#!/usr/bin/env bats
# _cdev-latest-tag: resolves the newest release tag by following the
# redirect that GitHub's /releases/latest issues to /releases/tag/<tag>,
# without touching the network or the GitHub API. curl is stubbed to answer
# with a fixed redirect target instead.

load test_helper

setup() {
  stub_bin_dir
  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

@test "_cdev-latest-tag returns the tag from a valid /tag/ redirect" {
  write_stub curl '
echo "https://github.com/pimlabs/cdev/releases/tag/v1.2.3"
exit 0
'
  run _cdev-latest-tag
  [ "$status" -eq 0 ]
  [ "$output" = "v1.2.3" ]
}

@test "_cdev-latest-tag fails on a redirect with no /tag/ in it" {
  # What a repo with no releases at all redirects to.
  write_stub curl '
echo "https://github.com/pimlabs/cdev/releases"
exit 0
'
  run _cdev-latest-tag
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_cdev-latest-tag fails when curl itself fails" {
  write_stub curl 'exit 1'

  run _cdev-latest-tag
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "_cdev-latest-tag rejects a /tag/ value that is not a version" {
  write_stub curl '
echo "https://github.com/pimlabs/cdev/releases/tag/not-a-version"
exit 0
'
  run _cdev-latest-tag
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
