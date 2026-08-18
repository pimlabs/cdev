# Changelog

## [Unreleased]

### Added

- Single cdev entrypoint with subcommands (status, kill, init, accounts, doctor, version, help) replacing five separate function names
- Workspace-trust failure detection and explanation in cdev-attach, replacing bare tmux exit message
- Uptime column in cdev status showing session duration
- Login column in cdev status, a placeholder that always prints "unknown". It is not a login check: cdev does not read Claude Code's credential expiry, the column only reserves the layout for a future one
- cdev doctor subcommand for comparing installed vs repo version and checking systemd/linger state
- Optional health-check notification via cdev-healthcheck.timer and ~/.cdev-notify
- Shell detection in install.sh to wire cdev.sh into matching rc file (.bashrc for bash, .zshrc for zsh)
- shellcheck linting in CI
- `cdev -- <name> [account] [dir]` to force attach mode when a project name collides with a subcommand word
- `./cdev.sh <args>` now works directly, not just `source cdev.sh` then `cdev <args>`, for quick local testing without installing

### Fixed

- cdev-ensure no longer builds the new session's launch command as a single shell string, an account or project name containing shell metacharacters could reach `sh -c` and execute arbitrary commands, including on every reboot via the registry replay
- cdev-kill no longer wipes the entire registry when the session name contains characters `grep`'s basic regex parser rejects, it now matches the name as a literal string
- cdev-attach polls for up to 3 seconds instead of a single fixed 1-second sleep before diagnosing a workspace-trust failure, avoiding a false positive on a slow session start
