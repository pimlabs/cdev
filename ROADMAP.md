# Roadmap

Curated backlog, not commitments. Grouped by track. See
[README.md](README.md) for current behavior and [CLAUDE.md](CLAUDE.md) for
architecture.

The single-entrypoint track below has shipped. Elsewhere in this document the
older `cdev-status`, `cdev-kill`, `cdev-doctor`-style names are left as
written when each item was curated, read those as the matching `cdev
<subcommand>` today.

## Single entrypoint with subcommands (shipped)

Curated 18 August 2026. At curation time the daily-use surface was five
separate function names (`cdev`, `cdev-init`, `cdev-status`, `cdev-kill`,
`cdev-accounts`), each remembered independently. The plan was to replace them
with one dispatcher, keeping bare `cdev <name> [account] [dir]` as the default
action since that is the one used the most:

```
cdev <name> [account] [dir]      # default: create (if needed) and attach
cdev status                      # list sessions
cdev kill <name>                 # stop + remove from the registry
cdev init <account> <dir>        # one-time login for an account
cdev accounts                    # list configured accounts
cdev doctor                      # compare installed vs repo version, check systemd/linger
cdev version                     # print the installed version
cdev help                        # usage + subcommand list
```

Trade-off to accept: since bare `cdev <name>` stays the default action,
project names can't collide with a subcommand word (`status`, `kill`, `init`,
`accounts`, `doctor`, `version`, `help`). Same pattern `git` and `npm` use.

Ships with:

- [x] A version constant embedded in `cdev.sh` itself, so it travels with the
      copy `install.sh` makes to `~/.cdev.sh`. Exposed via `cdev version`.
- [x] `cdev doctor` compares the installed version against the repo's, not a
      checksum, a version only changes when a maintainer deliberately bumps
      it, so a mismatch means "update available," not "any edit at all."
- [x] `CHANGELOG.md`, paired with every version bump, so a version mismatch
      also answers "what changed," not just "something changed."
- [x] `cdev help` prints the subcommand table above plus the defaults
      (`account` defaults to `personal`, `dir` defaults to
      `~/projects/<name>`), replacing README-reading for day-to-day use.
- [x] `./cdev.sh <args>` also works directly, not only `source cdev.sh` then
      `cdev <args>`, added afterward once local testing without installing
      turned out to need a source step every time.
- [x] Every internal helper renamed with a leading underscore
      (`_cdev-status`, `_cdev-kill`, `_cdev-init`, and so on), so `cdev` is
      the sole function meant to be called directly.
- [x] `uninstall.sh` folded into `cdev uninstall`. It shipped as its own
      script first, then moved once the one-line-install track above made
      the asymmetry obvious: install has to work before `cdev` exists on
      the box, so it must stand alone, but uninstall only ever runs after
      `cdev` is already there, so it never needed to be a separate file.

A pre-merge review pass also found and fixed 3 issues before this track
shipped: a shell-injection path in the tmux launch command, a `cdev-kill`
bug that could wipe the entire registry on a session name grep couldn't
parse, and a false-positive workspace-trust diagnosis on a slow session
start. Full detail in [CHANGELOG.md](CHANGELOG.md).

A follow-up API review after this track shipped found one more exception
worth closing:

- [x] Fold the two standalone scripts, `cdev-restore-all.sh` and
      `cdev-healthcheck.sh`, into `cdev.sh` itself as the `cdev restore` and
      `cdev healthcheck` subcommands, and rename `cdev-ensure` to
      `_cdev-ensure` now that nothing outside `cdev.sh` calls it by name.
      `cdev.sh` is now the single source of truth, and `cdev` is the only
      public function. The systemd units for both now source `~/.cdev.sh`
      and call the subcommand instead of invoking a standalone script.

A 6-reviewer architecture council pass on 19 August 2026 found 4 more issues,
closing the trade-off two paragraphs up for good rather than continuing to
live with it, plus three registry bugs the earlier review passes didn't
catch:

