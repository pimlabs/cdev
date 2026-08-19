#!/usr/bin/env bash
# One-time setup on the VPS: installs the cdev functions, wires the
# reboot-recovery systemd unit, and enables lingering so it starts even
# without an active login session.
#
# Runs two ways. From a checkout it installs the files sitting next to it,
# which is what a developer testing a change wants. Piped straight from the
# network, as
#
#   curl -fsSL https://cdev.pimlabs.id/install | bash
#
# there are no files next to it, so it resolves the latest release, downloads
# that tag's tarball, and hands over to the copy of this script inside it. A
# release tag rather than a branch on purpose: this script installs systemd
# units and calls sudo, so what it installs has to be a fixed, named thing.
set -euo pipefail

CDEV_REPO="${CDEV_REPO:-pimlabs/cdev}"

# The files install.sh needs to have beside it before it can install anything.
CDEV_PAYLOAD=(
  cdev.sh
  cdev-restore.service
  cdev-healthcheck.service
  cdev-healthcheck.timer
)

# Resolve the newest release tag by following the redirect that
# /releases/latest issues to /releases/tag/<tag>. Deliberately not the GitHub
# API: no JSON to parse without jq, and no 60-per-hour unauthenticated rate
# limit to hit. A repo with no releases at all redirects to a page with no
# /tag/ in the path, which the pattern check below rejects.
cdev_latest_tag() {
  local url tag
  url=$(curl -fsSL --connect-timeout 5 --max-time 20 -o /dev/null \
    -w '%{url_effective}' "https://github.com/$CDEV_REPO/releases/latest") || return 1
  tag="${url##*/tag/}"
  case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$tag" ;;
    *) return 1 ;;
  esac
}

# Am I running from a checkout, or piped in on my own? Answered by looking
# for the payload rather than by inspecting $0 or BASH_SOURCE: what matters
# is whether the files are reachable, and that check reads the same however
# the script was invoked. It is also what stops the hand-off below from
# looping, since the extracted copy does find its payload.
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
fi

have_payload=1
for f in "${CDEV_PAYLOAD[@]}"; do
  [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$f" ] || { have_payload=0; break; }
done

if [ "$have_payload" -eq 0 ]; then
  # Belt and braces against the loop the payload check already prevents.
  if [ -n "${CDEV_BOOTSTRAPPED:-}" ]; then
    echo "install: downloaded release is missing its own files, aborting." >&2
    exit 1
  fi

  for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "install: $cmd is required to install this way." >&2
      exit 1
    }
  done

  echo "Resolving the latest cdev release..."
  tag=$(cdev_latest_tag) || {
    echo "install: could not resolve the latest release of $CDEV_REPO." >&2
    echo "Install from a checkout instead: git clone, then ./install.sh" >&2
    exit 1
  }
  echo "Latest release: $tag"

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # --strip-components=1 so this does not depend on the name GitHub gives the
  # directory inside the archive, which is the tag minus its leading v.
  curl -fsSL --connect-timeout 5 --max-time 120 \
    "https://github.com/$CDEV_REPO/archive/refs/tags/$tag.tar.gz" |
    tar -xz -C "$work" --strip-components=1

  [ -f "$work/install.sh" ] || {
    echo "install: the $tag tarball has no install.sh, aborting." >&2
    exit 1
  }

  echo "Installing $tag..."
  CDEV_BOOTSTRAPPED=1 exec bash "$work/install.sh" "$@"
fi

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
