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
as above. CI uses whatever shellcheck ships preinstalled on the
`ubuntu-latest` runner image rather than installing one via `apt-get`, which
used to be both the source of a real version-drift false positive (SC2015,
fixed in 0.3.0) and the exact command that hung for about 4 hours on 19
August 2026. That means CI's shellcheck version can differ from whatever is
installed locally, since the runner image's version only moves when GitHub
updates it, not on every run, a rare and documented drift rather than the
unpredictable one `apt-get` gave.

A bats-core test suite lives under `test/`, covering only the pieces that
need no live tmux, systemd, or VPS. External commands (`tmux`, `systemctl`,
`sudo`, `loginctl`) are stubbed onto `PATH` by `test/test_helper.bash`, and
every test points `HOME` at a temp directory, so nothing touches the real
registry or this machine's systemd state.

```bash
bats test/            # needs bats-core installed, it is not vendored here
```

- `test/cdev_ensure.bats` registry dedup in `_cdev-ensure`, `_cdev-session-alive`
  distinguishing a dead-but-`remain-on-exit`-held pane from a genuinely live
  one, `_cdev-ensure` killing and recreating a session left in that dead
  state, that it creates the session directory when it doesn't exist, and
  that it `git init`s a brand new one (with a resolvable `HEAD`, not just a
  bare repository) but leaves an already-initialized repository (its
  existing commits included) untouched
- `test/cdev_kill.bats` registry line removal in `_cdev-kill` (the `cdev kill` subcommand)
- `test/account_config_dir.bats` account to `CLAUDE_CONFIG_DIR` mapping
- `test/install_shell_detection.bats` rc file `install.sh` falls back to for
  its `PATH` line when `~/.local/bin` isn't already on `PATH`
- `test/cdev_restore_healthcheck.bats` the registry replay in `_cdev-restore`
  (including that it continues past a failing session) and the opt-in
  webhook gate in `_cdev-healthcheck`, including that it also fires for a
  session held open in a dead state by `remain-on-exit`, not just one that
  vanished outright
- `test/cdev_attach_recovery.bats` `_cdev-attach`'s automatic trust-step
  retry when a session dies immediately (stateful tmux/claude stubs play out
  "created dead, trust step runs, recreated alive" rather than a canned
  single response), that it gives up cleanly if the retry also fails, that
  an already-alive session skips the retry path entirely, never launching
  `claude` at all, and that `_cdev-wait-for-alive` always sleeps before its
  first check rather than trusting an immediate reading (regression test
  for the 0.8.0 race, see `_cdev-session-alive` above)
- `test/dispatcher_flags.bats` flag handling in the `cdev()` dispatcher, and
  the registry-corruption chain it once caused (see the file's own header)
- `test/uninstall.bats` `cdev uninstall`, including that its conservative
  defaults stay conservative (live sessions are left running, the registry
  and notify file survive, linger is never disabled), and specifically that
  it `return`s rather than `exit`s so the calling shell survives it, the
  failure mode a subcommand risks that a standalone script never could
- `test/cdev_doctor_release.bats` `_cdev-doctor`'s `Released:` line sourced
  from `_cdev-latest-tag` (including that GitHub being unreachable degrades
  that one line instead of aborting the rest of the report), and the
  `claude`/`tmux` presence and version checks
- `test/cdev_doctor_repair.bats` the self-heal half of `_cdev-doctor`:
  adopting a live tmux session that isn't in the registry (and leaving an
  already-registered one untouched), and the fix command it prints for a
  disabled systemd unit or disabled linger, distinct from one that was never
  installed

The suite covers the `cdev()` dispatcher only for flag handling, not for
subcommand routing. `_cdev-status` is not covered at all, still hand-verified.

There is no automated way to exercise the install/reboot flow. Verifying a
change means reasoning through the script by hand, or running it against a
real (ideally throwaway) VPS, since `install.sh` runs `sudo loginctl
enable-linger` and installs `systemd --user` units, both of which persist
past the session.

