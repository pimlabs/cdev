#!/usr/bin/env bats
# _cdev-doctor's "Released:" line, sourced from _cdev-latest-tag, and the
# fact that GitHub being unreachable degrades that one line instead of
# aborting the rest of the report.

load test_helper

setup() {
  stub_bin_dir
  write_stub systemctl 'exit 0'
  write_stub loginctl 'exit 0'

  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

@test "doctor reports a newer release and suggests cdev upgrade" {
  write_stub curl '
echo "https://github.com/pimlabs/cdev/releases/tag/v9.9.9"
exit 0
'
  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Released:  cdev 9.9.9"* ]]
  [[ "$output" == *"run 'cdev upgrade'"* ]]
}

@test "doctor degrades gracefully instead of aborting when GitHub is unreachable" {
  write_stub curl 'exit 1'

  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Released:  could not check (no network, no curl, or no release yet)"* ]]

  # The rest of the report still has to show up, systemd/linger included.
  [[ "$output" == *"cdev-restore.service:"* ]]
  [[ "$output" == *"cdev-healthcheck.timer:"* ]]
  [[ "$output" == *"loginctl linger:"* ]]
}
