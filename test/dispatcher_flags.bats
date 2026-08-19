#!/usr/bin/env bats
# Regression tests for a chain of bugs that made `cdev --version` corrupt the
# registry and hang `cdev restore`.
#
# `--version` was not a dispatcher case, so it fell through to _cdev-attach
# and was treated as a project name. _cdev-ensure's dedup check then ran
# `grep -qxF "$line"` without `--`, so a line starting with a dash was read
# by grep as its own options; grep failed, the `||` branch fired, and the
# line was appended again on every call. _cdev-restore read that same file
# line by line while _cdev-ensure appended to it, so the loop never reached
# the end. A real run left 12,657 identical lines in the registry.

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

@test "cdev --version prints the version and never touches the registry" {
  run cdev --version
  [ "$status" -eq 0 ]
  [[ "$output" == "cdev $CDEV_VERSION" ]]
  [ ! -f "$CDEV_REGISTRY" ]
}

@test "cdev -v prints the version too" {
  run cdev -v
  [ "$status" -eq 0 ]
  [[ "$output" == "cdev $CDEV_VERSION" ]]
}

@test "an unknown flag is rejected instead of becoming a project name" {
  run cdev --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]
  [ ! -f "$CDEV_REGISTRY" ]
}

@test "cdev -- <flag-like-name> still reaches attach mode on purpose" {
  # The escape hatch has to keep working, otherwise rejecting flags above
  # would make a genuinely dash-named project unreachable.
  run cdev -- --weird personal "$TEST_HOME/p"
  grep -qxF -- "--weird personal $TEST_HOME/p" "$CDEV_REGISTRY"
}

@test "cdev -- <ordinary-name> still works as the legacy escape hatch" {
  # Not just for flag-like names: `cdev -- <name>` was the only way to
  # force attach mode even for an ordinary name that collided with a
  # subcommand word, before `cdev open` existed. It has to keep working
  # for anyone already using it.
  run cdev -- myproject personal "$TEST_HOME/p"
  grep -qxF -- "myproject personal $TEST_HOME/p" "$CDEV_REGISTRY"
}

@test "cdev open <name> reaches _cdev-attach the same way the old bare cdev <name> did" {
  run cdev open myproject personal "$TEST_HOME/p"
  grep -qxF -- "myproject personal $TEST_HOME/p" "$CDEV_REGISTRY"
}

@test "a bare unrecognized word is treated as a project name and attached" {
  # Reverted back to this on purpose: cdev <name> is the default action
  # again, matching v0.2.0's original behavior, because typing `open` for
  # the single most common action read as unnecessary friction in practice.
  # Reserved subcommand words stay protected, see the test below, so this
  # only ever applies to a genuinely unrecognized word.
  run cdev myproject personal "$TEST_HOME/p"
  grep -qxF -- "myproject personal $TEST_HOME/p" "$CDEV_REGISTRY"
}

@test "reserved subcommand words stay safe to call directly, never shadowed by a project" {
  # status, kill, doctor, and the rest are matched by their own case arm
  # before the bare-word fallthrough, so a project can never accidentally
  # capture one of these names by being attached first.
  run cdev status
  [ "$status" -eq 0 ]
  [[ "$output" != *"isn't a recognized subcommand"* ]]
  [ ! -f "$CDEV_REGISTRY" ] || ! grep -q '^status ' "$CDEV_REGISTRY"
}

@test "_cdev-ensure dedups a registry line that starts with a dash" {
  _cdev-ensure -- -dashname personal "$TEST_HOME/p" || true
  _cdev-ensure -dashname personal "$TEST_HOME/p" || true
  _cdev-ensure -dashname personal "$TEST_HOME/p" || true

  local total
  total=$(grep -cxF -- "-dashname personal $TEST_HOME/p" "$CDEV_REGISTRY")
  [ "$total" -eq 1 ]
}

@test "_cdev-restore terminates and does not grow a registry it is reading" {
  # `timeout` is coreutils, standard on Linux and in CI, but absent from a
  # stock macOS without brew. Skip rather than fail there.
  command -v timeout >/dev/null 2>&1 || skip "timeout not available"

  printf -- '-dashname personal %s/p\nplain personal %s/q\n' \
    "$TEST_HOME" "$TEST_HOME" > "$CDEV_REGISTRY"
  local before
  before=$(wc -l < "$CDEV_REGISTRY")

  # If the loop is fed by its own writes this never returns, so a timeout
  # is the assertion. Without one a regression hangs the whole suite.
  run timeout 10 bash -c "
    source '$CDEV_ROOT/cdev.sh'
    CDEV_REGISTRY='$CDEV_REGISTRY'
    HOME='$TEST_HOME'
    _cdev-restore
  "
  [ "$status" -ne 124 ]

  local after
  after=$(wc -l < "$CDEV_REGISTRY")
  [ "$after" -eq "$before" ]
}
