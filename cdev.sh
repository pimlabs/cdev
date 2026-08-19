#!/usr/bin/env bash
# Persistent, multi-account Claude Code sessions on this VPS.
# Sourced from the shell rc file at install time. Single entrypoint: `cdev
# <subcommand> ...` dispatches to the underscore-prefixed functions below,
# which are implementation detail and not meant to be called directly. The
# systemd units call `cdev restore` and `cdev healthcheck` the same way a
# human would, after sourcing this file.

CDEV_VERSION="0.2.0"
CDEV_REGISTRY="$HOME/.cdev-sessions"
CDEV_REPO="${CDEV_REPO:-pimlabs/cdev}"

# Map an account to its CLAUDE_CONFIG_DIR. 'personal' uses ~/.claude, any
# other account uses ~/.claude-<account>. One helper so _cdev-ensure,
# _cdev-init, and _cdev-attach can't drift from each other on this mapping.
_cdev-config-dir() {
  local account="${1:-personal}"
  if [ "$account" = "personal" ]; then
    echo "$HOME/.claude"
  else
    echo "$HOME/.claude-$account"
  fi
}

# Create the tmux + Remote Control session if it doesn't already exist, and
# record it in the registry. Does not attach, so it is safe to call with no
# terminal attached, which is what the boot path depends on.
_cdev-ensure() {
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir
  config_dir=$(_cdev-config-dir "$account")

  if ! tmux has-session -t "$name" 2>/dev/null; then
    # Passed as separate argv items, plus -e for the env var, rather than one
    # interpolated string: tmux execs a multi-argument command directly with
    # no shell involved, so a name or account containing quotes/semicolons/etc
    # can't break out into arbitrary shell execution (requires tmux >= 3.2
    # for -e on new-session).
    if ! tmux new-session -d -s "$name" -c "$dir" -e "CLAUDE_CONFIG_DIR=$config_dir" \
      claude remote-control --name "$name" --spawn=worktree; then
      # tmux itself refused (no server, name clash, tmux older than 3.2).
      # Report it and skip the registry write rather than recording a
      # session that was never created.
      echo "cdev: failed to create tmux session '$name'" >&2
      return 1
    fi
    tmux set-environment -t "$name" CDEV_ACCOUNT "$account"
  fi

  touch "$CDEV_REGISTRY"
  # The `--` matters: without it a registry line starting with a dash makes
  # grep read the line as its own options, fail, and take the `||` branch,
  # so the line is appended again on every single call. Paired with
  # _cdev-restore reading this same file line by line, that turns into a
  # loop that never ends and a registry that grows without limit.
  grep -qxF -- "$name $account $dir" "$CDEV_REGISTRY" ||
    echo "$name $account $dir" >> "$CDEV_REGISTRY"
}

# One-time interactive login for an account, run inside the target project
# directory. Claude Code's first-run trust dialog is never saved for $HOME,
# so this has to happen in $dir, not wherever the SSH session happens to
# land, or the login "succeeds" but the project still isn't trusted. Safe to
# call again, no-ops if the account's config dir already exists. Deliberately
# NOT called from _cdev-ensure: that path also runs at boot with no attached
# terminal, and an interactive login/trust prompt there would just hang the
# restore service.
_cdev-init() {
  local account="${1:?Usage: cdev init <account> <dir>}"
  local dir="${2:?Usage: cdev init <account> <dir>}"
  local config_dir
  config_dir=$(_cdev-config-dir "$account")

  if [ -d "$config_dir" ]; then
    echo "Account '$account' already initialized ($config_dir)."
    return 0
  fi

  echo "No login yet for account '$account', starting one-time login in $dir..."
  ( cd "$dir" && CLAUDE_CONFIG_DIR="$config_dir" claude )
}

