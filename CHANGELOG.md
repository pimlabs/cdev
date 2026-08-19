# Changelog

## [Unreleased]

## [0.7.0] - 2026-08-19

### Added

- `cdev <name> [account] [dir]` now creates `dir` if it doesn't exist yet, tmux refuses a session whose working directory is missing, and the natural way to use this command is exactly for a brand new project that has no directory at all
- `cdev <name> [account] [dir]` now recovers automatically when the first attempt dies immediately, most commonly because `dir` was never trusted under an account that already has other trusted projects (trust is saved per-directory, not per-account). It opens a one-time trust step scoped to `dir` and retries once, instead of printing a fix command for the user to copy and re-run `cdev` themselves. Only falls back to that manual message if the retry also fails

### Fixed

- A session whose command already died (a crash, or the common case, an untrusted directory) but stayed held open by `remain-on-exit` was indistinguishable from a healthy one to `tmux has-session` alone, since the session object itself hadn't gone anywhere. `_cdev-ensure` used to skip recreating it, `_cdev-attach` reattached straight back to the same dead pane with no diagnostic (a bare tmux `[exited]`, since the existing untrusted-workspace diagnostic only ever fired when the session disappeared entirely), and `_cdev-healthcheck` never flagged it as missing either. All three now check the pane's actual liveness (`#{pane_dead}`), not just whether tmux still has a session by that name

## [0.6.0] - 2026-08-19

### Added

- `cdev doctor` now adopts a live tmux session that isn't in the registry into the registry, so it survives `cdev restore` after a reboot instead of silently vanishing with no warning beforehand. Account and dir are best-effort guesses, `CDEV_ACCOUNT` from the session's own tmux environment and its current pane path, since an orphan session was never told either explicitly the way `cdev <name>` tells `_cdev-ensure`
- `cdev doctor` now prints the exact fix command when it finds `cdev-restore.service`, `cdev-healthcheck.timer`, or `loginctl` linger disabled, instead of only naming the problem and leaving the fix to be looked up

### Fixed

- `cdev doctor`'s systemd unit check no longer misreports a disabled-but-installed unit as "not installed". `systemctl is-enabled` exits non-zero for "disabled" just as much as for a unit that was never installed, the exit code alone couldn't tell the two apart, only the actual stdout can
- `shellcheck.yml` no longer installs shellcheck via `apt-get`. The `ubuntu-latest` runner image already ships shellcheck preinstalled, so the CI job now uses that directly, one less unpinned network call that can stall a run (the exact command that hung for about 4 hours on 19 August 2026, see the `timeout-minutes` fix in 0.3.0) and the job runs faster with the step gone entirely

## [0.5.0] - 2026-08-19

### Added

- `cdev doctor` now reports `claude` and `tmux`, both hard requirements it never actually checked for before, presence and version if found, a plain "not found on PATH" if not. Their absence used to only ever surface as a confusing mid-session failure, a bare tmux `[exited]` pane with no context, instead of a clear answer here
- `cdev doctor` prints a `Running from:` line showing the exact path it executed from, useful confirmation that a report is coming from the real installed binary and not something else on `PATH`

## [0.4.0] - 2026-08-19

### Changed

- `cdev` is now installed as a plain executable at `~/.local/bin/cdev` instead of being copied to `~/.cdev.sh` and sourced into `~/.bashrc`/`~/.zshrc`. The old model meant the shell that just ran the installer never had `cdev` available, only shells that sourced the rc file after install did, so every install ended with a manual `source ~/.cdev.sh` or a new shell. A `$PATH`-resolved executable needs no such step: the next `cdev` typed, in the same shell that ran the installer, already works, `~/.local/bin` is on `PATH` by default on stock Ubuntu. If it isn't, `install.sh` now falls back to appending `export PATH="$HOME/.local/bin:$PATH"` to the detected rc file instead. Upgrading an existing install is automatic and transparent: `install.sh` (which `cdev upgrade` re-runs) removes the old `~/.cdev.sh` and strips the legacy `source` line from both rc files if present, and `cdev uninstall` now removes the `~/.local/bin/cdev` binary as its primary target, keeping the rc-file cleanup only as a fallback for a box still on the old model
- `cdev upgrade` no longer tells you to open a new shell or re-source anything afterward. That instruction was a symptom of the sourced-function model: replacing `~/.cdev.sh` on disk did nothing to a shell that had already loaded the old function definitions into memory. With a binary, the very next `cdev` invocation, in any shell, already runs the newly-installed content at that same path
- `cdev-restore.service` and `cdev-healthcheck.service` now call `~/.local/bin/cdev` directly by its absolute path (`ExecStart=%h/.local/bin/cdev restore`, and `... healthcheck`), instead of `/bin/bash -c "source %h/.cdev.sh && cdev ..."`. Behavior is unchanged, this is strictly simpler now that there is a real executable to point at

