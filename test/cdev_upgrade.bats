#!/usr/bin/env bats
# `cdev upgrade` (_cdev-upgrade), and its place in the `cdev` dispatcher.
# curl is stubbed to log every invocation it gets, so a test can assert not
# just what got printed but whether the tarball download ever happened.

load test_helper

setup() {
  stub_bin_dir
  stub_tmux_no_session

  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
  CDEV_REGISTRY="$TEST_HOME/.cdev-sessions"

  CURL_LOG="$TEST_HOME/curl.log"
  export CURL_LOG
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

# A curl stub that logs every invocation, answers the "resolve latest tag"
# request with a tag matching the sourced CDEV_VERSION exactly, and fails
# loudly if the "download the tarball" request ever reaches it, so a stray
# download shows up as a test failure instead of passing silently.
stub_curl_already_latest() {
  local tag="v$CDEV_VERSION"
  write_stub curl '
echo "$@" >> "$CURL_LOG"
for arg in "$@"; do
  case "$arg" in
    *releases/latest*)
      echo "https://github.com/pimlabs/cdev/releases/tag/'"$tag"'"
      exit 0
      ;;
    *archive/refs/tags*)
      echo "stub: unexpected tarball download" >&2
      exit 1
      ;;
  esac
done
exit 0
'
}

@test "cdev upgrade prints already-latest and downloads nothing when the resolved tag matches" {
  stub_curl_already_latest

  run cdev upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already on the latest release"* ]]

  [ -f "$CURL_LOG" ]
  ! grep -q 'archive/refs/tags' "$CURL_LOG"
}

@test "cdev upgrade fails clearly when curl is not installed" {
  # An empty PATH containing only the stub dir (which has no curl in it for
  # this test) makes "command -v curl" fail exactly like a box that never
  # had curl installed, without touching the real curl on this machine.
  run bash -c "
    PATH='$STUB_BIN'
    HOME='$TEST_HOME'
    source '$CDEV_ROOT/cdev.sh'
    _cdev-upgrade
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"curl"* ]]
}

@test "cdev upgrade routes to _cdev-upgrade rather than falling through to attach mode" {
  stub_curl_already_latest

  run cdev upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already on the latest release"* ]]

  # Attach mode would have called _cdev-ensure and registered a tmux
  # session named "upgrade". Confirm that never happened.
  [ ! -f "$CDEV_REGISTRY" ] || ! grep -q '^upgrade ' "$CDEV_REGISTRY"
}

# A curl stub for the actual download path (resolved tag differs from
# CDEV_VERSION, so _cdev-upgrade proceeds past the already-latest check):
# resolves to v9.9.9, serves arbitrary tarball bytes (never extracted,
# since checksum verification has to reject it first), and serves a
# SHA256SUMS whose source.tar.gz entry is a well-formed but wrong hash, the
# same shape a tampered or corrupted download would have.
stub_curl_checksum_mismatch() {
  write_stub curl '
echo "$@" >> "$CURL_LOG"
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
    echo "https://github.com/pimlabs/cdev/releases/tag/v9.9.9"
    ;;
  *archive/refs/tags/*)
    echo "not a real tarball" > "$outfile"
    ;;
  *SHA256SUMS)
    echo "0000000000000000000000000000000000000000000000000000000000000000  source.tar.gz" > "$outfile"
    ;;
  *)
    echo "stub curl: unexpected request: $*" >&2
    exit 1
    ;;
esac
'
}

@test "cdev upgrade aborts on a checksum mismatch and never runs install.sh" {
  stub_curl_checksum_mismatch

  run cdev upgrade
  [ "$status" -ne 0 ]
  [[ "$output" == *"checksum mismatch"* ]]
  [[ "$output" != *"Upgraded."* ]]
}