# Interactive entry point: log the account in first if needed, ensure the
# session exists, then attach to it. This is the default action of the
# `cdev` dispatcher, so `cdev <name> [account] [dir]` still works as before.
_cdev-attach() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev <project-name> [account] [dir]"
    return 1
  fi
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir
  config_dir=$(_cdev-config-dir "$account")
  [ -d "$config_dir" ] || _cdev-init "$account" "$dir"

  local was_running=0
  tmux has-session -t "$name" 2>/dev/null && was_running=1
  _cdev-ensure "$name" "$account" "$dir"

  # Only pay for the liveness check on a session this call actually created.
  # A session that was already up cannot be failing at spawn time, so
  # checking before every reattach would tax the common case for nothing.
  # Poll instead of one fixed sleep: a slow/cold-start VPS can take longer
  # than a single early check to get past claude's own startup, and a blind
  # 1s sleep would misdiagnose that as an untrusted-directory failure. The
  # printed fix is shell-quoted so it survives copy-paste.
  if [ "$was_running" -eq 0 ]; then
    local tries=0
    until tmux has-session -t "$name" 2>/dev/null || [ "$tries" -ge 6 ]; do
      sleep 0.5
      tries=$((tries + 1))
    done
    if ! tmux has-session -t "$name" 2>/dev/null; then
      echo "Session '$name' isn't running, it most likely exited immediately"
      echo "because account '$account' isn't trusted in '$dir' yet."
      echo "Fix: cd '$dir' && CLAUDE_CONFIG_DIR='$config_dir' claude"
      echo "Accept the trust prompt, exit, then retry cdev."
      return 1
    fi
  fi

  tmux attach -t "$name"
}

# List the per-account config dirs that exist. Uses find rather than a glob
# on purpose: install.sh now sources this file from ~/.zshrc for zsh users,
# and under zsh's default nomatch an unmatched .claude-* glob aborts the
# command with "no matches found" instead of expanding to nothing, so a box
# with only ~/.claude and no other account would print an error and list
# nothing.
_cdev-accounts() {
  find "$HOME" -maxdepth 1 \( -type d -o -type l \) \
    \( -name '.claude' -o -name '.claude-*' \) 2>/dev/null | sort
}

# Format a duration in seconds as a short human string, e.g. '3d 4h', '12h',
# '45m'. Used by _cdev-status for the UPTIME column.
_cdev-format-duration() {
  local secs="${1:-0}"
  local days=$(( secs / 86400 ))
  local hours=$(( (secs % 86400) / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))

  if [ "$days" -gt 0 ]; then
    printf '%dd %dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh' "$hours"
  else
    printf '%dm' "$mins"
  fi
}

# List live sessions with account, attach state, and uptime.
_cdev-status() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null)
  if [ -z "$sessions" ]; then
    echo "No cdev sessions running."
    return
  fi
  printf '%-20s %-14s %-10s %-8s\n' "SESSION" "ACCOUNT" "ATTACHED" "UPTIME"
  echo "$sessions" | while IFS='|' read -r s att created; do
    local acct uptime_secs uptime
    acct=$(tmux show-environment -t "$s" CDEV_ACCOUNT 2>/dev/null | cut -d= -f2)
    [ "$att" = "1" ] && att="yes" || att="no"
    uptime_secs=$(( $(date +%s) - created ))
    uptime=$(_cdev-format-duration "$uptime_secs")
    printf '%-20s %-14s %-10s %-8s\n' "$s" "${acct:-personal}" "$att" "$uptime"
  done
}

# Kill a session AND remove it from the registry, so it does not come back
# on the next reboot. A session stopped some other way (crash, VPS restart)
# stays in the registry and gets recreated by `cdev restore`.
_cdev-kill() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev kill <project-name>"
    return 1
  fi
  tmux kill-session -t "$1" 2>/dev/null && echo "Session '$1' killed." || echo "Session '$1' not found."
  # grep -v into a temp file, then replace: portable across BSD and GNU
  # sed/grep, unlike `sed -i` whose in-place flag takes a mandatory backup
  # suffix argument on BSD sed (macOS) and none on GNU sed, so a single
  # `sed -i EXPR FILE` invocation cannot work on both. -F matches the name
  # as a literal string, not a regex: a name containing regex metacharacters
  # (brackets, dots, etc.) used to make grep fail to parse the pattern and
  # write nothing, which the unconditional mv below then turned into wiping
  # every other session out of the registry. The exit-status check below is
  # belt and suspenders in case grep still errors for some other reason.
  if [ -f "$CDEV_REGISTRY" ]; then
    grep -vF -- "$1 " "$CDEV_REGISTRY" > "$CDEV_REGISTRY.tmp"
    local grep_status=$?
    if [ "$grep_status" -le 1 ]; then
      mv "$CDEV_REGISTRY.tmp" "$CDEV_REGISTRY"
    else
      rm -f "$CDEV_REGISTRY.tmp"
    fi
  fi
}

