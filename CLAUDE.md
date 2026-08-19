# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Bash functions plus a systemd unit that keep Claude Code Remote Control
sessions alive on a server across SSH disconnects, laptop sleep, and reboots,
by wrapping each session in its own `tmux` session and recreating them at
boot. See [README.md](README.md) for the full command reference, the
multi-account model, and known issues (workspace-trust errors, silent stalls
on expired login).

## Commands

No build step, no package manifest. This is two shell scripts plus three
systemd unit files, a GitHub Actions workflow, and a growing bats-core test
suite.

```bash
shellcheck cdev.sh install.sh   # lint
```

Shellcheck also runs in CI on every push and pull request, see
`.github/workflows/shellcheck.yml`, in addition to running it ad hoc locally
as above.

A bats-core test suite lives under `test/`, covering only the pieces that
need no live tmux, systemd, or VPS. External commands (`tmux`, `systemctl`,
`sudo`, `loginctl`) are stubbed onto `PATH` by `test/test_helper.bash`, and
every test points `HOME` at a temp directory, so nothing touches the real
registry or this machine's systemd state.

```bash
bats test/            # needs bats-core installed, it is not vendored here
```

- `test/cdev_ensure.bats` registry dedup in `_cdev-ensure`
- `test/cdev_kill.bats` registry line removal in `_cdev-kill` (the `cdev kill` subcommand)
- `test/account_config_dir.bats` account to `CLAUDE_CONFIG_DIR` mapping
- `test/install_shell_detection.bats` rc file picked by `install.sh`
- `test/cdev_restore_healthcheck.bats` the registry replay in `_cdev-restore`
  (including that it continues past a failing session) and the opt-in
  webhook gate in `_cdev-healthcheck`
