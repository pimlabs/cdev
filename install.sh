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

# Portable sha256: Linux ships sha256sum, macOS ships shasum -a 256, prefer
# whichever exists rather than assuming one. Prints the hex digest only.
# cdev.sh carries its own copy of this, _cdev-sha256, for the same reason it
# carries its own copy of cdev_latest_tag above: install.sh has to run
# before cdev.sh is on the box at all, so the two cannot share code.
cdev_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
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
  # A && B || C is exactly what's wanted here: C (mark the payload missing,
  # break the loop) only has to run when the chain in front of it fails,
  # and neither A nor B can produce output that makes C fire on its own.
  # Newer shellcheck (0.10+) already knows this pattern is fine and stays
  # quiet; older versions, including whatever `apt-get install shellcheck`
  # resolves to on a given day, still flag it, so the disable stays pinned
  # here rather than relying on which shellcheck happens to run this in CI.
  # shellcheck disable=SC2015
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

  if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then
    echo "install: sha256sum or shasum is required to verify the download." >&2
    exit 1
  fi

  echo "Resolving the latest cdev release..."
  tag=$(cdev_latest_tag) || {
    echo "install: could not resolve the latest release of $CDEV_REPO." >&2
    echo "Install from a checkout instead: git clone, then ./install.sh" >&2
    exit 1
  }
  echo "Latest release: $tag"

  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # Downloaded to a file rather than piped straight into tar, so the
  # checksum below can verify the exact bytes before anything is unpacked.
  curl -fsSL --connect-timeout 5 --max-time 120 \
    "https://github.com/$CDEV_REPO/archive/refs/tags/$tag.tar.gz" \
    -o "$work/source.tar.gz"

  echo "Verifying checksum..."
  if ! curl -fsSL --connect-timeout 5 --max-time 20 \
    "https://github.com/$CDEV_REPO/releases/download/$tag/SHA256SUMS" \
    -o "$work/SHA256SUMS"; then
    echo "install: could not download SHA256SUMS for $tag, aborting." >&2
    echo "This is what protects the downloaded archive against tampering." >&2
    exit 1
  fi

  # A single awk rather than grep piped into awk: under this script's
  # set -e -o pipefail, a grep that matches nothing exits 1, and pipefail
  # would make the whole pipeline (and this assignment) exit non-zero too,
  # aborting the script right here instead of reaching the intentional
  # "no entry for source.tar.gz" message below. awk finds no match and
  # still exits 0, which is what makes the check below reachable at all.
  expected="$(awk '$0 ~ / source\.tar\.gz$/ {print $1}' "$work/SHA256SUMS")"
  if [ -z "$expected" ]; then
    echo "install: SHA256SUMS for $tag has no entry for source.tar.gz, aborting." >&2
    exit 1
  fi

  actual="$(cdev_sha256 "$work/source.tar.gz")" || {
    echo "install: no sha256sum or shasum available to verify the download." >&2
    exit 1
  }

  if [ "$expected" != "$actual" ]; then
    echo "install: checksum mismatch for $tag, refusing to install." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    exit 1
  fi
  echo "Checksum OK."

  # --strip-components=1 so this does not depend on the name GitHub gives the
  # directory inside the archive, which is the tag minus its leading v.
  tar -xz -C "$work" --strip-components=1 -f "$work/source.tar.gz"

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
