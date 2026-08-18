#!/usr/bin/env bash
# Persistent, multi-account Claude Code sessions on this VPS.
# Sourced from ~/.bashrc. See cdev-restore-all.sh for the reboot-recovery half.
# Single entrypoint: `cdev <subcommand> ...` dispatches to the functions below.

CDEV_VERSION="0.1.0"
CDEV_REGISTRY="$HOME/.cdev-sessions"

# Map an account to its CLAUDE_CONFIG_DIR. 'personal' uses ~/.claude, any
# other account uses ~/.claude-<account>. One helper so cdev-ensure,
# cdev-init, and cdev-attach can't drift from each other on this mapping.
cdev-config-dir() {
  local account="${1:-personal}"
  if [ "$account" = "personal" ]; then
    echo "$HOME/.claude"
  else
    echo "$HOME/.claude-$account"
  fi
}

# Create the tmux + Remote Control session if it doesn't already exist, and
# record it in the registry. Does not attach, safe to call at boot.
cdev-ensure() {
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir
  config_dir=$(cdev-config-dir "$account")

  if ! tmux has-session -t "$name" 2>/dev/null; then
    # Passed as separate argv items, plus -e for the env var, rather than one
    # interpolated string: tmux execs a multi-argument command directly with
    # no shell involved, so a name or account containing quotes/semicolons/etc
    # can't break out into arbitrary shell execution (requires tmux >= 3.2
    # for -e on new-session).
    tmux new-session -d -s "$name" -c "$dir" -e "CLAUDE_CONFIG_DIR=$config_dir" \
      claude remote-control --name "$name" --spawn=worktree
    tmux set-environment -t "$name" CDEV_ACCOUNT "$account"
  fi

  touch "$CDEV_REGISTRY"
  grep -qxF "$name $account $dir" "$CDEV_REGISTRY" || echo "$name $account $dir" >> "$CDEV_REGISTRY"
}

# One-time interactive login for an account, run inside the target project
# directory. Claude Code's first-run trust dialog is never saved for $HOME,
# so this has to happen in $dir, not wherever the SSH session happens to
# land, or the login "succeeds" but the project still isn't trusted. Safe to
# call again, no-ops if the account's config dir already exists. Deliberately
# NOT called from cdev-ensure: that path also runs at boot with no attached
# terminal, and an interactive login/trust prompt there would just hang the
# restore service.
cdev-init() {
  local account="${1:?Usage: cdev-init <account> <dir>}"
  local dir="${2:?Usage: cdev-init <account> <dir>}"
  local config_dir
  config_dir=$(cdev-config-dir "$account")

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
cdev-attach() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev <project-name> [account] [dir]"
    return 1
  fi
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir
  config_dir=$(cdev-config-dir "$account")
  [ -d "$config_dir" ] || cdev-init "$account" "$dir"

  local was_running=0
  tmux has-session -t "$name" 2>/dev/null && was_running=1
  cdev-ensure "$name" "$account" "$dir"

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
cdev-accounts() {
  find "$HOME" -maxdepth 1 \( -type d -o -type l \) \
    \( -name '.claude' -o -name '.claude-*' \) 2>/dev/null | sort
}

# Format a duration in seconds as a short human string, e.g. '3d 4h', '12h',
# '45m'. Used by cdev-status for the UPTIME column.
cdev-format-duration() {
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

# List live sessions. The LOGIN column is a literal 'unknown' placeholder,
# not a real check: cdev does not read Claude Code's local credential
# expiry, so it cannot tell a logged-in session from an expired one. The
# column exists so the layout does not have to change once there is a safe
# way to read that. Do not describe it as a login check anywhere.
cdev-status() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null)
  if [ -z "$sessions" ]; then
    echo "No cdev sessions running."
    return
  fi
  printf '%-20s %-14s %-10s %-8s %-10s\n' "SESSION" "ACCOUNT" "ATTACHED" "UPTIME" "LOGIN"
  echo "$sessions" | while IFS='|' read -r s att created; do
    local acct uptime_secs uptime
    acct=$(tmux show-environment -t "$s" CDEV_ACCOUNT 2>/dev/null | cut -d= -f2)
    [ "$att" = "1" ] && att="yes" || att="no"
    uptime_secs=$(( $(date +%s) - created ))
    uptime=$(cdev-format-duration "$uptime_secs")
    printf '%-20s %-14s %-10s %-8s %-10s\n' "$s" "${acct:-personal}" "$att" "$uptime" "unknown"
  done
}

# Kill a session AND remove it from the registry, so it does not come back
# on the next reboot. A session stopped some other way (crash, VPS restart)
# stays in the registry and gets recreated by cdev-restore-all.sh.
cdev-kill() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev-kill <project-name>"
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

# Print one line of cdev-doctor's systemd unit report for $1, given that
# systemctl is already known to exist. `is-active` exits non-zero for a unit
# that is merely inactive, so it gets `|| true`: the word it prints is the
# answer we want, not an error. Factored out so this handling only needs to
# be right in one place as more units get added.
cdev-doctor-unit() {
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
cdev-doctor() {
  echo "Installed: cdev $CDEV_VERSION (~/.cdev.sh)"

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
    cdev-doctor-unit cdev-restore.service
    cdev-doctor-unit cdev-healthcheck.timer
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

cdev-help() {
  cat <<'EOF'
Usage: cdev <name> [account] [dir]
  Attaches to (creating if needed) a persistent session for <name>.
  account defaults to 'personal', mapping to ~/.claude-<account>.
  dir defaults to ~/projects/<name>.
  If <name> collides with a subcommand word below, force attach mode with
  `cdev -- <name> [account] [dir]`.

Subcommands:
  status                List running sessions with account, attach state, and uptime.
                        The LOGIN column always prints 'unknown', it is a
                        placeholder, cdev does not read credential expiry.
  kill <name>           Kill a session and remove it from the reboot registry.
  init <account> <dir>  One-time interactive login/trust setup for an account.
  accounts              List configured account config directories.
  doctor                Show install version and systemd/linger health.
  version               Print the installed cdev version.
  help                  Show this message.
EOF
}

# Single entrypoint. Routes to the functions above; anything not recognized
# as a subcommand falls through to cdev-attach, so `cdev <name> ...` still
# works exactly as the old top-level `cdev` function did.
cdev() {
  local sub="${1:-}"
  case "$sub" in
    --)
      shift
      cdev-attach "$@"
      ;;
    status)
      shift
      cdev-status "$@"
      ;;
    kill)
      shift
      cdev-kill "$@"
      ;;
    init)
      shift
      cdev-init "$@"
      ;;
    accounts)
      shift
      cdev-accounts "$@"
      ;;
    doctor)
      shift
      cdev-doctor "$@"
      ;;
    version)
      echo "cdev $CDEV_VERSION"
      ;;
    help|--help|-h|"")
      cdev-help
      ;;
    *)
      cdev-attach "$@"
      ;;
  esac
}
