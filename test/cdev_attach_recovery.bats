#!/usr/bin/env bats
# _cdev-attach's automatic recovery when a session's first attempt dies
# immediately, most commonly a brand new directory that has never been
# trusted under an already-logged-in account (trust is saved per directory,
# not per account, see _cdev-init in cdev.sh). Before this, the user had to
# copy a printed fix command, run it by hand, and retry cdev themselves.
#
# tmux and claude are both stubbed with real state, tracked in plain marker
# files under $TEST_HOME, so the sequence "session created dead, trust step
# runs, session recreated alive" plays out the same way it would for real,
# not just a canned single response.

load test_helper

setup() {
  stub_bin_dir
  TEST_HOME="$(mktemp -d)"
  # Exported, not just set: the tmux/claude stubs below run as their own
  # subprocesses (real executables on PATH), which do not inherit a plain
  # shell variable the way a sourced function or `run` command would.
  export TEST_HOME
  HOME="$TEST_HOME"
  mkdir -p "$TEST_HOME/.claude-work"

  source "$CDEV_ROOT/cdev.sh"
  CDEV_REGISTRY="$TEST_HOME/.cdev-sessions"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

# A session that "new-session" just created starts out dead unless
# $TEST_HOME/.trusted already exists, mirroring an untrusted workspace
# making `claude remote-control` exit immediately. kill-session clears it.
stub_tmux_stateful() {
  write_stub tmux '
case "$1" in
  new-session)
    touch "$TEST_HOME/.session-exists"
    if [ -f "$TEST_HOME/.trusted" ]; then
      rm -f "$TEST_HOME/.session-dead"
    else
      touch "$TEST_HOME/.session-dead"
    fi
    exit 0
    ;;
  kill-session)
    rm -f "$TEST_HOME/.session-exists" "$TEST_HOME/.session-dead"
    exit 0
    ;;
  has-session)
    [ -f "$TEST_HOME/.session-exists" ] && exit 0 || exit 1
    ;;
  display-message)
    [ -f "$TEST_HOME/.session-dead" ] && echo 1 || echo 0
    ;;
  *) exit 0 ;;
esac
'
}

@test "cdev-attach runs a trust step and retries once when the first attempt dies immediately" {
  stub_tmux_stateful
  write_stub claude '
if [ "$1" = "remote-control" ]; then
  exit 0
else
  touch "$TEST_HOME/.trusted"
  exit 0
fi
'

  run _cdev-attach newproj work "$TEST_HOME/projects/newproj"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hasn't"*"trusted"* ]]
  [ -f "$TEST_HOME/.trusted" ]

  local matches
  matches=$(grep -cxF "newproj work $TEST_HOME/projects/newproj" "$CDEV_REGISTRY")
  [ "$matches" -eq 1 ]
}

@test "cdev-attach gives up with a clear message when the retry also fails" {
  stub_tmux_stateful
  # claude never marks the workspace trusted, no matter how many times it's
  # invoked, simulating a failure that is not actually about trust.
  write_stub claude 'exit 0'

  run _cdev-attach newproj work "$TEST_HOME/projects/newproj"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Still not starting"* ]]
}

@test "cdev-attach skips the trust retry entirely when the session is already alive" {
  write_stub tmux '
case "$1" in
  has-session) exit 0 ;;
  display-message) echo 0 ;;
  *) exit 0 ;;
esac
'
  write_stub claude 'echo "should not run" >> "$TEST_HOME/claude-called"; exit 0'

  run _cdev-attach already-up work "$TEST_HOME/projects/already-up"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_HOME/claude-called" ]
}
