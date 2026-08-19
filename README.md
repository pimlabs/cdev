# cdev

Persistent, multi-account Claude Code sessions on any server, over tmux.
Survives SSH disconnects, laptop sleep, and reboots. Originally built for a
single VPS, split out here because it has no dependency on that VPS or any
specific project, install it on whichever box you want to develop from.

## Requirements

`tmux`, installed first if it's not already on the box:

```bash
sudo apt install -y tmux
```

## Install

```bash
git clone https://github.com/pimlabs/cdev.git
cd cdev
./install.sh
source ~/.cdev.sh
```

`install.sh` copies `cdev.sh` to `~/.cdev.sh`, detects whether the login
shell is zsh or bash and sources it from the matching rc file (`~/.zshrc` or
`~/.bashrc`), and installs three `systemd --user` units. Everything, the
interactive commands, the boot-time restore, and the health check, lives in
that one `cdev.sh`, dispatched through `cdev restore` and `cdev healthcheck`
the same way a human would call `cdev status`. It enables
`cdev-restore.service`, which recreates every registered session
automatically after a reboot with no manual step, and
`cdev-healthcheck.timer`, which drives `cdev-healthcheck.service` on a 5
minute interval (that one stays silent until you opt in, see below). It also
runs `sudo loginctl enable-linger` so those units can start before any
interactive login.

## Commands

`cdev` is a single entrypoint, `cdev <subcommand> ...`. Anything that isn't a
recognized subcommand falls through to the default action, attaching to (or
creating) a project session.

| Command | Does |
|---|---|
| `cdev <name> [account] [dir]` | Default action. Create (if new) and attach to a session. Account defaults to `personal`, maps to `~/.claude-<account>`. Logs the account in first if it never has been. If the session exits immediately because the account isn't trusted in `dir` yet, `cdev` now detects that and prints the fix directly, instead of leaving a bare tmux `[exited]` with no explanation. |
| `cdev status` | List running sessions with their account, attach state, and session uptime. There is no login/credential column: cdev does not read Claude Code's local credential expiry, so it cannot tell a logged-in session from an expired one. |
| `cdev kill <name>` | Stop a session and remove it from the reboot registry. |
| `cdev init <account> <dir>` | One-time interactive login for an account, run inside `<dir>` so the trust dialog applies to that project, not `$HOME`. No-ops if it's already logged in. Runs automatically from `cdev` when needed. |
| `cdev accounts` | List which `~/.claude*` config dirs (accounts) exist. |
| `cdev doctor` | Check install health: installed vs repo version, whether the systemd units are enabled/active, and whether linger is on. |
| `cdev restore` | Recreate every registered session. Run automatically at boot by `cdev-restore.service`; safe to run by hand too, it no-ops on sessions that already exist. |
| `cdev healthcheck` | Report registered sessions that vanished from tmux without going through `cdev kill`. Run every 5 minutes by `cdev-healthcheck.timer`; silent unless `~/.cdev-notify` holds a webhook URL. |
| `cdev version` | Print the installed cdev version. |
| `cdev help` | Show usage and the subcommand list. |

A project name can't collide with a subcommand word (`status`, `kill`, `init`,
`accounts`, `doctor`, `restore`, `healthcheck`, `version`, `help`), the same
convention `git` and `npm` use. If it does, force attach mode with
`cdev -- <name> [account] [dir]`.

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
2. Find the session by the name you gave it, that's the first argument you
   passed to `cdev`. Sessions show a computer icon with a green dot when
   online.
3. Tap in to watch progress live or send a message, it stays in sync with
   whatever's happening in the server's terminal.

If a session doesn't show up, double check you're looking at the right
account (`personal` sessions only appear in the personal account's list,
`work` sessions only in that one) and that the systemd unit / tmux session
is actually running (`cdev status` on the server).

## Basic tmux, if you're not used to it

`cdev <name>` attaches you to the session's terminal. To leave it running
and get your shell back:

```
Ctrl+b, then d
```

That detaches without stopping anything, running `cdev <name>` again later
reattaches to the same session. Closing the terminal window or losing the
SSH connection does the same thing by accident, tmux keeps the session
alive either way.

## Reboot recovery

`cdev` appends every session it creates to `~/.cdev-sessions` (one line:
`name account dir`). `cdev kill` removes the matching line so a
deliberately-stopped session doesn't come back. `cdev restore` reads that
file and recreates each entry the same way `cdev` does when it creates a new
session, just without attaching; `cdev-restore.service` runs it once at
boot, by sourcing `~/.cdev.sh` and calling `cdev restore` directly. A
session that stops some other way (server reboot, crash) stays in the
registry and gets recreated automatically the next time the box comes up.
`cdev restore` is also safe to run by hand at any time, it no-ops on
sessions that already exist and only reports a failure for the ones that
didn't come up.

## Health-check notifications (optional)

`cdev-healthcheck.timer` runs every 5 minutes and drives
`cdev-healthcheck.service`, which sources `~/.cdev.sh` and calls
`cdev healthcheck`. That compares the registry against the tmux sessions
actually running. If a registered session vanished without going through
`cdev kill` (a crash, an OOM kill, anything other than a deliberate stop),
it POSTs a plain-text message describing which session disappeared to a
webhook URL.

This is opt-in and silent by default. To turn it on, write the webhook URL
into `~/.cdev-notify`, one line, nothing else to configure. If that file
doesn't exist, the health check exits immediately and does nothing.

## Known issues

- **`Error: Workspace not trusted`** when a fresh account tries to start
  `claude remote-control`: Claude Code's first-run trust dialog is never
  saved for a home directory, on purpose. `cdev` now detects this failure
  automatically (the session exits immediately, `cdev` notices and prints
  the fix instead of leaving a bare tmux `[exited]`). `cdev init` still runs
  the login step inside the target project directory for the same reason,
  if it instead ran wherever the SSH session happened to land (typically
  `$HOME`), login would "succeed" but the project directory would still come
  up untrusted the moment `remote-control` tried to start there. An account
  whose config dir already got created by a broken earlier attempt won't get
  walked through `cdev init` again since it looks already-initialized. Fix
  by hand once: `cd <dir> && CLAUDE_CONFIG_DIR=~/.claude-<account> claude`,
  accept the trust prompt, exit, then retry `cdev`.
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