- [x] `cdev open <name> [account] [dir]` replaces bare `cdev <name>` as the
      only path to attach mode, so the "trade-off to accept" above no longer
      applies at all: a project can be named `status`, `doctor`, or any other
      subcommand word and `cdev open <name>` still attaches to it correctly.
      An unrecognized bare word is now a plain error pointing at
      `cdev open`. `cdev -- <name> [account] [dir]` stays working as an
      older, now-secondary equivalent.

      Reverted the same day, before any of this ever shipped in a tagged
      release: typing `open` for the single most common action read as
      unnecessary friction. Bare `cdev <name>` is back as the default attach
      action, matching `v0.2.0`. The "trade-off to accept" two paragraphs up
      is back too, on purpose, reserved subcommand words are matched by
      their own case arm ahead of the bare-word fallthrough, so they stay
      safely reachable directly and can never be shadowed by a same-named
      project. `cdev open <name>` and `cdev -- <name>` remain the two ways
      to attach to a project whose name actually collides with one.
- [x] `_cdev-kill`'s registry removal matched the session name as a
      substring anywhere in the line (`grep -vF -- "$1 "`), not just the
      name field, so killing one session could silently drop an unrelated
      line whose account or dir field happened to contain the same text.
      Rewritten with `awk` matching only the first field.
- [x] Three registry races: an `_cdev-ensure` append landing mid-`_cdev-kill`
      and getting discarded, two concurrent `cdev kill` calls each
      resurrecting the line the other had just removed, and `cdev restore`
      recreating a session a human killed after its snapshot was taken.
      Fixed with `flock`-based locking around every registry read and
      write, falling back to running unlocked when `flock` isn't on `PATH`
      (this project's own dev/test machine has none, every target VPS does,
      it ships in util-linux).
- [x] SHA256SUMS checksum verification for the tarball `install.sh` and
      `cdev upgrade` both download, extending the one-line install track
      below rather than sitting apart from it: computed in CI from the same
      URL the installer fetches, checked before anything is extracted, and
      install aborts with a clear message on a mismatch instead of
      proceeding anyway.

Full detail in [CHANGELOG.md](CHANGELOG.md).

## Known issues (low effort)

Both already documented as pain points in README's "Known issues" section.

- [x] Detect the "Workspace not trusted" failure mode: when a session dies
      immediately after spawn, `cdev` currently leaves the user to notice
      tmux's own `[exited]` with no context. Check session liveness shortly
      after creation and point at the manual fix (`cd <dir> &&
      CLAUDE_CONFIG_DIR=~/.claude-<account> claude`) instead.
- [ ] Surface login-expiry warnings outside the terminal. Claude already
      warns in-terminal within three days of expiry, but only if someone is
      looking. Nothing currently propagates that into `cdev-status` or an
      out-of-band notification, so a session can go quiet for days with no
      visible signal.

## Observability (low-medium effort)

Natural extension of `cdev-status`, which at curation time only showed name,
account, and attach state.

- [x] Add per-session uptime (tmux session start time) to `cdev-status`.
- [ ] Add per-account login-expiry countdown to `cdev-status`. Not done: a
      LOGIN column was tried and then removed entirely, since it printed the
      literal word `unknown` on every single run and carried no information.
      Still pending a safe way to read Claude Code's local credential expiry
      before this column comes back for real.
- [x] Optional webhook/ntfy notification when a session disappears from tmux
      unexpectedly (crash) versus a clean `cdev-kill`.

## Maintainability (medium effort)

About keeping the project easy to work on, not new user-facing behavior.

- [x] Run `shellcheck` in CI on every push/PR (already used ad hoc locally,
      see [CLAUDE.md](CLAUDE.md)).
- [x] Add a `bats-core` test suite for the pieces that don't need a live
      tmux/VPS: registry dedup in `cdev-ensure`, line removal in
      `cdev-kill`, account-to-config-dir mapping.
- [x] Surfacing a stale install is covered by `cdev doctor` in the
      single-entrypoint track above, superseded there.

