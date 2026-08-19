#!/usr/bin/env bash
# Reverse what install.sh did to this box: the systemd units, the source
# line in the shell rc file, and the ~/.cdev.sh copy.
#
# Deliberately conservative by default, since the things this could destroy
# are the things people actually care about:
#   - running tmux sessions are left alone. Uninstalling the launcher is not
#     a reason to kill live Claude sessions and lose whatever they were in
#     the middle of. Pass --kill-sessions to stop them too.
#   - ~/.cdev-sessions and ~/.cdev-notify are kept. The registry is a record
#     of your projects and the notify file is your webhook config, so both
#     survive a reinstall. Pass --purge to delete them.
#   - linger stays enabled. install.sh turned it on with sudo, but other
#     systemd --user services may depend on it by now, and turning it off
#     would stop them silently. The command to undo it is printed instead.
set -euo pipefail

PURGE=0
KILL_SESSIONS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --purge) PURGE=1 ;;
    --kill-sessions) KILL_SESSIONS=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: ./uninstall.sh [--kill-sessions] [--purge]

Removes the cdev install from this box: systemd units, the source line in
the shell rc file, and ~/.cdev.sh.

  --kill-sessions  Also stop every running tmux session in the registry.
                   Off by default, uninstalling should not kill live work.
  --purge          Also delete ~/.cdev-sessions (the registry) and
                   ~/.cdev-notify (the webhook URL). Off by default, both
                   survive so a reinstall picks up where you left off.

Linger is never disabled, other systemd --user services may rely on it.
EOF
      exit 0
      ;;
    *)
      echo "uninstall: unknown option '$1'" >&2
      echo "Run './uninstall.sh --help' for usage." >&2
      exit 1
      ;;
  esac
  shift
done

REGISTRY="$HOME/.cdev-sessions"

# --- running sessions -------------------------------------------------------

live_sessions=()
if command -v tmux >/dev/null 2>&1 && [ -f "$REGISTRY" ]; then
  while read -r name _account _dir; do
    [ -z "$name" ] && continue
    if tmux has-session -t "$name" 2>/dev/null; then
      live_sessions+=("$name")
    fi
  done < "$REGISTRY"
fi

if [ "${#live_sessions[@]}" -gt 0 ]; then
  if [ "$KILL_SESSIONS" -eq 1 ]; then
    for name in "${live_sessions[@]}"; do
      tmux kill-session -t "$name" 2>/dev/null && echo "Killed session '$name'." ||
        echo "Could not kill session '$name'."
    done
  else
    echo "Leaving ${#live_sessions[@]} running session(s) alone: ${live_sessions[*]}"
    echo "They keep running under tmux. Re-run with --kill-sessions to stop them,"
    echo "or attach with 'tmux attach -t <name>' once cdev is gone."
  fi
fi

# --- systemd ----------------------------------------------------------------

UNIT_DIR="$HOME/.config/systemd/user"
UNITS=(cdev-restore.service cdev-healthcheck.service cdev-healthcheck.timer)

if command -v systemctl >/dev/null 2>&1; then
  # `disable --now` also stops a running unit. Both are guarded: a unit that
  # was never installed, or a box where the user systemd bus is not
  # reachable, must not abort the rest of the uninstall under set -e.
  for unit in "${UNITS[@]}"; do
    systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
  done
  echo "Disabled systemd units."
else
  echo "No systemd on this box, skipping unit teardown."
fi

for unit in "${UNITS[@]}"; do
  rm -f "$UNIT_DIR/$unit"
done
echo "Removed unit files from $UNIT_DIR."

if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload >/dev/null 2>&1 || true
fi

# --- shell rc ---------------------------------------------------------------

# Clean both rc files, not just the one matching $SHELL today. install.sh
# picks the rc file by the shell active at install time, and someone who has
# switched shells since would otherwise be left with a dangling source line
# in the other file, which errors on every new shell once ~/.cdev.sh is gone.
# The single quotes are deliberate, the same way install.sh writes this
# line: the literal string $HOME is what sits in the rc file, so that is
# what has to be matched, not its expansion.
# shellcheck disable=SC2016
SOURCE_LINE='source "$HOME/.cdev.sh"'
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  [ -f "$rc" ] || continue
  grep -qxF -- "$SOURCE_LINE" "$rc" || continue

  # grep -vF into a temp file, then replace. Same reason cdev.sh does it this
  # way rather than `sed -i`: the in-place flag takes a mandatory backup
  # suffix on BSD sed and none on GNU sed, so one invocation cannot work on
  # both. The status check keeps a genuinely failed grep from truncating the
  # rc file, which would be far worse than a leftover line. Status 1 is not
  # a failure: it means nothing was selected, which is exactly what an rc
  # file holding nothing but the source line produces, and that empty result
  # is the correct new contents.
  grep_status=0
  grep -vxF -- "$SOURCE_LINE" "$rc" > "$rc.cdev-tmp" || grep_status=$?
  if [ "$grep_status" -le 1 ]; then
    mv "$rc.cdev-tmp" "$rc"
    echo "Removed the cdev source line from $rc."
  else
    rm -f "$rc.cdev-tmp"
    echo "Could not rewrite $rc, leaving it untouched. Remove this line by hand:" >&2
    echo "  $SOURCE_LINE" >&2
  fi
done

# --- installed files --------------------------------------------------------

# .cdev-restore-all.sh and .cdev-healthcheck.sh are from installs predating
# the move to `cdev restore` / `cdev healthcheck` subcommands.
rm -f "$HOME/.cdev.sh" "$HOME/.cdev-restore-all.sh" "$HOME/.cdev-healthcheck.sh"
echo "Removed ~/.cdev.sh."

if [ "$PURGE" -eq 1 ]; then
  rm -f "$REGISTRY" "$HOME/.cdev-notify"
  echo "Purged the registry and notify file."
else
  [ -f "$REGISTRY" ] && echo "Kept $REGISTRY (pass --purge to delete it)."
  [ -f "$HOME/.cdev-notify" ] && echo "Kept $HOME/.cdev-notify (pass --purge to delete it)."
fi

echo ""
echo "Uninstalled. Open a new shell, the cdev function is gone from this one"
echo "only after you do (or run 'unset -f cdev' now)."
if command -v loginctl >/dev/null 2>&1; then
  echo "Linger is still enabled. If nothing else on this box needs it:"
  echo "  sudo loginctl disable-linger $(whoami)"
fi
