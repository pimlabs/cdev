#!/usr/bin/env bash
# Persistent, multi-account Claude Code sessions on this VPS.
# Sourced from ~/.bashrc. See cdev-restore-all.sh for the reboot-recovery half.

CDEV_REGISTRY="$HOME/.cdev-sessions"

# Create the tmux + Remote Control session if it doesn't already exist, and
# record it in the registry. Does not attach, safe to call at boot.
cdev-ensure() {
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir="$HOME/.claude"
  [ "$account" != "personal" ] && config_dir="$HOME/.claude-$account"

  if ! tmux has-session -t "$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$dir" \
      "CLAUDE_CONFIG_DIR=$config_dir claude remote-control --name '$name'"
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
  local config_dir="$HOME/.claude"
  [ "$account" != "personal" ] && config_dir="$HOME/.claude-$account"

  if [ -d "$config_dir" ]; then
    echo "Account '$account' already initialized ($config_dir)."
    return 0
  fi

  echo "No login yet for account '$account', starting one-time login in $dir..."
  ( cd "$dir" && CLAUDE_CONFIG_DIR="$config_dir" claude )
}

# Interactive entry point: log the account in first if needed, ensure the
# session exists, then attach to it.
cdev() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev <project-name> [account] [dir]"
    return 1
  fi
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir="$HOME/.claude"
  [ "$account" != "personal" ] && config_dir="$HOME/.claude-$account"
  [ -d "$config_dir" ] || cdev-init "$account" "$dir"
  cdev-ensure "$name" "$account" "$dir"
  tmux attach -t "$name"
}

cdev-accounts() { ls -d "$HOME/.claude" "$HOME"/.claude-* 2>/dev/null; }

cdev-status() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}' 2>/dev/null)
  if [ -z "$sessions" ]; then
    echo "No cdev sessions running."
    return
  fi
  printf '%-20s %-14s %-10s\n' "SESSION" "ACCOUNT" "ATTACHED"
  echo "$sessions" | while IFS='|' read -r s att; do
    local acct
    acct=$(tmux show-environment -t "$s" CDEV_ACCOUNT 2>/dev/null | cut -d= -f2)
    [ "$att" = "1" ] && att="yes" || att="no"
    printf '%-20s %-14s %-10s\n' "$s" "${acct:-personal}" "$att"
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
  [ -f "$CDEV_REGISTRY" ] && sed -i "/^$1 /d" "$CDEV_REGISTRY"
}