# Recreate every registered session. Run at boot by cdev-restore.service,
# and safe to run by hand since _cdev-ensure no-ops on sessions that are
# already up. This file is sourced into an interactive shell, so it can't
# lean on `set -e` the way a standalone script would; the loop therefore
# handles a failing session explicitly. One session that can't come up must
# not stop the others from being restored, so the failure is counted and
# the loop continues, with a non-zero return at the end so systemd still
# marks the unit failed rather than reporting a clean boot.
_cdev-restore() {
  [ -f "$CDEV_REGISTRY" ] || return 0

  # Iterate over a snapshot, not over the live file. _cdev-ensure appends to
  # the registry, so reading the file directly means the loop can be fed by
  # its own writes and never reach the end.
  local snapshot name account dir failed=0
  snapshot=$(cat "$CDEV_REGISTRY")
  while read -r name account dir; do
    [ -z "$name" ] && continue
    if ! _cdev-ensure "$name" "$account" "$dir"; then
      failed=$((failed + 1))
    fi
  done <<< "$snapshot"

  if [ "$failed" -gt 0 ]; then
    echo "cdev restore: $failed session(s) failed to restore" >&2
    return 1
  fi
}

# Notice when a registered session disappeared unexpectedly (a crash), as
# opposed to a clean `cdev kill`, which already removes its own registry
# line so it is never flagged as missing. Opt-in and silent by default:
# does nothing unless ~/.cdev-notify holds a webhook URL. Run every 5
# minutes by cdev-healthcheck.timer, safe to run by hand too.
_cdev-healthcheck() {
  [ -f "$CDEV_REGISTRY" ] || return 0

  local notify_file="$HOME/.cdev-notify"
  [ -s "$notify_file" ] || return 0
  local webhook_url
  webhook_url="$(head -n 1 "$notify_file")"
  [ -n "$webhook_url" ] || return 0

  # Without tmux on PATH every has-session below fails, which would read as
  # "every registered session crashed" and fire one webhook per line. That
  # is a broken check, not a finding, so stop quietly instead. Worth
  # guarding even though tmux is a hard requirement of cdev: this also runs
  # from a systemd --user unit, whose PATH is not the login shell's.
  command -v tmux >/dev/null 2>&1 || return 0

  local host now name account _dir message
  host="$(hostname 2>/dev/null || echo unknown-host)"
  now="$(date -u +%H:%M 2>/dev/null || echo '??:??')"

  while read -r name account _dir; do
    [ -z "$name" ] && continue
    if ! tmux has-session -t "$name" 2>/dev/null; then
      message="cdev: session '$name' (account $account, box $host) disappeared unexpectedly at $now UTC. Registry still lists it; run 'cdev status' to confirm, or 'cdev $name' to respawn."
      # A webhook that is down is not a reason to skip the remaining
      # sessions, and its response body is noise in the journal every 5
      # minutes, so the call is silenced and its failure swallowed.
      curl -fsS -X POST "$webhook_url" -H 'Content-Type: text/plain' -d "$message" >/dev/null 2>&1 || true
    fi
  done < "$CDEV_REGISTRY"
}

# Resolve the newest release tag by following the redirect that
# /releases/latest issues to /releases/tag/<tag>. No JSON to parse without
# jq, and no unauthenticated API rate limit to hit. install.sh carries its
# own copy of this: it has to run before cdev.sh is installed, so the two
# cannot share it.
_cdev-latest-tag() {
  command -v curl >/dev/null 2>&1 || return 1
  local url tag
  url=$(curl -fsSL --connect-timeout 3 --max-time 10 -o /dev/null \
    -w '%{url_effective}' "https://github.com/$CDEV_REPO/releases/latest") || return 1
  tag="${url##*/tag/}"
  case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$tag" ;;
    *) return 1 ;;
  esac
}