## Architecture

Everything lives in one file, `cdev.sh` (copied to `~/.local/bin/cdev` and
made executable at install time, see the `install.sh` paragraph below).
`cdev()` is the dispatcher and the only function meant to be called
directly, the sole public entrypoint: it routes `cdev open`, `cdev status`,
`cdev kill`, `cdev init`, `cdev accounts`, `cdev doctor`, `cdev upgrade`,
`cdev restore`, `cdev healthcheck`, `cdev uninstall`, `cdev version`, and
`cdev help` to underscore-prefixed internal functions (`_cdev-attach`,
`_cdev-status`, `_cdev-kill`, `_cdev-kill-remove`, `_cdev-init`,
`_cdev-accounts`, `_cdev-doctor`, `_cdev-doctor-unit`, `_cdev-upgrade`,
`_cdev-sha256`, `_cdev-latest-tag`, `_cdev-restore`,
`_cdev-restore-still-registered`, `_cdev-healthcheck`, `_cdev-uninstall`,
`_cdev-help`, `_cdev-format-duration`, `_cdev-config-dir`, `_cdev-ensure`,
`_cdev-ensure-append`, `_cdev-registry-locked`). Bare `cdev <name> [account]
[dir]` is the default action and the primary way to reach `_cdev-attach`:
anything the dispatcher's `case` doesn't recognize as a subcommand word
falls through to it as a project name, created and attached. `cdev open
<name> [account] [dir]` and the older `cdev -- <name> [account] [dir]`
escape hatch reach the same place explicitly, which matters only for a
project name that collides with a reserved subcommand word (`status`,
`kill`, `doctor`, and the rest), exactly the short, ordinary words someone
would plausibly pick for a real project, and the list only grows as more
subcommands get added. That collision is a deliberate, accepted trade-off,
the same one `git` and `npm` make by giving a bare argument their own
default action, not a bug: a 19 August 2026 architecture council pass tried
closing it entirely by making `cdev open` the only path and erroring on
every bare word, and it was reverted the same day, before ever shipping in
a release, because typing `open` for the single most common action read as
unnecessary friction against the small, real risk of a project actually
being named after a reserved word. The leading underscore marks every one
of these as implementation detail, not a supported interface, so nothing
outside `cdev.sh` itself should call them by name. There is no exception any
more: `cdev` is the only function in the file without the underscore
prefix.

- `_cdev-attach` holds the login-then-ensure-then-tmux-attach logic that used
  to live directly in `cdev`. If the first attempt dies immediately, most
  commonly because `dir` was never trusted under an account that is already
  logged in elsewhere (trust is per-directory, not per-account, see
  `_cdev-init` below), it now opens that one-time trust step itself, scoped
  to `dir`, and retries `_cdev-ensure` once automatically, rather than
  printing a fix command and making the user copy it and re-run `cdev`
  themselves. Only gives up, with a message pointing at the same manual
  check, if the retry also fails. Found and fixed the same day as the
  `_cdev-session-alive` bug below, live on a VPS: a brand new project
  directory is exactly the case `cdev <name> [account] [dir]` exists for, so
  this was the common case failing silently, not an edge case.
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
  otherwise downloads that tag's tarball, verifies it against `SHA256SUMS`
  (see below), and runs its `install.sh`. It deliberately does not decide
  which version is newer, comparing version
  strings portably is more machinery than it is worth, so it prints both and
  installs what the project currently publishes. Afterwards it tells the
  user no restart is needed: `cdev` is a plain executable at
  `~/.local/bin/cdev`, not a shell function held in memory, so the next
  `cdev` invocation in any shell, including the one that just ran the
  upgrade, already runs the new content at that same path.
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
  rather than aborting or staying silent. It also reports `claude` and
  `tmux`, presence and version if found, a plain "not found on PATH" if not,
  the two hard requirements cdev never actually checked for before a live
  VPS test surfaced how confusing their absence looked otherwise (a bare
  tmux `[exited]` pane with no context). A `Running from: $0` line confirms
  the report came from the real installed binary; `_cdev-help` prints usage.
  `_cdev-doctor` also self-heals two things rather than only reporting them.
  It adopts any live tmux session missing from the registry (started outside
  `cdev`, or a registry line lost to a manual edit), the same idempotent
  append `_cdev-ensure` already does, since such a session looks fine in
  `cdev status` right up until the box actually reboots and it is simply
  gone, with no warning beforehand. And it prints the exact fix command for
  a disabled `cdev-restore.service`, `cdev-healthcheck.timer`, or disabled
  linger, instead of only naming the problem, which also required fixing
  `_cdev-doctor-unit`'s presence check: `systemctl is-enabled` exits
  non-zero for "disabled" just as much as for a unit that was never
  installed, so the old code, which gated on the exit code alone, silently
  misreported a disabled-but-installed unit as though cdev had never set it
  up at all.