## Distribution: one-line install (shipped)

Curated 19 August 2026. Installing before this meant `git clone` first,
which meant a fresh VPS needed `git` before it could install a tool that
otherwise only needs `tmux` and `curl`. The target was the pattern rustup,
Homebrew, Bun, Deno, uv, Docker, Tailscale, and k3s all use:

```
curl -fsSL https://cdev.pimlabs.id/install | bash
```

The last three were the relevant precedent: they also need root and also
install system services, so the fact that `install.sh` runs `sudo loginctl
enable-linger` was not a reason to avoid this.

- [x] Make `install.sh` work in two modes. It used to copy its sibling
      files via `$SCRIPT_DIR`, which does not exist when the script is
      piped into bash. Piped, it downloads the release tarball and installs
      from that; from a checkout it keeps working exactly as before.
- [x] Attach `install.sh` as a release asset, so
      `github.com/pimlabs/cdev/releases/latest/download/install.sh` always
      resolves to the newest release. That is what makes the front door a
      one-time setup instead of something to update on every tag.
- [x] Add `cdev upgrade`. Without a checkout there is no `git pull`, so
      there is now a supported way to move to a newer version.
- [x] Change `_cdev-doctor`'s version comparison to check the latest release
      tag on GitHub rather than only a `cdev.sh` in `$PWD`. This closes the
      part that used to silently break: with no checkout the old comparison
      was skipped and doctor reported nothing at all, which read as "up to
      date".

Two constraints worth writing down. The URL must resolve to a tagged
release, never to `main`, since piping a moving branch into a shell with
sudo access is a far bigger ask than piping a fixed one. And the DNS
redirect from `cdev.pimlabs.id` to the GitHub URL is not a blocker: the
installer works through the GitHub URL from day one, and the subdomain is
a nicer front door that can be pointed at it whenever.

One piece remains, and it is not code: pointing `cdev.pimlabs.id` at the
GitHub URL is a DNS record the user still has to set up, outside this repo.
Until then, `curl -fsSL https://github.com/pimlabs/cdev/releases/latest/download/install.sh | bash`
is the working one-liner. Also worth knowing: the existing `v0.2.0` tag was
pushed before the release workflow existed, so it has no release asset.
The one-liner starts working from the next tagged release onward.

The 19 August 2026 architecture council pass under the single-entrypoint
track above added checksum verification to this download: both the piped
install and `cdev upgrade` now check the tarball against a `SHA256SUMS`
release asset before extracting it.

A second 19 August 2026 pass, discovered live during an actual VPS install
attempt, replaced the sourced-function model entirely. `install.sh` used to
copy `cdev.sh` to `~/.cdev.sh` and append `source "$HOME/.cdev.sh"` to
`~/.bashrc` or `~/.zshrc`. A shell function only becomes callable in shells
that source the rc file *after* install, so the very shell that had just run
the installer never got `cdev`, a child process can never inject a function
into its parent shell. Every install ended with "now run `source
~/.cdev.sh` or open a new shell," which read as non-standard friction, even
though rustup, nvm, and Bun have the identical limitation for the identical
reason.

- [x] Install `cdev` as a plain executable at `~/.local/bin/cdev`
      (`chmod +x`, the same `#!/usr/bin/env bash` shebang `cdev.sh` already
      had) instead of copying it to a dotfile and sourcing it. `~/.local/bin`
      is on `PATH` by default on stock Ubuntu, the common target here, so a
      command resolved off `PATH` needs no loading step the way a shell
      function does, it is looked up fresh (or from bash's per-session path
      hash, keyed by path, not content) on every invocation. The next `cdev`
      typed, in the same shell that just ran the installer, already finds it.
- [x] Fall back to appending `export PATH="$HOME/.local/bin:$PATH"` to the
      detected shell rc file when `~/.local/bin` isn't already on `PATH`,
      idempotently, only in that case, so the common case (already on
      `PATH`) gets no rc-file edit and no restart instruction at all.