# Move this box to the latest release. Exists because an install made with
# `curl ... | bash` has no checkout, so there is no `git pull` to run.
_cdev-upgrade() {
  for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "cdev upgrade: $cmd is required." >&2
      return 1
    }
  done

  local tag
  tag=$(_cdev-latest-tag) || {
    echo "cdev upgrade: could not reach GitHub to check for a release." >&2
    return 1
  }

  if [ "$tag" = "v$CDEV_VERSION" ]; then
    echo "Already on the latest release (cdev $CDEV_VERSION)."
    return 0
  fi

  # Deliberately not deciding which of the two is newer. Comparing version
  # strings portably is more machinery than it is worth here, and "install
  # what the project currently publishes" is a defensible answer either way,
  # so the versions are printed and the user can stop if that is not what
  # they wanted.
  echo "Installed: cdev $CDEV_VERSION"
  echo "Latest release: $tag"
  echo "Installing $tag..."

  local work
  work=$(mktemp -d) || return 1

  if ! curl -fsSL --connect-timeout 5 --max-time 120 \
    "https://github.com/$CDEV_REPO/archive/refs/tags/$tag.tar.gz" |
    tar -xz -C "$work" --strip-components=1; then
    echo "cdev upgrade: could not download or unpack $tag." >&2
    rm -rf "$work"
    return 1
  fi

  if [ ! -f "$work/install.sh" ]; then
    echo "cdev upgrade: the $tag tarball has no install.sh." >&2
    rm -rf "$work"
    return 1
  fi

  ( cd "$work" && bash ./install.sh )
  local status=$?
  rm -rf "$work"

  if [ "$status" -eq 0 ]; then
    echo ""
    echo "Upgraded. This shell still holds the old functions, open a new one"
    echo "or run 'source ~/.cdev.sh' to pick up $tag."
  fi
  return "$status"
}

# Print one line of _cdev-doctor's systemd unit report for $1, given that
# systemctl is already known to exist. `is-active` exits non-zero for a unit
# that is merely inactive, so it gets `|| true`: the word it prints is the
# answer we want, not an error. Factored out so this handling only needs to
# be right in one place as more units get added.
_cdev-doctor-unit() {
  local unit="$1" enabled active
  if enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null); then
    active=$(systemctl --user is-active "$unit" 2>/dev/null) || true
    echo "$unit: $enabled, ${active:-unknown}"
  else
    echo "$unit: not installed"
  fi
}

# Report install health: version, matching systemd units, and linger state.
# Every systemctl/loginctl call is guarded so a machine without systemd, or
# without a given unit installed, doesn't crash the function.
_cdev-doctor() {
  echo "Installed: cdev $CDEV_VERSION (~/.cdev.sh)"

  # The $PWD comparison only ever helps someone developing in a checkout,
  # and it is skipped silently everywhere else. An install made with
  # `curl ... | bash` has no checkout at all, so the released version has to
  # come from GitHub or doctor would report nothing and read as up to date.
  if [ -f "./cdev.sh" ]; then
    local repo_version
    repo_version=$(grep '^CDEV_VERSION=' "./cdev.sh" | head -n1 | sed -E 's/CDEV_VERSION="?([^"]*)"?/\1/')
    if [ -n "$repo_version" ]; then
      echo "Repo:      cdev $repo_version (this checkout)"
      if [ "$repo_version" != "$CDEV_VERSION" ]; then
        echo "Versions differ, run ./install.sh again to update."
      fi
    fi
  fi

  local latest
  if latest=$(_cdev-latest-tag); then
    echo "Released:  cdev ${latest#v}"
    if [ "$latest" != "v$CDEV_VERSION" ]; then
      echo "A different version is published, run 'cdev upgrade' to move to $latest."
    fi
  else
    # Offline, no curl, or no releases yet. Not a fault worth an error, but
    # not something to leave looking like a clean bill of health either.
    echo "Released:  could not check (no network, no curl, or no release yet)"
  fi

  echo ""

  # Absent systemd and an uninstalled unit are two different answers, so
  # check for the binary once rather than reporting "not installed" for
  # every unit on a box that could never have installed them. `is-active`
  # exits non-zero for a unit that is merely inactive, so it gets `|| true`:
  # the word it prints is the answer we want, not an error.
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "cdev-restore.service: no systemd on this box"
    echo "cdev-healthcheck.timer: no systemd on this box"
  else
    _cdev-doctor-unit cdev-restore.service
    _cdev-doctor-unit cdev-healthcheck.timer
  fi

  local linger
  if ! command -v loginctl >/dev/null 2>&1; then
    echo "loginctl linger: no loginctl on this box"
  elif linger=$(loginctl show-user "$(whoami)" -p Linger 2>/dev/null); then
    if [ "$linger" = "Linger=yes" ]; then
      echo "loginctl linger: enabled"
    else
      echo "loginctl linger: disabled"
    fi
  else
    echo "loginctl linger: unknown"
  fi
}