- `_cdev-session-alive` is the fix for a real bug found on a live VPS: `tmux
  has-session` only tells you a session exists, not that its command is
  still running. A pane whose command already died (crash, or the common
  case, an untrusted directory) but is held open by `remain-on-exit` still
  "has" a session under that name, so a bare `has-session` check reads a
  dead leftover exactly like a healthy one. `_cdev-ensure` used to skip
  recreating it, `_cdev-attach` used to reattach straight to the same dead
  pane (a bare tmux `[exited]`, no diagnostic, since that diagnostic only
  ever fired when the session disappeared entirely, which a
  `remain-on-exit` pane never does), and `_cdev-healthcheck` used to never
  flag it as missing either. `_cdev-session-alive` checks `#{pane_dead}` in
  addition to `has-session`, and all three now call it instead of the bare
  check. `_cdev-wait-for-alive` wraps the polling loop (used by
  `_cdev-attach`'s first attempt and its trust-step retry) around it, tries
  and interval overridable via `CDEV_POLL_TRIES`/`CDEV_POLL_INTERVAL` so
  tests don't pay the real 3-second wait, `test/test_helper.bash`'s
  `stub_bin_dir` sets both to run instantly. Its first version, shipped in
  0.7.0, checked immediately with no sleep before the first look, which
  carried its own race live on a VPS the same day: `tmux new-session -d`
  only waits for the pane to fork, not for the command inside to run far
  enough to fail, so a session dying fast (an untrusted directory, exactly
  the case the retry exists for) could still be a few milliseconds from
  exiting at that instant, reading as alive and skipping the whole retry
  path silently. It now sleeps once before every check, first one included,
  not only between retries, closing that window. A stub-based test cannot
  reproduce a real scheduling race, so the regression test for this asserts
  the structural guarantee instead: `_cdev-wait-for-alive` must call
  `sleep` at least once even when a stub reports alive on the very first
  possible check.
- `_cdev-ensure` creates the tmux session and records it in the registry. It
  creates `dir` first if it does not exist yet (tmux refuses a working
  directory that is missing, and the natural way to use `cdev <name>
  [account] [dir]` is for a brand new project that has no directory at
  all), `git init`s it too if it is not already a repository (every session
  is spawned with `--spawn=worktree`, which needs one; found live on a VPS
  the day after the trust-retry fix above shipped: a brand new project,
  exactly the case that fix targets, died right after with "Worktree mode
  requires a git repository", a second, separate failure only visible once
  the trust one was out of the way, since trust is checked first), leaves
  an empty initial commit on that fresh repo too (found on the very next
  live test right after: an empty repo has no commit for `HEAD` to resolve
  to, and `claude`'s own worktree creation needs to resolve `HEAD` as the
  base branch, unlike a plain `git worktree add`, which tolerates a
  commit-less repo by inferring an orphan branch; the commit is made with a
  scoped `-c user.name`/`-c user.email`, not the user's global git config,
  since a fresh box may have no git identity configured yet), and kills a
  same-named session left behind with a dead pane before creating a fresh
  one, `tmux new-session` would otherwise fail with "duplicate
  session" against the leftover. It is also the one function called
  non-interactively, so it must stay safe to run with no attached terminal
  (no prompts, no blocking reads), since the boot path depends on that.
- `_cdev-restore` replays every line of the registry through `_cdev-ensure`.
  This is what the boot path runs. `cdev.sh` can still be sourced directly
  (tests do this, and nothing stops a user from doing the same), and `set -e`
  set inside a sourced file leaks into whatever it was sourced into, so it
  cannot lean on `set -e` the way the old standalone script could; instead
  `_cdev-restore` counts each `_cdev-ensure` failure
  explicitly, keeps going through the rest of the registry so one broken
  session does not block the others, and returns 1 at the end if any failed,
  so systemd still marks the unit failed rather than reporting a clean boot.
- `_cdev-healthcheck` is a separate, opt-in non-interactive check. It
  compares the registry against live tmux sessions (via `_cdev-session-alive`,
  not bare `has-session`, so a crashed session held open by
  `remain-on-exit` is caught too, not just one that vanished outright) and
  reports any session that is no longer actually running without going
  through `cdev kill`. It is silent and a no-op unless `~/.cdev-notify`
  exists.

Both the boot path and the periodic health check are subcommands of `cdev`
rather than standalone scripts, keeping the registry, locking, and
config-dir logic in one file instead of duplicating it across separate
scripts. Now that `cdev` is installed as a plain executable at
`~/.local/bin/cdev` rather than sourced into a shell rc file, each unit's
`ExecStart` calls it directly by its absolute path, `%h/.local/bin/cdev
restore` (and `cdev healthcheck` for the health check unit), no shell
wrapper, no `PATH` lookup, and no login shell to source anything from
first. An earlier version had `cdev.sh` sourced into `~/.bashrc` or
`~/.zshrc` instead, which meant a systemd unit had no shell where `cdev`
was already defined, so `ExecStart` had to source the file itself before
calling the subcommand: `/bin/bash -c "source %h/.cdev.sh && cdev
restore"`. A `$PATH`-resolved binary needs no such step at all, and the
same property is what fixed the friction that motivated dropping the
sourced-function model on 19 August 2026: installing used to leave the
very shell that ran `install.sh` without a working `cdev` until it was
manually re-sourced or a new shell was opened, since a child process can
never inject a function into its parent shell. This is the same
entrypoint a human uses, just invoked non-interactively. `cdev-restore.service`
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

`_cdev-ensure` (appends), `_cdev-kill` (read-modify-write), and
`_cdev-restore` (reads a snapshot, then loops calling `_cdev-ensure`) can all
run concurrently, a human's interactive shell, the boot-time
`cdev-restore.service`, the 5-minute `cdev-healthcheck.timer`, or two
interactive shells at once, so all three now go through
`_cdev-registry-locked`, which runs its arguments under `flock -x` on
`$CDEV_REGISTRY_LOCK`. Without it, an append landing between `_cdev-kill`'s
read and its `mv` gets silently discarded, two concurrent `cdev kill` calls
can resurrect each other's just-removed line, and `cdev restore` can recreate
(and re-append) an entry a human killed after the snapshot was taken but
before the loop reached it; `_cdev-restore-still-registered` guards against
that last one specifically, a locked, read-only registry check `_cdev-restore`
runs immediately before each `_cdev-ensure` call, which narrows that race from
the whole restore run down to one fast file check (not a complete fix, full
transactional locking across both operations would be needed for that).
`flock` is guarded with `command -v`, falling back to running unlocked when
it is absent, because this project's own dev/test machine (macOS) has none
at all while every target VPS does (util-linux ships it), and unlocked is no
worse than before this existed. **Never nest two `_cdev-registry-locked`
calls**: the lock is per open-file-description, not reentrant across nested
subshells on the same process tree, so an outer call would block forever
waiting for an inner call to release a lock it can never acquire. That is
why `_cdev-restore`'s loop runs the still-registered check and `_cdev-ensure`
(which locks internally via `_cdev-ensure-append`) as two separate,
sequential calls rather than one wrapping the other, keep that shape if this
is touched again. `_cdev-kill`'s registry removal, `_cdev-kill-remove`, was
fixed alongside the locking: the old `grep -vF -- "$1 "` matched the name as
a substring anywhere in the line, so killing session `foo` could also
silently drop an unrelated line whose account or dir field merely contained
the literal text `foo ` (a dir `/home/x/foo bar`, say). It now uses
`awk -v name="$1" '$1 != name'`, comparing only the first field with plain
string equality.

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
running `~/.local/bin/cdev`) against the version in whatever `cdev.sh` sits
in `$PWD`, when run from inside this repo's checkout. That comparison is
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
`cdev_latest_tag`), downloads that tag's tarball from GitHub to a file,
verifies it (see below), extracts it to a temp directory with
`--strip-components=1`, and hands over with `CDEV_BOOTSTRAPPED=1 exec bash
"$work/install.sh"`. The mode decision looks for the payload files rather
than inspecting `$0` or `BASH_SOURCE`, deliberately: a payload check reads
the same however the script was invoked, and it is what stops the hand-off
from looping, since the extracted copy does find its own payload and
installs on that pass instead of downloading again. `CDEV_BOOTSTRAPPED` is
the second, belt-and-braces guard against the same loop. Piped installs
require `curl`, `tar`, and either `sha256sum` or `shasum`, and say so
clearly if any is missing.

