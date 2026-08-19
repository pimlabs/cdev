#!/usr/bin/env bash
# One-time setup on the VPS: installs the cdev functions, wires the
# reboot-recovery systemd unit, and enables lingering so it starts even
# without an active login session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/cdev.sh" "$HOME/.cdev.sh"

# Older installs had the boot and health-check halves as their own copied
# dotfiles. Both are now `cdev restore` / `cdev healthcheck` subcommands
# inside .cdev.sh, and the systemd units below no longer point at them, so
# clear the leftovers rather than leaving dead scripts in $HOME.
rm -f "$HOME/.cdev-restore-all.sh" "$HOME/.cdev-healthcheck.sh"

SHELL_NAME="$(basename "${SHELL:-}")"
if [ "$SHELL_NAME" = "zsh" ]; then
  RC_FILE="$HOME/.zshrc"
else
  RC_FILE="$HOME/.bashrc"
fi
echo "Detected shell: $SHELL_NAME"

# Create the rc file first if it isn't there. The append below would create
# it anyway, but the grep in front of it would print its own "No such file
# or directory" on a fresh box, which reads like the install failed.
touch "$RC_FILE"

# The single quotes are deliberate: the literal string $HOME has to land in
# the rc file so it resolves at shell startup, not install time.
# shellcheck disable=SC2016
grep -qxF 'source "$HOME/.cdev.sh"' "$RC_FILE" || echo 'source "$HOME/.cdev.sh"' >> "$RC_FILE"
echo "Added 'source \"\$HOME/.cdev.sh\"' to $RC_FILE"

mkdir -p "$HOME/.config/systemd/user"
cp "$SCRIPT_DIR/cdev-restore.service" "$HOME/.config/systemd/user/cdev-restore.service"
cp "$SCRIPT_DIR/cdev-healthcheck.service" "$HOME/.config/systemd/user/cdev-healthcheck.service"
cp "$SCRIPT_DIR/cdev-healthcheck.timer" "$HOME/.config/systemd/user/cdev-healthcheck.timer"

sudo loginctl enable-linger "$(whoami)"
systemctl --user daemon-reload
systemctl --user enable cdev-restore.service
systemctl --user enable --now cdev-healthcheck.timer

echo "Installed."
echo "Run 'source $RC_FILE' (or start a new shell) to use cdev right away."
echo "From now on, any session started with cdev survives a VPS reboot automatically."
echo "cdev-healthcheck.timer is now enabled and will periodically check session health."