_cdev-help() {
  echo "cdev $CDEV_VERSION"
  echo ""
  cat <<'EOF'
Usage: cdev <name> [account] [dir]
  Attaches to (creating if needed) a persistent session for <name>.
  account defaults to 'personal', mapping to ~/.claude-<account>.
  dir defaults to ~/projects/<name>.
  If <name> collides with a subcommand word below, force attach mode with
  `cdev -- <name> [account] [dir]`.

Subcommands:
  status                   List running sessions with account, attach state,
                           and uptime.
  kill <name>              Kill a session and remove it from the reboot
                           registry.
  init <account> <dir>     One-time interactive login/trust setup for an
                           account.
  accounts                 List configured account config directories.
  doctor                   Show install version and systemd/linger health.
  upgrade                  Install the latest release. For installs made with
                           the one-line curl command, which have no checkout
                           to git pull.
  restore                  Recreate every registered session. Run at boot by
                           cdev-restore.service, safe to run by hand.
  healthcheck              Report registered sessions that vanished from tmux.
                           Run every 5 minutes by cdev-healthcheck.timer, and
                           silent unless ~/.cdev-notify holds a webhook URL.
  version (--version, -v)  Print the installed cdev version.
  help (--help, -h)        Show this message.
EOF
}

# Single entrypoint. Routes to the functions above; anything not recognized
# as a subcommand falls through to _cdev-attach, so `cdev <name> ...` still
# works exactly as the old top-level `cdev` function did.
cdev() {
  local sub="${1:-}"
  case "$sub" in
    --)
      shift
      _cdev-attach "$@"
      ;;
    status)
      shift
      _cdev-status "$@"
      ;;
    kill)
      shift
      _cdev-kill "$@"
      ;;
    init)
      shift
      _cdev-init "$@"
      ;;
    accounts)
      shift
      _cdev-accounts "$@"
      ;;
    doctor)
      shift
      _cdev-doctor "$@"
      ;;
    upgrade)
      shift
      _cdev-upgrade "$@"
      ;;
    restore)
      shift
      _cdev-restore "$@"
      ;;
    healthcheck)
      shift
      _cdev-healthcheck "$@"
      ;;
    version|--version|-v)
      echo "cdev $CDEV_VERSION"
      ;;
    help|--help|-h|"")
      _cdev-help
      ;;
    -*)
      # Anything else that looks like a flag is a typo, not a project. The
      # fallthrough below would otherwise treat it as a session name and
      # register it, which is how `cdev --version` used to end up in the
      # registry as a project called "--version".
      echo "cdev: unknown option '$sub'" >&2
      echo "Run 'cdev help' for usage, or 'cdev -- $sub' to use it as a project name." >&2
      return 1
      ;;
    *)
      _cdev-attach "$@"
      ;;
  esac
}

# Let `./cdev.sh <args>` work directly too, not only `source cdev.sh` then
# `cdev <args>`. BASH_SOURCE[0] (this file's path) only equals $0 (the
# running program's name) when the file is executed, not when it's sourced,
# so this is a no-op for the installed, sourced-into-rc-file case.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  cdev "$@"
fi
