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

## Bigger scale (high effort, changes project philosophy)

These move cdev from a small, predictable single-box tool toward a small
platform. Worth weighing against the "does no dependency on any specific
box" framing in the README before committing to either.

- [ ] Multi-server support: aggregate `cdev-status` across boxes, which needs
      either an SSH fan-out or a lightweight sync of each box's
      `~/.cdev-sessions`. **Deferred** (curated 18 August 2026): needs a new
      "control machine" concept this project doesn't have yet, revisit later.
- [x] Shell support beyond bash: `install.sh` only wires `cdev.sh` into
      `~/.bashrc`. Sourcing it from `~/.zshrc` too needs auditing the script
      for bash-isms that don't hold under zsh. **Scope agreed** (curated 18
      August 2026): `install.sh` detects the active shell and writes the
      `source` line to the matching rc file.
