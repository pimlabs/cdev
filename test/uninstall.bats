#!/usr/bin/env bats
# uninstall.sh, run against a temp HOME with tmux/systemctl/sudo/loginctl
# stubbed, so nothing touches this machine's real registry, units, or linger
# state. The conservative defaults are the point of most of these: leaving
# live sessions and user data alone is behavior, not an oversight, so it is
# tested rather than left to be "cleaned up" by a later change.

load test_helper

setup() {
  stub_bin_dir
  write_stub systemctl 'exit 0'
  write_stub sudo 'exit 0'
  write_stub loginctl 'exit 0'

  TEST_HOME="$(mktemp -d)"
  UNIT_DIR="$TEST_HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"

  # A box that looks installed: dotfile, units, registry, notify file, and a
  # source line in both rc files.
  touch "$TEST_HOME/.cdev.sh"
  touch "$UNIT_DIR/cdev-restore.service" \
        "$UNIT_DIR/cdev-healthcheck.service" \
        "$UNIT_DIR/cdev-healthcheck.timer"
  printf 'alpha personal /tmp/a\nbeta work /tmp/b\n' > "$TEST_HOME/.cdev-sessions"
  echo 'https://example.test/hook' > "$TEST_HOME/.cdev-notify"
  echo 'source "$HOME/.cdev.sh"' > "$TEST_HOME/.bashrc"
  printf '# my zshrc\nsource "$HOME/.cdev.sh"\nalias ll=ls\n' > "$TEST_HOME/.zshrc"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

# tmux stub reporting every session as alive, so the "leave them running"
# path is what gets exercised, and recording kill-session calls.
stub_tmux_alive() {
  write_stub tmux '
case "$1" in
  has-session) exit 0 ;;
  kill-session) echo "$3" >> "$TMUX_KILL_LOG" ; exit 0 ;;
  *) exit 0 ;;
esac
'
  TMUX_KILL_LOG="$TEST_HOME/killed"
  : > "$TMUX_KILL_LOG"
  export TMUX_KILL_LOG
}

run_uninstall() {
  run env HOME="$TEST_HOME" PATH="$PATH" TMUX_KILL_LOG="${TMUX_KILL_LOG:-}" \
    bash "$CDEV_ROOT/uninstall.sh" "$@"
}

@test "uninstall removes the installed dotfile and the systemd unit files" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  [ ! -f "$TEST_HOME/.cdev.sh" ]
  [ ! -f "$UNIT_DIR/cdev-restore.service" ]
  [ ! -f "$UNIT_DIR/cdev-healthcheck.service" ]
  [ ! -f "$UNIT_DIR/cdev-healthcheck.timer" ]
}

@test "uninstall strips the source line from both rc files, not just one" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  run grep -c 'cdev' "$TEST_HOME/.bashrc"
  [ "$output" = "0" ]
  run grep -c 'cdev' "$TEST_HOME/.zshrc"
  [ "$output" = "0" ]
}

# The rc file holding nothing but the source line is the case that broke
# first: grep selects no lines and exits 1, which is "nothing matched", not
# an error, so the rewrite has to go ahead anyway.
@test "an rc file containing only the source line ends up empty, not untouched" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  [ ! -s "$TEST_HOME/.bashrc" ]
}

@test "uninstall leaves unrelated rc file content alone" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  grep -qxF '# my zshrc' "$TEST_HOME/.zshrc"
  grep -qxF 'alias ll=ls' "$TEST_HOME/.zshrc"
}

@test "running sessions are left alive by default" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  [ ! -s "$TMUX_KILL_LOG" ]
  [[ "$output" == *"Leaving 2 running session"* ]]
}

@test "--kill-sessions stops every registered session" {
  stub_tmux_alive
  run_uninstall --kill-sessions
  [ "$status" -eq 0 ]

  grep -qxF 'alpha' "$TMUX_KILL_LOG"
  grep -qxF 'beta' "$TMUX_KILL_LOG"
}

@test "the registry and notify file survive by default" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.cdev-sessions" ]
  [ -f "$TEST_HOME/.cdev-notify" ]
}

@test "--purge deletes the registry and notify file" {
  stub_tmux_alive
  run_uninstall --purge
  [ "$status" -eq 0 ]

  [ ! -f "$TEST_HOME/.cdev-sessions" ]
  [ ! -f "$TEST_HOME/.cdev-notify" ]
}

@test "uninstall never disables linger on its own" {
  stub_tmux_alive
  write_stub loginctl 'echo "$@" >> "$LOGINCTL_LOG"; exit 0'
  LOGINCTL_LOG="$TEST_HOME/loginctl"
  : > "$LOGINCTL_LOG"
  export LOGINCTL_LOG

  run env HOME="$TEST_HOME" PATH="$PATH" LOGINCTL_LOG="$LOGINCTL_LOG" \
    TMUX_KILL_LOG="$TMUX_KILL_LOG" bash "$CDEV_ROOT/uninstall.sh"
  [ "$status" -eq 0 ]

  run grep -c 'disable-linger' "$LOGINCTL_LOG"
  [ "$output" = "0" ]
}

@test "an unknown flag is rejected instead of being ignored" {
  stub_tmux_alive
  run_uninstall --nope
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown option"* ]]

  # A rejected run must not have started tearing anything down.
  [ -f "$TEST_HOME/.cdev.sh" ]
}

@test "uninstall is safe to run twice" {
  stub_tmux_alive
  run_uninstall
  [ "$status" -eq 0 ]

  run_uninstall
  [ "$status" -eq 0 ]
}

@test "uninstall works on a box that was never installed" {
  stub_tmux_alive
  rm -rf "$TEST_HOME"
  TEST_HOME="$(mktemp -d)"

  run env HOME="$TEST_HOME" PATH="$PATH" bash "$CDEV_ROOT/uninstall.sh"
  [ "$status" -eq 0 ]
}