## [0.3.0] - 2026-08-19

### Added

- One-line curl install (`curl -fsSL https://cdev.pimlabs.id/install | bash`, or the GitHub URL directly before the DNS redirect is in place). `install.sh` now runs in two modes: from a checkout it installs as before, and when piped from the network it resolves the latest release tag, downloads that tag's tarball, and hands off to the extracted copy's install.sh
- `cdev upgrade` subcommand, for installs made via the curl one-liner that have no checkout to `git pull`. Resolves the latest release tag, does nothing if already on it, otherwise downloads and installs that tag
- `.github/workflows/release.yml` publishes a GitHub Release and attaches install.sh and SHA256SUMS as assets on every `v*` tag push, which is what makes `releases/latest/download/install.sh` resolve to the newest release
- SHA256SUMS checksum verification: `install.sh`'s piped mode and `cdev upgrade` both download the release tarball to a file, verify it against the `SHA256SUMS` release asset, and abort with a clear message on a mismatch or a missing `SHA256SUMS`, instead of extracting and running an unverified download
- `cdev open <name> [account] [dir]` subcommand, an explicit equivalent to bare `cdev <name> [account] [dir]` (the default action, unchanged from `v0.2.0`), for a project name that collides with a reserved subcommand word. `cdev -- <name> [account] [dir]` keeps working as an older equivalent for the same case

### Changed

- `cdev doctor` now also reports the latest published release tag on GitHub, alongside the existing `$PWD` checkout comparison. Its only version check before this was against a `cdev.sh` in `$PWD`, which a curl install never has, so doctor silently skipped that check and read as up to date with no way to tell otherwise
- `uninstall.sh` is deleted. Its logic is now `_cdev-uninstall`, reachable as the `cdev uninstall` subcommand. Behavior and every flag (`--kill-sessions`, `--purge`) are unchanged; only how you run it changed, from `./uninstall.sh` to `cdev uninstall`
- The `./cdev.sh <args>` direct-invoke check now uses `(return 0 2>/dev/null)` instead of comparing `BASH_SOURCE[0]` to `$0`. The old comparison could misreport a sourced call as a direct one if something invoked bash with an explicit `$0` matching the sourced path, which surfaced as a real test failure once `cdev uninstall` needed to be exercised as a subcommand rather than a standalone script

### Fixed

- `_cdev-kill` no longer matches the session name as a substring anywhere in the registry line. The previous `grep -vF -- "$1 "` could silently drop an unrelated line whose account or dir field happened to contain the same text as the name being killed (e.g. killing `foo` could also remove a line whose dir was `/home/x/foo bar`). Registry removal is now done with `awk`, matching only the name field
- Three registry race conditions, fixed with `flock`-based locking around every registry read and write: an `_cdev-ensure` append landing between `_cdev-kill`'s read and its `mv` could be silently discarded; two concurrent `cdev kill` calls could each resurrect the line the other had just removed; and `cdev restore` could recreate (and re-register) a session a human killed after the restore snapshot was taken but before the loop reached it. Falls back to running unlocked when `flock` isn't on `PATH` (no worse than before), since this project's own dev/test machine has none while every target VPS does
- An SC2015 finding in `install.sh`'s payload-check loop that a local shellcheck no longer flags but the version `apt-get install shellcheck` resolved to on the `shellcheck.yml` runner still did, failing CI on 3 consecutive pushes to `main`. The `A && B || C` pattern there is intentional, so the rule is now disabled explicitly with a comment, instead of depending on whichever shellcheck version happens to be current on the runner that day
- Neither GitHub Actions workflow capped its job runtime, so GitHub's default 6-hour job timeout applied. A stalled `apt-get install shellcheck` step in `shellcheck.yml` sat "in progress" for about 4 hours across 3 runs on 19 August 2026 before being cancelled by hand, billable the whole time on this private repo. Both workflows now set `timeout-minutes` (5 for shellcheck, 10 for release, both well above their normal runtime), and `shellcheck.yml` also cancels a still-running run for the same branch when a newer push supersedes it

## [0.2.0] - 2026-08-19

First tagged release. Everything below was written before any version
existed, so this entry is the whole history rather than a delta from 0.1.0,
which was only ever the in-development value of `CDEV_VERSION`.

Upgrading from an install made before this tag: re-run `./install.sh`. The
old `cdev-status`, `cdev-kill`, `cdev-init`, `cdev-accounts`, and
`cdev-ensure` function names are gone, use the `cdev <subcommand>` form.