- [x] Migrate a box installed under the old model automatically: `install.sh`
      (which `cdev upgrade` re-runs) now removes `~/.cdev.sh` and strips the
      legacy `source` line from both rc files if present, so an upgrade
      leaves nothing dangling behind.
- [x] Point `cdev-restore.service` and `cdev-healthcheck.service` at the
      binary's absolute path (`%h/.local/bin/cdev restore` /
      `... healthcheck`) directly, dropping the `/bin/bash -c "source
      %h/.cdev.sh && cdev ..."` wrapper the sourced-function model needed.
      systemd never read the shell rc file anyway, so this was always a
      workaround for `cdev` not existing as a callable command yet, and a
      `$PATH`-resolved binary makes the workaround unnecessary rather than
      fixing it in place.
- [x] Update `_cdev-uninstall` to remove the binary as the primary target,
      keeping the rc-file line stripping only as a migration safety net for
      a box still carrying leftovers from the old model.

One bonus fell out of this for free rather than needing its own work:
`cdev upgrade` used to leave the current shell running the old, already-
loaded function definitions until it was re-sourced or a new shell opened,
since replacing `~/.cdev.sh` on disk does nothing to a shell that already
parsed the old copy into memory. With a binary, the very next `cdev`
invocation in the same shell already runs the newly-installed content at
that same path, same file, new bytes, no separate reload step, and no
staleness window is possible.

The very next live-VPS test after that migration landed found the leftover
edge case it created: a shell that had an older `cdev` sourced into it
before the binary switch keeps that function loaded in memory for the life
of the shell, and bash checks functions before `$PATH`, so the stale
function silently wins over the correct binary. On this project's own test
VPS the leftover function predated even the single-entrypoint refactor, old
enough to have no subcommand dispatch at all, so every subcommand, `doctor`
included, was treated as a project name to attach to, failing with a bare
tmux `[exited]`.

- [x] `cdev doctor` now reports `claude` and `tmux` presence and version,
      both hard requirements it never actually checked before, so their
      absence gets a plain answer instead of surfacing later as a confusing
      mid-session failure.
- [x] `cdev doctor` prints a `Running from:` line, the exact path it
      executed from, confirming a report came from the real installed
      binary.
- [x] Documented the stale-function-shadowing failure mode itself in
      README's Known issues, `cdev` cannot detect it from inside itself (a
      child process can't see the calling shell's function table), so this
      is a documented `type cdev` / `unset -f cdev` fix rather than an
      auto-detected one, the same shape as the other two Known issues above.

## Bigger scale (high effort, changes project philosophy)

This moves cdev from a small, predictable single-box tool toward a small
platform. Worth weighing against the "no dependency on any specific box"
framing in the README before committing to it.

- [x] Shell support beyond bash: `install.sh` only wires `cdev.sh` into
      `~/.bashrc`. Sourcing it from `~/.zshrc` too needs auditing the script
      for bash-isms that don't hold under zsh. **Scope agreed** (curated 18
      August 2026): `install.sh` detects the active shell and writes the
      `source` line to the matching rc file.

## Considered and dropped

Kept here rather than deleted, so the reasoning does not get lost and the
idea does not come back around as if it were new.

- **Multi-server support**, an aggregated `cdev status` across boxes, backed
  by an SSH fan-out or a synced copy of each box's `~/.cdev-sessions`.
  Deferred 18 August 2026, dropped 19 August 2026. It turned out to be
  solving problems that are already solved elsewhere. The "see all my
  sessions at once" case is handled by claude.ai/code itself, which already
  lists every Remote Control session for an account regardless of which box
  it runs on, and does it better than a terminal table could. The "tell me
  when one dies" case is handled by `cdev healthcheck`, which already puts
  the hostname in its webhook message, so several boxes pointed at one
  webhook already give a fleet-wide view with no new concept. What would be
  left is fleet config management, checking unit health and version drift
  across boxes, and that is an Ansible or ssh-loop job, not something cdev
  should grow a control-machine concept for.