Both this piped-install path and `_cdev-upgrade` now verify that downloaded
tarball against a `SHA256SUMS` file before extracting anything, downloading
to a file first rather than piping straight into `tar`, since there has to
be something on disk to checksum before it can be unpacked. A checksum
mismatch, or a `SHA256SUMS` that can't be fetched at all, aborts with a
clear message rather than installing anyway. `_cdev-sha256` in `cdev.sh`
(`cdev_sha256` in `install.sh`, same underscore-dash-vs-plain naming split as
`_cdev-latest-tag` / `cdev_latest_tag` above, and for the same reason,
`install.sh` has to work before `cdev.sh` is on the box at all) prefers
`sha256sum` (Linux) and falls back to `shasum -a 256` (macOS), since neither
is guaranteed present on both. `SHA256SUMS` itself is computed in CI (see
Releasing below) from the exact same tarball URL the installer fetches,
rather than trusted from anything GitHub reports about the tarball, which is
what makes it an independent check of the bytes that actually arrived over
the wire rather than a value that could be wrong for the same reason the
download itself could be. Be honest about what this does and does not cover:
it defends against a corrupted or tampered-with download in transit, nothing
more. It does not verify who built the release or that the release pipeline
itself wasn't compromised, that would need signing, which this does not
attempt.

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
`install.sh` and `SHA256SUMS` as assets, automatically, so this is not a
step a maintainer does by hand. The `install.sh` asset is what makes
`/releases/latest/download/install.sh` resolve, which is the documented
one-line install URL. If that workflow ever stops attaching it, the
advertised one-liner 404s for everyone while the release itself still looks
perfectly fine, nothing else in the release process would catch it.
`SHA256SUMS` is computed in the same job, from the same tarball URL
`install.sh` and `cdev upgrade` download, plus a hash of `install.sh` itself,
before either asset is uploaded, see the checksum-verification paragraph
above for why it is computed here rather than trusted from GitHub. The
existing `v0.2.0` tag was pushed before this workflow existed, so it has no
Release object and no assets; the one-line install only starts working from
the next tagged release onward.

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
files: it copies `cdev.sh` into `$HOME/.local/bin/cdev` and makes it
executable, that is the whole install, `cdev` needs no loading step beyond
being on `$PATH`. This replaced a design where `install.sh` copied `cdev.sh`
to the dotfile `~/.cdev.sh` and appended a `source` line to the detected
shell rc file, which had a real, reported problem: a shell function only
becomes callable in shells that source the rc file *after* install, so the
very shell that had just run the installer never got `cdev`, a child process
can never inject a function into its parent shell. That friction was raised
during a live VPS install attempt on 19 August 2026, and a `$PATH`-resolved
executable avoids it structurally rather than working around it: unlike a
shell function, it needs no loading step, it is resolved fresh (or from
bash's per-session path hash, keyed by path not content) on every invocation,
so the very next `cdev` typed, in any shell, already finds it. `install.sh`
also clears `$HOME/.cdev.sh`, `$HOME/.cdev-restore-all.sh`, and
`$HOME/.cdev-healthcheck.sh`, leftovers from the old sourced-function model
and, further back, from an install that used now-deleted standalone scripts,
strips the legacy `source "$HOME/.cdev.sh"` line from both rc files if
present, ensures `~/.local/bin` is actually on `PATH` (appending an `export
PATH=...` line to the detected shell rc file, `~/.zshrc` or `~/.bashrc`,
only if it wasn't already there, which is not the case on stock Ubuntu, the
common target here), and installs all three systemd units. It enables two of
them, `cdev-restore.service` and `cdev-healthcheck.timer`.
`cdev-healthcheck.service` is installed but deliberately not enabled: it has
no `[Install]` section and is activated by its timer, so enabling it
directly would be wrong. Editing `cdev.sh` in this repo has no effect on an
already-installed box until `install.sh` (or a manual copy) runs again, the
two are not symlinked. One concrete benefit of the binary model beyond fixing
that friction: `cdev upgrade` (see below) used to leave the current shell
running stale, already-loaded function definitions until it was re-sourced
or a new shell opened; with a binary, the very next `cdev` invocation in the
same shell already runs the newly-installed content at that same path, no
shell-function staleness is possible.

`_cdev-uninstall` (`cdev uninstall`) reverses exactly that: it disables and
removes the three systemd units and deletes `~/.local/bin/cdev`, the binary
itself, the primary thing it removes now. It also strips two rc-file lines
that only exist on a box carrying leftovers from before the binary model,
the legacy `source "$HOME/.cdev.sh"` line and the `export
PATH="$HOME/.local/bin:$PATH"` line `install.sh` may have added, plus the
legacy dotfiles (`.cdev.sh` and the two standalone-script leftovers).
Neither rc-file line exists on a fresh install where `~/.local/bin` was
already on `PATH`, so that part of uninstall is a migration safety net, not
the primary removal target. Unlike `install.sh` it is a subcommand, not its
own script, because of when each one runs: install has to work before `cdev`
exists on the box, so it must stand alone, while uninstall only ever runs
after `cdev` is already installed, so the code is already there and it needs
no network. That also means it must not use `exit`, every path through it
`return`s instead, since `cdev.sh` can still be sourced directly (the test
suite loads its functions that way, and nothing stops a user from doing the
same), and an `exit` there would close whatever shell it was sourced into.
`test/uninstall.bats` tests this directly. It cleans both `~/.bashrc` and
`~/.zshrc` rather than only the shell detected as current, because
`install.sh` picked the rc file by the shell active at install time, and
someone who has since switched shells would otherwise be left with a
dangling line that errors on every new shell in the file `install.sh` never
touched. It is deliberately conservative about three things an uninstall
could otherwise "helpfully" clean up too far: running tmux sessions are left
alone (uninstalling the launcher is not a reason to
kill live work; `--kill-sessions` opts in), the registry and the notify file
are kept so a reinstall picks up where you left off (`--purge` opts in), and
linger is never disabled since other systemd `--user` services may depend on
it by now (the `sudo loginctl disable-linger` command is printed instead,
left for a human to decide).
