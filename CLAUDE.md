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
systemd unit files, two GitHub Actions workflows, and a growing bats-core
test suite.

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
- `test/uninstall.bats` `cdev uninstall`, including that its conservative
  defaults stay conservative (live sessions are left running, the registry
  and notify file survive, linger is never disabled), and specifically that
  it `return`s rather than `exit`s so the calling shell survives it, the
  failure mode a subcommand risks that a standalone script never could

The suite covers the `cdev()` dispatcher only for flag handling, not for
subcommand routing. `_cdev-doctor` and `_cdev-status` are not covered at all.
Those are still hand-verified.

There is no automated way to exercise the install/reboot flow. Verifying a
change means reasoning through the script by hand, or running it against a
real (ideally throwaway) VPS, since `install.sh` runs `sudo loginctl
enable-linger` and installs `systemd --user` units, both of which persist
past the session.

## Architecture

Everything lives in one file, `cdev.sh` (sourced into `~/.bashrc` at install
time). `cdev()` is the dispatcher and the only function meant to be called
directly, the sole public entrypoint: it routes `cdev status`, `cdev kill`,
`cdev init`, `cdev accounts`, `cdev doctor`, `cdev upgrade`, `cdev restore`,
`cdev healthcheck`, `cdev uninstall`, `cdev version`, and `cdev help` to
underscore-prefixed
internal functions (`_cdev-status`, `_cdev-kill`, `_cdev-init`,
`_cdev-accounts`, `_cdev-doctor`, `_cdev-doctor-unit`, `_cdev-upgrade`,
`_cdev-latest-tag`, `_cdev-restore`, `_cdev-healthcheck`, `_cdev-uninstall`,
`_cdev-help`, `_cdev-format-duration`, `_cdev-config-dir`, `_cdev-ensure`),
and falls
through to `_cdev-attach` for anything else, so `cdev <name> [account] [dir]`
still works exactly as the
old top-level `cdev` function did. The leading underscore marks every one of
these as implementation detail, not a supported interface, so nothing outside
`cdev.sh` itself should call them by name. There is no exception any more:
`cdev` is the only function in the file without the underscore prefix.

- `_cdev-attach` holds the login-then-ensure-then-tmux-attach logic that used
  to live directly in `cdev`.
- `_cdev-latest-tag` resolves the newest published release by following the
  redirect that GitHub's `/releases/latest` issues to `/releases/tag/<tag>`,
  read with `curl -o /dev/null -w '%{url_effective}'`, then validates the
  result against the glob `v[0-9]*.[0-9]*.[0-9]*`. Deliberately not the
  GitHub API: no JSON to parse without `jq`, and no unauthenticated rate
  limit to hit. A repo with no releases redirects somewhere with no `/tag/`
  in it, which the glob rejects. `install.sh` carries its own copy of this
  logic, `cdev_latest_tag`, because it has to run before `cdev.sh` is on the
  box at all, so the two cannot share code.
- `_cdev-upgrade` moves an installed box to the latest release. It exists
  because an install made with the one-line `curl | bash` command has no
  checkout, so there is no `git pull`. It resolves the latest tag, prints
  "Already on the latest release" and stops if it matches `v$CDEV_VERSION`,
  otherwise downloads that tag's tarball and runs its `install.sh`. It
  deliberately does not decide which version is newer, comparing version
  strings portably is more machinery than it is worth, so it prints both and
  installs what the project currently publishes. Afterwards it reminds the
  user that their current shell still holds the old functions until they
  open a new one or re-source `~/.cdev.sh`.
- `_cdev-doctor` reports the installed version, systemd unit state, and
  linger state, guarding every `systemctl`/`loginctl` call so a box without
  systemd reports that fact instead of crashing or claiming the units are
  missing. It now also calls `_cdev-latest-tag` and prints the published
  version, suggesting `cdev upgrade` when it differs from the installed one.
  This is the check that actually reaches every install: the older `$PWD`
  comparison below is a developer convenience, useful only inside a
  checkout, and it is skipped silently everywhere else, which for a
  `curl | bash` install is always. Silence there used to read as "up to
  date", which is the bug the GitHub check fixes. When GitHub is
  unreachable, `curl` is missing, or there is no release yet, doctor prints
  "Released: could not check (no network, no curl, or no release yet)"
  rather than aborting or staying silent; `_cdev-help` prints usage.
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

At the bottom of `cdev.sh`, a check lets `./cdev.sh <args>` work directly,
not only via `source cdev.sh` then `cdev <args>`. It uses `(return 0
2>/dev/null)`, which succeeds only inside a function or a sourced file, to
tell sourced from executed. An earlier version compared `BASH_SOURCE[0]` to
`$0` instead, which looks equivalent but is not: it misreports a sourced
call as a direct one whenever something invokes bash with an explicit `$0`
that happens to match the sourced path, which is easy to do by accident in
a test harness (`test/uninstall.bats` did exactly this) and silently
corrupted the result, since bats' `bash -c 'source "$0" && ...'` construct
is a natural way to write a test. If this check ever needs touching again,
keep the `(return 0)` form.

