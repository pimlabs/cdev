#!/usr/bin/env bats
# The self-heal half of _cdev-doctor: adopting a live tmux session that
# never made it into the registry (so it would otherwise vanish silently on
# the next reboot), and printing a fix command for anything it finds
# disabled instead of only naming the problem.

load test_helper

setup() {
  stub_bin_dir
  write_stub systemctl 'exit 0'
  write_stub loginctl 'exit 0'
  write_stub curl 'exit 1'

  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

@test "doctor adopts a live tmux session that isn't in the registry" {
  write_stub tmux '
case "$1" in
  list-sessions) echo "orphan1" ;;
  show-environment) exit 1 ;;
  display-message) echo "/home/eko/projects/orphan1" ;;
  *) exit 0 ;;
esac
'
  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adopted orphan session 'orphan1' into the registry (account personal)"* ]]
  [ -f "$CDEV_REGISTRY" ]
  grep -qxF "orphan1 personal /home/eko/projects/orphan1" "$CDEV_REGISTRY"
}

@test "doctor adopts an orphan session under its own tmux-recorded account" {
  write_stub tmux '
case "$1" in
  list-sessions) echo "orphan2" ;;
  show-environment) echo "CDEV_ACCOUNT=work" ;;
  display-message) echo "/home/eko/projects/orphan2" ;;
  *) exit 0 ;;
esac
'
  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adopted orphan session 'orphan2' into the registry (account work)"* ]]
  grep -qxF "orphan2 work /home/eko/projects/orphan2" "$CDEV_REGISTRY"
}

@test "doctor does not touch a session that is already registered" {
  mkdir -p "$(dirname "$CDEV_REGISTRY")"
  echo "known1 personal /some/dir" > "$CDEV_REGISTRY"
  write_stub tmux '
case "$1" in
  list-sessions) echo "known1" ;;
  *) exit 0 ;;
esac
'
  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Adopted orphan session"* ]]
  [ "$(cat "$CDEV_REGISTRY")" = "known1 personal /some/dir" ]
}

@test "doctor stays silent when there are no live sessions to adopt" {
  stub_tmux_no_session

  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" != *"Adopted orphan session"* ]]
  [ ! -f "$CDEV_REGISTRY" ]
}

@test "doctor distinguishes a disabled unit from one that was never installed, and suggests the fix" {
  stub_tmux_no_session
  write_stub systemctl '
args="$*"
case "$args" in
  *"is-enabled cdev-restore.service"*) echo disabled; exit 1 ;;
  *"is-active cdev-restore.service"*) echo inactive; exit 3 ;;
  *"is-enabled cdev-healthcheck.timer"*) exit 1 ;;
  *) exit 0 ;;
esac
'
  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"cdev-restore.service: disabled, inactive"* ]]
  [[ "$output" == *"Not enabled, run: systemctl --user enable cdev-restore.service"* ]]
  [[ "$output" == *"cdev-healthcheck.timer: not installed"* ]]
  [[ "$output" != *"enable cdev-healthcheck.timer"* ]]
}

@test "doctor suggests enabling linger when it's disabled" {
  stub_tmux_no_session
  write_stub loginctl 'echo "Linger=no"'

  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"loginctl linger: disabled"* ]]
  [[ "$output" == *"run: sudo loginctl enable-linger"* ]]
}

@test "doctor does not suggest enabling linger when it's already enabled" {
  stub_tmux_no_session
  write_stub loginctl 'echo "Linger=yes"'

  run _cdev-doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"loginctl linger: enabled"* ]]
  [[ "$output" != *"enable-linger"* ]]
}
