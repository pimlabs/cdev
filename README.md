# cdev

[![release](https://img.shields.io/github/v/release/pimlabs/cdev)](https://github.com/pimlabs/cdev/releases/latest)
[![shellcheck](https://github.com/pimlabs/cdev/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/pimlabs/cdev/actions/workflows/shellcheck.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Persistent, multi-account Claude Code sessions on any server, over tmux.
Survives SSH disconnects, laptop sleep, and reboots. Originally built for a
single VPS, split out here because it has no dependency on that VPS or any
specific project, install it on whichever box you want to develop from.

## Contents

- [Requirements](#requirements)
- [Install](#install)
  - [Verifying the install](#verifying-the-install)
  - [Upgrading](#upgrading)
- [Uninstall](#uninstall)
- [Commands](#commands)
- [Connecting from your phone or another browser](#connecting-from-your-phone-or-another-browser)
- [Basic tmux, if you're not used to it](#basic-tmux-if-youre-not-used-to-it)
- [Reboot recovery](#reboot-recovery)
- [Health-check notifications (optional)](#health-check-notifications-optional)
- [Known issues](#known-issues)
- [License](#license)

## Requirements

Two things, both required before installing, `cdev doctor` checks for both
afterward and says plainly if either is missing:

- `tmux`, installed first if it's not already on the box:

  ```bash
  sudo apt install -y tmux
  ```

- The [Claude Code](https://claude.ai/code) CLI (`claude`), logged in or not,
  cdev handles login per account (see [Commands](#commands) below).

## Install

```bash
curl -fsSL https://cdev.pimlabs.id/install | bash
```

That is the one-line install, the same shape as Bun, rustup, or Docker's.
`cdev.pimlabs.id/install` is a permanent redirect to
`https://github.com/pimlabs/cdev/releases/latest/download/install.sh`, which
works today on its own if the redirect isn't live yet or you'd rather not
depend on the subdomain:

```bash
curl -fsSL https://github.com/pimlabs/cdev/releases/latest/download/install.sh | bash
```

It needs `curl` and `tar` on the box, and it always installs the latest
tagged release, never a branch. The script detects it's running from a pipe
rather than a checkout, downloads that release's tarball, and hands off to
the `install.sh` inside it, so the rest of the install (below) is identical
either way.

If you're developing on cdev itself, or you'd rather read the script before
running it, clone and run it from a checkout instead:

```bash
git clone https://github.com/pimlabs/cdev.git
cd cdev
./install.sh
```

Either way, `install.sh` copies `cdev.sh` to `~/.local/bin/cdev` and makes it
executable. `~/.local/bin` is on `PATH` by default on stock Ubuntu, the
common target here, so `cdev` is callable immediately in the very same shell
that ran the installer, no `source` step and no new shell needed: a plain
executable resolved off `PATH` needs no loading step the way a shell
function sourced from an rc file does. If `~/.local/bin` isn't already on
`PATH`, install.sh detects whether the login shell is zsh or bash and
appends an `export PATH=...` line to the matching rc file instead
(`~/.zshrc` or `~/.bashrc`), and says so at the end of the run.

It also installs three `systemd --user` units. Everything, the interactive
commands, the boot-time restore, and the health check, lives in that one
`cdev.sh`, dispatched through `cdev restore` and `cdev healthcheck` the same
way a human would call `cdev status`:

- **`cdev-restore.service`**, enabled: recreates every registered session
  automatically after a reboot, no manual step.
- **`cdev-healthcheck.timer`**, enabled: drives `cdev-healthcheck.service`
  every 5 minutes, stays silent until you opt in, see
  [Health-check notifications](#health-check-notifications-optional).

It also runs `sudo loginctl enable-linger` so those units can start before
any interactive login.

### Verifying the install

Every tagged release publishes a `SHA256SUMS` file alongside `install.sh`,
covering the source tarball the installer downloads and `install.sh` itself.
The piped install and `cdev upgrade` both fetch and check it automatically
before extracting anything, and abort with a clear message on a mismatch, so
this is not a step you normally have to do by hand. If you'd rather check
before piping `install.sh` straight into `bash`, download it and the release's
`SHA256SUMS` first and compare:

```bash
curl -fsSLO https://github.com/pimlabs/cdev/releases/latest/download/install.sh
curl -fsSLO https://github.com/pimlabs/cdev/releases/latest/download/SHA256SUMS
grep install.sh SHA256SUMS | shasum -a 256 -c -
bash install.sh
```

This only defends against a corrupted or tampered-with download in transit,
the same protection the installer applies to itself. It does not verify who
built the release, that would need signing, which cdev does not do.

### Upgrading

An install made with the curl one-liner has no checkout to `git pull`, so
`cdev upgrade` is how it moves forward: it downloads the latest release's
tarball and runs its `install.sh` the same way the one-liner did. A checkout
install upgrades the ordinary way instead:

```bash
git pull
./install.sh
```

Either path only updates `~/.local/bin/cdev` and the systemd units. Since
`cdev` is a plain executable rather than a shell function, there is nothing
to reload: the very next `cdev` command in any shell, including the one that
just ran the upgrade, already runs the new version.

## Uninstall

```bash
cdev uninstall
```

It reverses `install.sh`: disables and removes the three systemd units and
deletes the `~/.local/bin/cdev` binary, the primary thing it removes now that
`cdev` is a plain executable rather than a sourced function. It also strips
any leftover legacy rc-file lines from an older install, the `source
"$HOME/.cdev.sh"` line from the old sourced-function model and the `export
PATH="$HOME/.local/bin:$PATH"` line `install.sh` adds only when
`~/.local/bin` wasn't already on `PATH`, from both `~/.bashrc` and
`~/.zshrc`, in case the shell changed since install. On a fresh install
where `~/.local/bin` was already on `PATH` (the common case) neither line
was ever written, so there is nothing to clean up there at all. A subcommand
rather than its own script, unlike `install.sh`: uninstall only ever runs
after `cdev` is already on the box, so it needs no network and no separate
file, unlike installing, which has to work before `cdev` exists at all.

**Your running tmux sessions are not touched.** Uninstalling the launcher is
not a reason to kill live Claude sessions, so they keep running under tmux
and `cdev uninstall` prints how to reach them (`tmux attach -t <name>`). Pass
`--kill-sessions` to stop them too. The registry (`~/.cdev-sessions`) and the
webhook config (`~/.cdev-notify`) are kept by default as well, so a reinstall
picks up where you left off, pass `--purge` to delete them. Linger is never
disabled since other `systemd --user` services may depend on it by now,
`cdev uninstall` prints the `sudo loginctl disable-linger` command instead of
running it, so you can decide.

Removing the binary takes effect immediately in every shell, there is no
function left loaded anywhere to unset. Run `cdev uninstall --help` for the
full flag list.

## Commands

`cdev` is a single entrypoint, `cdev <subcommand> ...`. `cdev <name>
[account] [dir]` (bare, no subcommand word) is the default action: create if
needed, then attach.

| Command | Does |
|---|---|
| `cdev <name> [account] [dir]` | Create (if new) and attach to a session. Account defaults to `personal`, maps to `~/.claude-<account>`. `dir` is created if it doesn't exist yet. Logs the account in first if it never has been. If the session exits immediately, most commonly because `dir` has never been trusted under that account, `cdev` opens a one-time trust step there and retries once automatically, instead of leaving a bare tmux `[exited]` or a fix command to run by hand. `cdev open <name> [account] [dir]` and the older `cdev -- <name> [account] [dir]` are explicit equivalents, needed when `<name>` collides with a reserved subcommand word below. |
| `cdev status` | List running sessions with their account, attach state, and session uptime. There is no login/credential column: cdev does not read Claude Code's local credential expiry, so it cannot tell a logged-in session from an expired one. |
| `cdev kill <name>` | Stop a session and remove it from the reboot registry. |
| `cdev init <account> <dir>` | One-time interactive login for an account, run inside `<dir>` so the trust dialog applies to that project, not `$HOME`. No-ops if it's already logged in. Runs automatically from `cdev` when needed. |
| `cdev accounts` | List which `~/.claude*` config dirs (accounts) exist. |
| `cdev doctor` | Check install health: installed vs repo version, the latest published release, whether the systemd units are enabled/active, and whether linger is on. Points at `cdev upgrade` when the installed version is behind the latest release, and prints the exact fix command for a disabled unit or disabled linger. Also adopts any live tmux session missing from the registry, so it survives `cdev restore` after a reboot instead of silently vanishing. |
| `cdev upgrade` | Install the latest tagged release. For a curl-installed box (no checkout to `git pull`): downloads that release's tarball and runs its `install.sh`. No-ops with a message if you're already on the latest tag. |
| `cdev restore` | Recreate every registered session. Run automatically at boot by `cdev-restore.service`; safe to run by hand too, it no-ops on sessions that already exist. |
| `cdev healthcheck` | Report registered sessions that vanished from tmux without going through `cdev kill`. Run every 5 minutes by `cdev-healthcheck.timer`; silent unless `~/.cdev-notify` holds a webhook URL. |
| `cdev uninstall` | Remove cdev from this box: systemd units and the `~/.local/bin/cdev` binary. See [Uninstall](#uninstall) above. |
| `cdev version` (`--version`, `-v`) | Print the installed cdev version. |
| `cdev help` (`--help`, `-h`) | Show usage and the subcommand list. Also what bare `cdev` prints. |

A project name can't be `status`, `kill`, `doctor`, or any other word in
this table, `cdev` would treat it as that subcommand instead of a project.
Use `cdev open <name>` or `cdev -- <name>` for a project that genuinely
needs one of those names. Same trade-off `git` and `npm` accept, since a
bare argument is their default action too.

Must run inside `tmux` (which `cdev` handles for you), not a bare SSH shell,
or the session dies the moment SSH disconnects. The first time `cdev` is
used with a new account, it drops into an interactive login before creating
the session:

```
No login yet for account 'work', starting one-time login...
```

Press `c` to copy the login URL, open it on your phone/laptop browser,
paste the code it shows back into that prompt. Do not use
`claude setup-token` for this, that token type cannot establish Remote
Control sessions. Sessions logged into different accounts show up under
that account's own `claude.ai/code` session list, not a combined one.

`cdev init` is only wired into `cdev` itself, not into the boot-time restore
path (`cdev restore`), an interactive login prompt with nothing attached to
a terminal would just hang that service. So a brand new account still needs
its first `cdev <name> <account>` run by hand over SSH, after that its
session survives reboots like any other.

Every session is started with `--spawn=worktree`, so a session
spawned against it later from claude.ai/code or the mobile app gets an
isolated git worktree instead of sharing the working directory, no prompt
asked. Edit the flag in `cdev.sh` if some project genuinely wants
`same-dir` instead.

## Connecting from your phone or another browser

`cdev` gets you a live session in the server's terminal, that's only half of
Remote Control. To check in from elsewhere:

1. Open [claude.ai/code](https://claude.ai/code) (or the Claude mobile app)
   on the phone/laptop/browser you want to use, signed in with the **same
   account** the session was started under.
2. Find the session by the name you gave it, that's the `<name>` you passed
   to `cdev`. Sessions show a computer icon with a green dot when online.
3. Tap in to watch progress live or send a message, it stays in sync with
   whatever's happening in the server's terminal.

If a session doesn't show up, double check you're looking at the right
account (`personal` sessions only appear in the personal account's list,
`work` sessions only in that one) and that the systemd unit / tmux session
is actually running (`cdev status` on the server).

## Basic tmux, if you're not used to it

`cdev <name>` attaches you to the session's terminal. To leave it
running and get your shell back:

```
Ctrl+b, then d
```

That detaches without stopping anything, running `cdev <name>` again
later reattaches to the same session. Closing the terminal window or losing the
SSH connection does the same thing by accident, tmux keeps the session
alive either way.

## Reboot recovery

Every session lives in one registry file, `~/.cdev-sessions`, one line per
session: `name account dir`.

- **`cdev <name>`** appends to it when it creates a session.
- **`cdev kill <name>`** removes the matching line, so a
  deliberately-stopped session doesn't come back.
- **`cdev doctor`** adopts any live tmux session it finds missing from the
  file, so a session started outside `cdev` (or a line lost to a manual
  edit) survives a reboot too instead of silently disappearing. Account and
  directory are best-effort guesses read from the session's own tmux state,
  worth a quick `cdev status` check after an adoption if the directory
  matters.
- **`cdev restore`** reads the file and recreates every entry the same way
  `cdev` does when it creates a new session, just without attaching.
  `cdev-restore.service` runs it once at boot, by calling `~/.local/bin/cdev
  restore` directly, its absolute path, no shell wrapper needed.

A session that stops some other way (server reboot, crash) stays in the
registry and gets recreated automatically the next time the box comes up.
`cdev restore` is also safe to run by hand at any time, it no-ops on
sessions that already exist and only reports a failure for the ones that
didn't come up.

## Health-check notifications (optional)

`cdev-healthcheck.timer` runs every 5 minutes and drives
`cdev-healthcheck.service`, which calls `~/.local/bin/cdev healthcheck`
directly. That compares the registry against the tmux sessions
actually running. If a registered session vanished without going through
`cdev kill` (a crash, an OOM kill, anything other than a deliberate stop),
it POSTs a plain-text message describing which session disappeared to a
webhook URL.

This is opt-in and silent by default. To turn it on, write the webhook URL
into `~/.cdev-notify`, one line, nothing else to configure. If that file
doesn't exist, the health check exits immediately and does nothing.

## Known issues

- **`Error: Workspace not trusted`** when `claude remote-control` starts in a
  directory that has never been trusted under that account: Claude Code's
  trust dialog is saved per-directory, not per-account, so this is the
  normal, expected first run for any brand new project, `cdev <name>
  [account] [dir]` is exactly how a new project gets started. `cdev` handles
  it automatically now: it detects the session dying immediately, opens a
  one-time login/trust step scoped to that directory, and retries once, no
  manual fix command to copy or `cdev` to re-run by hand. If it still isn't
  running after that retry, something else is wrong, `cdev` prints the same
  command to check by hand: `cd <dir> && CLAUDE_CONFIG_DIR=~/.claude-<account>
  claude`.
- **Silent stalls on expired login**: a background or Remote Control session
  that outlives its login just stops making progress, no error, no
  notification, it goes quiet mid-task. If a `cdev` session looks idle after
  you've been away a long time (multi-day sleep, vacation), check whether it
  needs `/login` again before assuming something broke. `claude` warns
  in-terminal when a login is within three days of expiring, but that
  warning only shows up if someone's looking at the terminal when it
  appears. `cdev status` does not help here either: it has no login or
  credential column at all, so an expired session looks exactly like a
  healthy one.
- **A stale `cdev` shell function can shadow the real binary**: if this shell
  ever had an older `cdev` sourced into it (from before the switch to a
  `~/.local/bin/cdev` binary, or from a previous install attempt on this same
  box), that function stays loaded in memory for the life of the shell,
  editing files on disk afterward doesn't undo it. Bash checks shell
  functions before `$PATH`, so a stale function silently wins over the
  correct binary, and every subcommand behaves like whatever that old
  function did, an old enough one may not even recognize subcommands at all
  and try to attach to a project literally named `doctor` or `--help`,
  failing with a bare tmux `[exited]`. `cdev` cannot detect this from inside
  itself, a child process can't see the functions defined in the shell that
  launched it. If a command behaves like it's ignoring its own subcommand,
  run `type cdev`: if it says "is a function" instead of pointing at
  `~/.local/bin/cdev`, run `unset -f cdev` in that shell, or just open a new
  one.

## License

[MIT](LICENSE)