`CDEV_VERSION` is embedded as a variable near the top of `cdev.sh`.
`_cdev-doctor` compares the installed version (`$CDEV_VERSION` from the
sourced `~/.cdev.sh`) against the version in whatever `cdev.sh` sits in
`$PWD`, when run from inside this repo's checkout. That comparison is
best-effort: it is skipped entirely when no `cdev.sh` is found in the
current directory, which is exactly why the GitHub-backed "Released:" check
described above exists, it is the check that still fires when there is no
checkout at all.

`install.sh` runs in two modes, decided by whether its own payload sits next
to it. `CDEV_PAYLOAD` names the files install.sh needs beside it (`cdev.sh`
and the three systemd unit files). From a checkout those files are there, and
install.sh installs exactly as before. Piped straight from the network, as in
`curl -fsSL https://cdev.pimlabs.id/install | bash`, there is no sibling file
at all, so install.sh resolves the newest release tag with the same
redirect-following logic as `_cdev-latest-tag` above (its own copy, named
`cdev_latest_tag`), downloads that tag's tarball from GitHub, extracts it to
a temp directory with `--strip-components=1`, and hands over with
`CDEV_BOOTSTRAPPED=1 exec bash "$work/install.sh"`. The mode decision looks
for the payload files rather than inspecting `$0` or `BASH_SOURCE`,
deliberately: a payload check reads the same however the script was invoked,
and it is what stops the hand-off from looping, since the extracted copy
does find its own payload and installs on that pass instead of downloading
again. `CDEV_BOOTSTRAPPED` is the second, belt-and-braces guard against the
same loop. Piped installs require `curl` and `tar` and say so clearly if
either is missing.

## Releasing

Three things move together, and a release is wrong if any one of them is
missing. `CDEV_VERSION` is the number a user's box reports, `CHANGELOG.md`
is what a version mismatch actually means, and the tag is what makes a
version recoverable later. Bumping the variable alone tells someone their
install is stale without telling them what changed.

1. Bump `CDEV_VERSION` in `cdev.sh`.
2. Turn the `[Unreleased]` heading in `CHANGELOG.md` into the new version
   with the date, open a fresh empty `[Unreleased]` above it, and update the
   two link definitions at the bottom of the file.
3. Commit, then `git tag -a vX.Y.Z` with a message summarising the release.
4. `git push origin main --follow-tags`, which pushes the commit and the tag
   in one go. A plain `git push` leaves the tag behind on the laptop.

Pushing the tag is enough to publish the release itself. `.github/workflows/release.yml`
watches for `v*` tag pushes and publishes the GitHub Release, attaching
`install.sh` as an asset, automatically, so this is not a step a maintainer
does by hand. That asset is what makes `/releases/latest/download/install.sh`
resolve, which is the documented one-line install URL. If that workflow ever
stops attaching the asset, the advertised one-liner 404s for everyone while
the release itself still looks perfectly fine, nothing else in the release
process would catch it. The existing `v0.2.0` tag was pushed before this
workflow existed, so it has no Release object and no asset; the one-line
install only starts working from the next tagged release onward.

Pre-1.0, so a breaking change bumps the minor, not the major. Renaming or
removing anything a user types (a subcommand, a flag) or anything an
installed box calls counts as breaking, since `install.sh` copies `cdev.sh`
rather than symlinking it and boxes therefore run whatever version they were
last installed with.

Do not bump the version for a change nobody's box can observe, such as docs
or tests. A version only earns a bump when re-running `install.sh` would give
the user something different, which is precisely what makes `cdev doctor`'s
"versions differ" line worth acting on rather than noise.

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

`_cdev-uninstall` (`cdev uninstall`) reverses exactly that: it disables and
removes the three systemd units, strips the `source` line, and deletes
`.cdev.sh` (plus the two legacy dotfiles). Unlike `install.sh` it is a
subcommand, not its own script, because of when each one runs: install has
to work before `cdev` exists on the box, so it must stand alone, while
uninstall only ever runs after `cdev` is already installed, so the code is
already there and it needs no network. That also means it runs inside the
caller's own sourced shell rather than as a process that was always going to
end, so every path through it must `return`, never `exit`, an `exit` here
would close the user's terminal. `test/uninstall.bats` tests this directly.
It cleans both `~/.bashrc` and `~/.zshrc` rather than only the shell detected
as current, because `install.sh` picked the rc file by the shell active at
install time, and someone who has since switched shells would otherwise be
left with a dangling source line that errors on every new shell in the file
`install.sh` never touched. It is deliberately conservative about three
things an uninstall could otherwise "helpfully" clean up too far: running
tmux sessions are left alone (uninstalling the launcher is not a reason to
kill live work; `--kill-sessions` opts in), the registry and the notify file
are kept so a reinstall picks up where you left off (`--purge` opts in), and
linger is never disabled since other systemd `--user` services may depend on
it by now (the `sudo loginctl disable-linger` command is printed instead,
left for a human to decide).
