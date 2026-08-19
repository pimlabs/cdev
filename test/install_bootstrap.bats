#!/usr/bin/env bats
# install.sh's two modes. From a checkout it installs the files sitting
# next to it. Piped straight from the network (no files next to it) it
# resolves the latest release tag, downloads that tag's tarball, and hands
# over to the copy of install.sh inside it. curl is stubbed for both the
# tag-resolution and tarball-download requests; systemctl/sudo/loginctl are
# stubbed so nothing touches this machine's real systemd or linger state.

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

  [ -f "$TEST_HOME/.cdev.sh" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-restore.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.timer" ]
}

@test "standalone/piped mode resolves the latest release and installs from the downloaded tarball" {
  # Build a fake release tarball out of this checkout's own payload files,
  # standing in for what curl would otherwise download from GitHub.
  FIXTURE_DIR="$(mktemp -d)"
  mkdir "$FIXTURE_DIR/cdev-9.9.9"
  cp "$CDEV_ROOT/cdev.sh" "$CDEV_ROOT/install.sh" \
     "$CDEV_ROOT/cdev-restore.service" "$CDEV_ROOT/cdev-healthcheck.service" \
     "$CDEV_ROOT/cdev-healthcheck.timer" "$FIXTURE_DIR/cdev-9.9.9/"
  local tarball="$FIXTURE_DIR/release.tar.gz"
  tar -czf "$tarball" -C "$FIXTURE_DIR" cdev-9.9.9

  write_stub curl '
for arg in "$@"; do
  case "$arg" in
    *releases/latest*)
      echo "https://github.com/pimlabs/cdev/releases/tag/$FAKE_TAG"
      exit 0
      ;;
    *archive/refs/tags/*)
      cat "$FAKE_TARBALL"
      exit 0
      ;;
  esac
done
exit 1
'

  # A working directory with no cdev.sh in it, so the payload check fails
  # exactly like it would when this script is piped straight from curl.
  NOPAYLOAD_DIR="$(mktemp -d)"

  # Piping via stdin, not passing install.sh as an argument, is what makes
  # BASH_SOURCE[0] empty inside the script, the same as `curl ... | bash`.
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" \
    FAKE_TAG="v9.9.9" FAKE_TARBALL="$tarball" \
    bash -c 'cd "$1" && bash < "$2"' _ "$NOPAYLOAD_DIR" "$CDEV_ROOT/install.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"Resolving the latest cdev release..."* ]]
  [[ "$output" == *"Latest release: v9.9.9"* ]]
  [[ "$output" == *"Installing v9.9.9..."* ]]

  [ -f "$TEST_HOME/.cdev.sh" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-restore.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.service" ]
  [ -f "$TEST_HOME/.config/systemd/user/cdev-healthcheck.timer" ]
}
