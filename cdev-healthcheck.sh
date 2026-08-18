#!/usr/bin/env bash
# Notice when a registered cdev session disappeared unexpectedly (a crash),
# as opposed to a clean cdev-kill, which already removes its own registry
# line so it is never flagged as missing. Opt-in: silent unless
# $HOME/.cdev-notify holds a webhook URL. Run periodically by the
# cdev-healthcheck.timer / cdev-healthcheck.service systemd units; safe to
# run by hand too.
set -euo pipefail

REGISTRY="$HOME/.cdev-sessions"
[ -f "$REGISTRY" ] || exit 0

NOTIFY_FILE="$HOME/.cdev-notify"
[ -s "$NOTIFY_FILE" ] || exit 0
webhook_url="$(head -n 1 "$NOTIFY_FILE")"
[ -n "$webhook_url" ] || exit 0

# Without tmux on PATH every `has-session` below fails, which would read as
# "every registered session crashed" and fire one webhook per line. That is
# a broken check, not a finding, so exit quietly instead. Worth guarding
# even though tmux is a hard requirement of cdev: this runs from a
# systemd --user unit, whose PATH is not the login shell's.
command -v tmux >/dev/null 2>&1 || exit 0

host="$(hostname 2>/dev/null || echo unknown-host)"
now="$(date -u +%H:%M 2>/dev/null || echo '??:??')"

while read -r name account _dir; do
  [ -z "$name" ] && continue
  if ! tmux has-session -t "$name" 2>/dev/null; then
    message="cdev: session '$name' (account $account, box $host) disappeared unexpectedly at $now UTC. Registry still lists it; run 'cdev status' to confirm, or 'cdev $name' to respawn."
    curl -fsS -X POST "$webhook_url" -H 'Content-Type: text/plain' -d "$message" || true
  fi
done < "$REGISTRY"
