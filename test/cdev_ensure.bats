#!/usr/bin/env bats
# cdev-ensure's registry dedup, and the fact that it does not need a live
# tmux session to do its registry bookkeeping (tmux itself is stubbed out).

load test_helper

setup() {
  stub_bin_dir
  stub_tmux_no_session

  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
  CDEV_REGISTRY="$TEST_HOME/.cdev-sessions"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

@test "cdev-ensure writes one registry line for a new session" {
  cdev-ensure myproj personal /home/x/projects/myproj

  [ -f "$CDEV_REGISTRY" ]
  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 1 ]
  grep -qxF "myproj personal /home/x/projects/myproj" "$CDEV_REGISTRY"
}

@test "cdev-ensure called twice with the same name/account/dir dedups to one line" {
  cdev-ensure myproj personal /home/x/projects/myproj
  cdev-ensure myproj personal /home/x/projects/myproj

  local matches
  matches=$(grep -cxF "myproj personal /home/x/projects/myproj" "$CDEV_REGISTRY")
  [ "$matches" -eq 1 ]

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 1 ]
}

@test "cdev-ensure records distinct sessions as separate lines" {
  cdev-ensure proj-a personal /home/x/projects/proj-a
  cdev-ensure proj-b work /home/x/projects/proj-b

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 2 ]
  grep -qxF "proj-a personal /home/x/projects/proj-a" "$CDEV_REGISTRY"
  grep -qxF "proj-b work /home/x/projects/proj-b" "$CDEV_REGISTRY"
}