- `test/dispatcher_flags.bats` flag handling in the `cdev()` dispatcher, and
  the registry-corruption chain it once caused (see the file's own header)

The suite does not cover the `cdev()` dispatcher, `_cdev-doctor`, or
`_cdev-status`. Those are still hand-verified.

There is no automated way to exercise the install/reboot flow. Verifying a
change means reasoning through the script by hand, or running it against a
real (ideally throwaway) VPS, since `install.sh` runs `sudo loginctl
enable-linger` and installs `systemd --user` units, both of which persist
past the session.

## Architecture

Everything lives in one file, `cdev.sh` (sourced into `~/.bashrc` at install
time). `cdev()` is the dispatcher and the only function meant to be called
directly, the sole public entrypoint: it routes `cdev status`, `cdev kill`,
`cdev init`, `cdev accounts`, `cdev doctor`, `cdev restore`,
`cdev healthcheck`, `cdev version`, and `cdev help` to underscore-prefixed
internal functions (`_cdev-status`, `_cdev-kill`, `_cdev-init`,
`_cdev-accounts`, `_cdev-doctor`, `_cdev-doctor-unit`, `_cdev-restore`,
`_cdev-healthcheck`, `_cdev-help`, `_cdev-format-duration`,
`_cdev-config-dir`, `_cdev-ensure`), and falls through to `_cdev-attach` for
anything else, so `cdev <name> [account] [dir]` still works exactly as the
old top-level `cdev` function did. The leading underscore marks every one of
these as implementation detail, not a supported interface, so nothing outside
`cdev.sh` itself should call them by name. There is no exception any more:
`cdev` is the only function in the file without the underscore prefix.

- `_cdev-attach` holds the login-then-ensure-then-tmux-attach logic that used
  to live directly in `cdev`.
- `_cdev-doctor` reports the installed version, systemd unit state, and
  linger state, guarding every `systemctl`/`loginctl` call so a box without
  systemd reports that fact instead of crashing or claiming the units are
  missing; `_cdev-help` prints usage.
- `_cdev-ensure` creates the tmux session and records it in the registry. It
  is also the one function called non-interactively, so it must stay safe to
  run with no attached terminal (no prompts, no blocking reads), since the
  boot path depends on that.
- `_cdev-restore` replays every line of the registry through `_cdev-ensure`.
  This is what the boot path runs. `cdev.sh` is sourced into an interactive
  shell, so it cannot lean on `set -e` the way the old standalone script
  could; instead `_cdev-restore` counts each `_cdev-ensure` failure
  explicitly, keeps going through the rest of the registry so one broken
  session does not block the others, and returns 1 at the end if any failed,
  so systemd still marks the unit failed rather than reporting a clean boot.
- `_cdev-healthcheck` is a separate, opt-in non-interactive check. It
  compares the registry against live tmux sessions and reports any session
  that disappeared without going through `cdev kill`. It is silent and a
  no-op unless `~/.cdev-notify` exists.

Both the boot path and the periodic health check are now subcommands rather
than standalone scripts, because systemd does not read the shell rc file: a
unit cannot just run `cdev restore`, since `cdev` would not be defined yet in
that shell. Each unit's `ExecStart` instead sources `cdev.sh` itself and then
calls the subcommand in the same command:
`/bin/bash -c "source %h/.cdev.sh && cdev restore"` (and `cdev healthcheck`
for the health check unit). This is the same entrypoint a human uses, just
invoked non-interactively. `cdev-restore.service`
(`Type=oneshot`, `RemainAfterExit=yes`, `WantedBy=default.target`) runs
`cdev restore` at boot, safe to re-run by hand since `_cdev-ensure` no-ops on
sessions that already exist. `cdev-healthcheck.service` runs
`cdev healthcheck`, triggered every 5 minutes by `cdev-healthcheck.timer`,
installed and enabled by `install.sh` alongside the boot-time
`cdev-restore.service` but independent of it.

The registry (`~/.cdev-sessions`, one `name account dir` line per session) is
the only state shared between the interactive and non-interactive paths.
`cdev` appends to it when it creates a session, `_cdev-kill` deletes the
matching line; anything that dies some other way (crash, reboot) simply stays
in the file and gets recreated on the next `cdev restore`, or flagged by
`cdev healthcheck` if notifications are configured.

`CDEV_VERSION` is embedded as a variable near the top of `cdev.sh`.
`_cdev-doctor` compares the installed version (`$CDEV_VERSION` from the
sourced `~/.cdev.sh`) against the version in whatever `cdev.sh` sits in
`$PWD`, when run from inside this repo's checkout. That comparison is
best-effort: it is skipped entirely when no `cdev.sh` is found in the
current directory.

Per-account isolation runs entirely through `CLAUDE_CONFIG_DIR`: account
`personal` uses `~/.claude`, any other account name uses `~/.claude-<account>`
(this mirrors the two-Claude-config-dir setup documented in the user's global
`MACHINE.md`, but here it's driving *account* separation for Remote Control
sessions on a server, not the personal/work app split on a laptop). This is
why `_cdev-init` has to run inside the target project directory: Claude Code's
first-run trust dialog is saved per-directory, and never for `$HOME`, so
logging in from wherever the SSH session happens to land trusts the wrong
path.

`install.sh` is the only script that touches the box outside this repo's own
files: it copies `cdev.sh` into `$HOME` (as the dotfile `.cdev.sh`), clears
`$HOME/.cdev-restore-all.sh` and `$HOME/.cdev-healthcheck.sh` left over from
an older install that used the now-deleted standalone scripts, appends a
`source` line to the detected shell rc file (`~/.zshrc` or `~/.bashrc`), and
installs all three systemd units. It enables two of them,
`cdev-restore.service` and `cdev-healthcheck.timer`. `cdev-healthcheck.service`
is installed but deliberately not enabled: it has no `[Install]` section and
is activated by its timer, so enabling it directly would be wrong. Editing
`cdev.sh` in this repo has no effect on an already-installed box until
`install.sh` (or a manual copy) runs again, the two are not symlinked.