### Added

- uninstall.sh to remove the cdev install, reversing all install.sh changes to systemd units, shell rc files, and ~/.cdev.sh. Conservative by default, does not kill running tmux sessions (pass --kill-sessions to stop them), keeps the registry and notify file for reinstalls (pass --purge to delete them), and never disables linger
- Single cdev entrypoint with subcommands (status, kill, init, accounts, doctor, restore, healthcheck, version, help) replacing the separate top-level function names
- Workspace-trust failure detection and explanation in cdev-attach, replacing bare tmux exit message
- Uptime column in cdev status showing session duration
- cdev doctor subcommand for comparing installed vs repo version and checking systemd/linger state
- Optional health-check notification via cdev-healthcheck.timer and ~/.cdev-notify
- Shell detection in install.sh to wire cdev.sh into matching rc file (.bashrc for bash, .zshrc for zsh)
- shellcheck linting in CI
- `cdev -- <name> [account] [dir]` to force attach mode when a project name collides with a subcommand word
- `./cdev.sh <args>` now works directly, not just `source cdev.sh` then `cdev <args>`, for quick local testing without installing

### Changed

- Internal helper functions (`_cdev-status`, `_cdev-kill`, `_cdev-init`, `_cdev-attach`, `_cdev-accounts`, `_cdev-doctor`, `_cdev-doctor-unit`, `_cdev-format-duration`, `_cdev-config-dir`, `_cdev-help`) are now prefixed with an underscore and not meant to be called directly. `cdev-ensure` is also renamed to `_cdev-ensure`, dropping the exception it used to have, so `cdev` is now the only unprefixed function and the sole supported public entrypoint.
- The standalone scripts `cdev-restore-all.sh` and `cdev-healthcheck.sh` are deleted, their logic now lives in `cdev.sh` as `_cdev-restore` and `_cdev-healthcheck`, reachable as the `cdev restore` and `cdev healthcheck` subcommands. Behavior is unchanged: restore still replays every registry line, healthcheck is still opt-in and silent unless `~/.cdev-notify` holds a webhook URL. The `cdev-restore.service` and `cdev-healthcheck.service` systemd units now source `~/.cdev.sh` and call these subcommands (`ExecStart=/bin/bash -c "source %h/.cdev.sh && cdev <subcommand>"`) instead of invoking the deleted scripts, and `install.sh` no longer copies those two scripts into `$HOME`, removing any leftover copies from an older install instead.
- `_cdev-ensure` now returns 1 and prints to stderr when `tmux new-session` itself fails, instead of always returning 0. `_cdev-restore` counts those failures, keeps going through the rest of the registry, and returns 1 at the end if any session failed to start.

### Fixed

- cdev-ensure no longer builds the new session's launch command as a single shell string, an account or project name containing shell metacharacters could reach `sh -c` and execute arbitrary commands, including on every reboot via the registry replay
- cdev-kill no longer wipes the entire registry when the session name contains characters `grep`'s basic regex parser rejects, it now matches the name as a literal string
- cdev-attach polls for up to 3 seconds instead of a single fixed 1-second sleep before diagnosing a workspace-trust failure, avoiding a false positive on a slow session start
- `cdev --version` and `cdev -v` now print the version. They were not dispatcher cases, so they fell through to the default action and were registered as a project literally named `--version`. Any other unrecognized flag is now rejected with an error instead of being taken as a session name; `cdev -- <name>` remains the way to use a genuinely dash-named project
- `_cdev-ensure`'s dedup check now passes `--` to grep. Without it a registry line starting with a dash was read by grep as its own options, so the check failed and the line was appended again on every call
- `_cdev-restore` iterates over a snapshot of the registry rather than the live file. Combined with the dedup bug above, reading the file while `_cdev-ensure` appended to it turned the loop into one that never ended and a registry that grew without limit (a real run reached 12,657 identical lines)

[Unreleased]: https://github.com/pimlabs/cdev/compare/v0.7.0...HEAD
[0.7.0]: https://github.com/pimlabs/cdev/releases/tag/v0.7.0
[0.6.0]: https://github.com/pimlabs/cdev/releases/tag/v0.6.0
[0.5.0]: https://github.com/pimlabs/cdev/releases/tag/v0.5.0
[0.4.0]: https://github.com/pimlabs/cdev/releases/tag/v0.4.0
[0.3.0]: https://github.com/pimlabs/cdev/releases/tag/v0.3.0
[0.2.0]: https://github.com/pimlabs/cdev/releases/tag/v0.2.0
