#!/usr/bin/env bats
# account -> CLAUDE_CONFIG_DIR mapping: 'personal' maps to ~/.claude, any
# other account name maps to ~/.claude-<account>. Exercised through
# cdev-init, whose already-initialized message reports the resolved
# config_dir and returns before doing anything interactive.

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

@test "account 'personal' maps to ~/.claude" {
  mkdir -p "$TEST_HOME/.claude"

  run cdev-init personal /any/dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_HOME/.claude)"* ]]
}

@test "a non-personal account maps to ~/.claude-<account>" {
  mkdir -p "$TEST_HOME/.claude-work"

  run cdev-init work /any/dir
  [ "$status" -eq 0 ]
  [[ "$output" == *"$TEST_HOME/.claude-work)"* ]]
}

@test "two different non-personal accounts get two different config dirs" {
  mkdir -p "$TEST_HOME/.claude-alpha" "$TEST_HOME/.claude-beta"

  run cdev-init alpha /any/dir
  [[ "$output" == *"$TEST_HOME/.claude-alpha)"* ]]

  run cdev-init beta /any/dir
  [[ "$output" == *"$TEST_HOME/.claude-beta)"* ]]
}
