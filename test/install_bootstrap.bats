#!/usr/bin/env bats
# install.sh's two modes. From a checkout it installs the files sitting
# next to it. Piped straight from the network (no files next to it) it
# resolves the latest release tag, downloads that tag's tarball, verifies it
# against a SHA256SUMS file also fetched from the release, then extracts it
# and hands over to the copy of install.sh inside it. curl is stubbed for
# the tag-resolution, tarball-download, and SHA256SUMS-download requests;
# systemctl/sudo/loginctl are stubbed so nothing touches this machine's real
# systemd or linger state.

load test_helper

setup() {
  stub_bin_dir
  write_stub systemctl 'exit 0'
  write_stub sudo 'exit 0'
  write_stub loginctl 'exit 0'

  TEST_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME" "${FIXTURE_DIR:-}" "${NOPAYLOAD_DIR:-}"
}

# Portable sha256 for the test itself, mirroring cdev_sha256 in install.sh:
# prefer sha256sum (Linux/CI), fall back to shasum -a 256 (macOS).
fixture_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# A curl stub good for all three requests install.sh's piped mode makes:
# resolving the latest tag (answered via -w '%{url_effective}', so this
# stub prints the redirect target to stdout), and downloading the tarball
# and SHA256SUMS (both via -o <file>, so this stub copies the matching
# fixture to whatever path -o names, regardless of where -o falls among the
# other flags). Any request this stub doesn't recognize fails loudly rather
# than passing silently.
stub_curl_piped_install() {
  write_stub curl '
url=""
outfile=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      outfile="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

case "$url" in
  *releases/latest*)
    echo "https://github.com/pimlabs/cdev/releases/tag/$FAKE_TAG"
    ;;
  *archive/refs/tags/*)
    cp "$FAKE_TARBALL" "$outfile"
    ;;
  *SHA256SUMS)
    # No explicit exit here on purpose: the stub exits with the status of
    # cp, so a FAKE_SHASUMS pointing at a file that does not exist (the
    # "SHA256SUMS could not be downloaded" test) makes this stub fail
    # exactly like a real curl would against a missing release asset.
    cp "$FAKE_SHASUMS" "$outfile"
    ;;
  *)
    echo "stub curl: unexpected request: $*" >&2
    exit 1
    ;;
esac
'
}

@test "checkout mode installs from local files and never calls curl" {
  write_stub curl '
echo "$@" >> "$CURL_LOG"
exit 1
'
  CURL_LOG="$TEST_HOME/curl.log"
  export CURL_LOG

  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" \
    bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ ! -f "$CURL_LOG" ]

  [ -f "$TEST_HOME/.local/bin/cdev" ]
  [ -x "$TEST_HOME/.local/bin/cdev" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-restore.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.timer" ]
}

@test "standalone/piped mode resolves the latest release, verifies the checksum, and installs from the downloaded tarball" {
  # Build a fake release tarball out of this checkout's own payload files,
  # standing in for what curl would otherwise download from GitHub.
  FIXTURE_DIR="$(mktemp -d)"
  mkdir "$FIXTURE_DIR/cdev-9.9.9"
  cp "$CDEV_ROOT/cdev.sh" "$CDEV_ROOT/install.sh" \
     "$CDEV_ROOT/cdev-restore.service" "$CDEV_ROOT/cdev-healthcheck.service" \
     "$CDEV_ROOT/cdev-healthcheck.timer" "$FIXTURE_DIR/cdev-9.9.9/"
  local tarball="$FIXTURE_DIR/release.tar.gz"
  tar -czf "$tarball" -C "$FIXTURE_DIR" cdev-9.9.9

  # A SHA256SUMS whose source.tar.gz entry actually matches the fixture
  # tarball above, the same as a real release's would.
  local shasums="$FIXTURE_DIR/SHA256SUMS"
  printf '%s  source.tar.gz\n' "$(fixture_sha256 "$tarball")" > "$shasums"

  stub_curl_piped_install

  # A working directory with no cdev.sh in it, so the payload check fails
  # exactly like it would when this script is piped straight from curl.
  NOPAYLOAD_DIR="$(mktemp -d)"

  # Piping via stdin, not passing install.sh as an argument, is what makes
  # BASH_SOURCE[0] empty inside the script, the same as `curl ... | bash`.
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" \
    FAKE_TAG="v9.9.9" FAKE_TARBALL="$tarball" FAKE_SHASUMS="$shasums" \
    bash -c 'cd "$1" && bash < "$2"' _ "$NOPAYLOAD_DIR" "$CDEV_ROOT/install.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Resolving the latest cdev release..."* ]]
  [[ "$output" == *"Latest release: v9.9.9"* ]]
  [[ "$output" == *"Verifying checksum..."* ]]
  [[ "$output" == *"Checksum OK."* ]]
  [[ "$output" == *"Installing v9.9.9..."* ]]

  [ -f "$TEST_HOME/.local/bin/cdev" ]
  [ -x "$TEST_HOME/.local/bin/cdev" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-restore.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.timer" ]
}

@test "standalone/piped mode aborts on a checksum mismatch and never installs anything" {
  FIXTURE_DIR="$(mktemp -d)"
  mkdir "$FIXTURE_DIR/cdev-9.9.9"
  cp "$CDEV_ROOT/cdev.sh" "$CDEV_ROOT/install.sh" \
     "$CDEV_ROOT/cdev-restore.service" "$CDEV_ROOT/cdev-healthcheck.service" \
     "$CDEV_ROOT/cdev-healthcheck.timer" "$FIXTURE_DIR/cdev-9.9.9/"
  local tarball="$FIXTURE_DIR/release.tar.gz"
  tar -czf "$tarball" -C "$FIXTURE_DIR" cdev-9.9.9

  # A SHA256SUMS with a well-formed but wrong hash, standing in for a
  # tampered or corrupted download.
  local shasums="$FIXTURE_DIR/SHA256SUMS"
  printf '%s  source.tar.gz\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    > "$shasums"

  stub_curl_piped_install

  NOPAYLOAD_DIR="$(mktemp -d)"

  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" \
    FAKE_TAG="v9.9.9" FAKE_TARBALL="$tarball" FAKE_SHASUMS="$shasums" \
    bash -c 'cd "$1" && bash < "$2"' _ "$NOPAYLOAD_DIR" "$CDEV_ROOT/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]

  # Nothing from the (untrusted) tarball should have been installed.
  [ ! -f "$TEST_HOME/.local/bin/cdev" ]
  [ ! -f "$TEST_HOME/.config/systemd/user/cdev-restore.service" ]
}

@test "standalone/piped mode aborts when SHA256SUMS can't be downloaded" {
  FIXTURE_DIR="$(mktemp -d)"
  mkdir "$FIXTURE_DIR/cdev-9.9.9"
  cp "$CDEV_ROOT/cdev.sh" "$CDEV_ROOT/install.sh" \
     "$CDEV_ROOT/cdev-restore.service" "$CDEV_ROOT/cdev-healthcheck.service" \
     "$CDEV_ROOT/cdev-healthcheck.timer" "$FIXTURE_DIR/cdev-9.9.9/"
  local tarball="$FIXTURE_DIR/release.tar.gz"
  tar -czf "$tarball" -C "$FIXTURE_DIR" cdev-9.9.9

  # No SHA256SUMS fixture at all: the stub's *SHA256SUMS) branch tries to
  # cp a path that was never set, which fails, standing in for a release
  # with no SHA256SUMS asset (or a network hiccup fetching it).
  stub_curl_piped_install

  NOPAYLOAD_DIR="$(mktemp -d)"

  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" \
    FAKE_TAG="v9.9.9" FAKE_TARBALL="$tarball" FAKE_SHASUMS="/nonexistent/SHA256SUMS" \
    bash -c 'cd "$1" && bash < "$2"' _ "$NOPAYLOAD_DIR" "$CDEV_ROOT/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"could not download SHA256SUMS"* ]]

  [ ! -f "$TEST_HOME/.local/bin/cdev" ]
}

@test "standalone/piped mode aborts when SHA256SUMS has no entry for source.tar.gz" {
  # Regression test for a set -e/pipefail trap: the entry lookup used to be
  # `grep ' source.tar.gz$' SHA256SUMS | awk '{print $1}'`. Under this
  # script's `set -euo pipefail`, a grep that matches nothing exits 1, and
  # pipefail carries that failure into the pipeline (and the assignment
  # capturing it), aborting the script right there instead of ever reaching
  # the intended "has no entry for source.tar.gz" message. It is now a
  # single awk, which exits 0 even on no match, so the check below is what
  # actually aborts, with the right message.
  FIXTURE_DIR="$(mktemp -d)"
  mkdir "$FIXTURE_DIR/cdev-9.9.9"
  cp "$CDEV_ROOT/cdev.sh" "$CDEV_ROOT/install.sh" \
     "$CDEV_ROOT/cdev-restore.service" "$CDEV_ROOT/cdev-healthcheck.service" \
     "$CDEV_ROOT/cdev-healthcheck.timer" "$FIXTURE_DIR/cdev-9.9.9/"
  local tarball="$FIXTURE_DIR/release.tar.gz"
  tar -czf "$tarball" -C "$FIXTURE_DIR" cdev-9.9.9

  # A well-formed SHA256SUMS that simply has no source.tar.gz line in it,
  # standing in for a release whose SHA256SUMS asset only covers install.sh.
  local shasums="$FIXTURE_DIR/SHA256SUMS"
  printf '%s  install.sh\n' \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    > "$shasums"

  stub_curl_piped_install

  NOPAYLOAD_DIR="$(mktemp -d)"

  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" \
    FAKE_TAG="v9.9.9" FAKE_TARBALL="$tarball" FAKE_SHASUMS="$shasums" \
    bash -c 'cd "$1" && bash < "$2"' _ "$NOPAYLOAD_DIR" "$CDEV_ROOT/install.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *"has no entry for source.tar.gz"* ]]

  [ ! -f "$TEST_HOME/.local/bin/cdev" ]
}
