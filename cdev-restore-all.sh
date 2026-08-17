#!/usr/bin/env bash
# Recreate every registered cdev session. Run automatically at boot by the
# cdev-restore.service systemd unit; safe to run by hand too, since
# cdev-ensure no-ops for sessions that are already up.
set -euo pipefail

# shellcheck source=./cdev.sh
source "$HOME/.cdev.sh"

REGISTRY="$HOME/.cdev-sessions"
[ -f "$REGISTRY" ] || exit 0

while read -r name account dir; do
  [ -z "$name" ] && continue
  cdev-ensure "$name" "$account" "$dir"
done < "$REGISTRY"
