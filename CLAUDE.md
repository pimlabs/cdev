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

No build step, no package manifest. This is several shell scripts plus three
systemd unit files, a GitHub Actions workflow, and a growing bats-core test
suite.

```bash
shellcheck cdev.sh install.sh cdev-restore-all.sh cdev-healthcheck.sh   # lint
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

- `test/cdev_ensure.bats` registry dedup in `cdev-ensure`
- `test/cdev_kill.bats` registry line removal in `cdev-kill`
- `test/account_config_dir.bats` account to `CLAUDE_CONFIG_DIR` mapping
- `test/install_shell_detection.bats` rc file picked by `install.sh`

The suite does not cover the `cdev()` dispatcher, `cdev-doctor`,
`cdev-status`, or `cdev-healthcheck.sh`. Those are still hand-verified.

There is no automated way to exercise the install/reboot flow. Verifying a
change means reasoning through the script by hand, or running it against a
real (ideally throwaway) VPS, since `install.sh` runs `sudo loginctl
enable-linger` and installs `systemd --user` units, both of which persist
past the session.

## Architecture

Two halves that share state through a flat file, not through each other:

- **`cdev.sh`** (sourced into `~/.bashrc` at install time) is the interactive
  half. `cdev()` itself is now a thin dispatcher: it routes `cdev status`,
  `cdev kill`, `cdev init`, `cdev accounts`, `cdev doctor`, `cdev version`,
  and `cdev help` to the functions of the same shape (`cdev-status`,
  `cdev-kill`, `cdev-init`, `cdev-accounts`, unchanged in name and behavior
  from before the dispatcher existed), and falls through to `cdev-attach` for
  anything else, so `cdev <name> [account] [dir]` still works exactly as the
  old top-level `cdev` function did. `cdev-attach` holds the login-then-
  ensure-then-tmux-attach logic that used to live directly in `cdev`.
  `cdev-doctor` and `cdev-help` are new: `cdev-doctor` reports the installed
  version, systemd unit state, and linger state, guarding every
  `systemctl`/`loginctl` call so a box without systemd reports that fact
  instead of crashing or claiming the units are missing; `cdev-help` prints
  usage. One trap in `cdev-status`: its LOGIN column is a hardcoded
  `unknown` string, not a check. cdev has no way to read Claude Code's
  credential expiry, and the column only reserves the layout for a future
  one. Do not describe it as a login check in docs or commit messages, and
  do not treat it as a signal.
  `cdev-ensure` inside this file is the one function also called
  non-interactively, it must stay safe to run with no attached terminal (no
  prompts, no blocking reads) since the boot path depends on that.
- **`cdev-restore-all.sh`** is the non-interactive half. It sources
  `~/.cdev.sh` and calls `cdev-ensure` directly by name for every registered
  session, unaffected by the `cdev()` dispatcher above. Run at boot by
  `cdev-restore.service` (`Type=oneshot`, `RemainAfterExit=yes`,
  `WantedBy=default.target`), and safe to re-run by hand since `cdev-ensure`
  no-ops on sessions that already exist.
- **`cdev-healthcheck.sh`** is a separate, opt-in non-interactive check. It
  compares the registry against live tmux sessions and reports any session
  that disappeared without going through `cdev-kill`. It is silent and a
  no-op unless `~/.cdev-notify` exists. Run by a second systemd unit pair,
  `cdev-healthcheck.service` + `cdev-healthcheck.timer`, every 5 minutes,
  installed and enabled by `install.sh` alongside the boot-time
  `cdev-restore.service` but independent of it.

The registry (`~/.cdev-sessions`, one `name account dir` line per session) is
the only thing connecting the interactive and non-interactive halves. `cdev`
appends to it when it creates a session, `cdev-kill` deletes the matching
line; anything that dies some other way (crash, reboot) simply stays in the
file and gets recreated on the next boot, or flagged by
`cdev-healthcheck.sh` if notifications are configured.

`CDEV_VERSION` is embedded as a variable near the top of `cdev.sh`.
`cdev-doctor` compares the installed version (`$CDEV_VERSION` from the
sourced `~/.cdev.sh`) against the version in whatever `cdev.sh` sits in
`$PWD`, when run from inside this repo's checkout. That comparison is
best-effort: it is skipped entirely when no `cdev.sh` is found in the
current directory.

Per-account isolation runs entirely through `CLAUDE_CONFIG_DIR`: account
`personal` uses `~/.claude`, any other account name uses `~/.claude-<account>`
(this mirrors the two-Claude-config-dir setup documented in the user's global
`MACHINE.md`, but here it's driving *account* separation for Remote Control
sessions on a server, not the personal/work app split on a laptop). This is
why `cdev-init` has to run inside the target project directory: Claude Code's
first-run trust dialog is saved per-directory, and never for `$HOME`, so
logging in from wherever the SSH session happens to land trusts the wrong
path.

`install.sh` is the only script that touches the box outside this repo's own
files: it copies `cdev.sh`, `cdev-restore-all.sh`, and `cdev-healthcheck.sh`
into `$HOME` (as dotfiles, `.cdev.sh` / `.cdev-restore-all.sh` /
`.cdev-healthcheck.sh`), appends a `source` line to the detected shell rc file
(`~/.zshrc` or `~/.bashrc`), and installs all three systemd units. It enables
two of them, `cdev-restore.service` and `cdev-healthcheck.timer`.
`cdev-healthcheck.service` is installed but deliberately not enabled: it has
no `[Install]` section and is activated by its timer, so enabling it directly
would be wrong. Editing `cdev.sh` in this repo has no effect on an
already-installed box until `install.sh` (or a manual copy) runs again, the
two are not symlinked.
