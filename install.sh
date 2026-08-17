#!/usr/bin/env bash
# One-time setup on the VPS: installs the cdev functions, wires the
# reboot-recovery systemd unit, and enables lingering so it starts even
# without an active login session.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp "$SCRIPT_DIR/cdev.sh" "$HOME/.cdev.sh"
cp "$SCRIPT_DIR/cdev-restore-all.sh" "$HOME/.cdev-restore-all.sh"
chmod +x "$HOME/.cdev-restore-all.sh"

grep -qxF 'source "$HOME/.cdev.sh"' "$HOME/.bashrc" || echo 'source "$HOME/.cdev.sh"' >> "$HOME/.bashrc"

mkdir -p "$HOME/.config/systemd/user"
cp "$SCRIPT_DIR/cdev-restore.service" "$HOME/.config/systemd/user/cdev-restore.service"

sudo loginctl enable-linger "$(whoami)"
systemctl --user daemon-reload
systemctl --user enable cdev-restore.service

echo "Installed."
echo "Run 'source ~/.cdev.sh' (or start a new shell) to use cdev right away."
echo "From now on, any session started with cdev survives a VPS reboot automatically."
