#!/usr/bin/env bats
# _cdev-restore (the former cdev-restore-all.sh) and _cdev-healthcheck (the
# former cdev-healthcheck.sh), now both plain functions in cdev.sh reached
# via the `cdev restore` / `cdev healthcheck` subcommands. tmux and curl are
# stubbed onto PATH, and each stub logs the args it was called with to a
# file named by an exported env var, so a test can assert on what actually
# got invoked without a real tmux server or network call behind it.

load test_helper

setup() {
  stub_bin_dir
  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
  CDEV_REGISTRY="$TEST_HOME/.cdev-sessions"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

# tmux stub for _cdev-restore tests: no session ever exists yet (so
# _cdev-ensure always proceeds to `new-session`), every new-session call is
# logged, and new-session fails when the session name being created matches
# $TMUX_FAIL_NAME (unset means nothing fails).
stub_tmux_for_restore() {
  write_stub tmux '
case "$1" in
  has-session)
    exit 1
    ;;
  new-session)
    echo "$@" >> "$TMUX_LOG"
    for arg in "$@"; do
      if [ -n "$TMUX_FAIL_NAME" ] && [ "$arg" = "$TMUX_FAIL_NAME" ]; then
        exit 1
      fi
    done
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
}

# tmux stub for _cdev-healthcheck tests: has-session succeeds (session is
# alive) unless the name being checked matches $TMUX_MISSING_NAME.
stub_tmux_for_healthcheck() {
  write_stub tmux '
case "$1" in
  has-session)
    if [ -n "$TMUX_MISSING_NAME" ] && [ "$3" = "$TMUX_MISSING_NAME" ]; then
      exit 1
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
'
}

stub_curl_logging() {
  write_stub curl '
echo "$@" >> "$CURL_LOG"
exit 0
'
}

@test "_cdev-restore with no registry file returns 0 and does nothing" {
  stub_tmux_for_restore
  TMUX_LOG="$TEST_HOME/tmux.log"
  export TMUX_LOG
  rm -f "$CDEV_REGISTRY"

  run _cdev-restore
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$TMUX_LOG" ]
}

@test "_cdev-restore calls _cdev-ensure for every line in a multi-line registry" {
  stub_tmux_for_restore
  TMUX_LOG="$TEST_HOME/tmux.log"
  export TMUX_LOG

  cat > "$CDEV_REGISTRY" <<REGEOF
alpha personal $TEST_HOME/projects/alpha
beta work $TEST_HOME/projects/beta
gamma personal $TEST_HOME/projects/gamma
REGEOF

  run _cdev-restore
  [ "$status" -eq 0 ]

  [ -f "$TMUX_LOG" ]
  grep -q -- '-s alpha' "$TMUX_LOG"
  grep -q -- '-s beta' "$TMUX_LOG"
  grep -q -- '-s gamma' "$TMUX_LOG"
  local calls
  calls=$(wc -l < "$TMUX_LOG")
  [ "$calls" -eq 3 ]
}

@test "_cdev-restore keeps going past a session that fails to create and returns non-zero" {
  stub_tmux_for_restore
  TMUX_LOG="$TEST_HOME/tmux.log"
  TMUX_FAIL_NAME="beta"
  export TMUX_LOG TMUX_FAIL_NAME

  cat > "$CDEV_REGISTRY" <<REGEOF
alpha personal $TEST_HOME/projects/alpha
beta work $TEST_HOME/projects/beta
gamma personal $TEST_HOME/projects/gamma
REGEOF

  run _cdev-restore
  [ "$status" -eq 1 ]
  [[ "$output" == *"1 session(s) failed to restore"* ]]

  # alpha and gamma still got attempted even though beta failed.
  grep -q -- '-s alpha' "$TMUX_LOG"
  grep -q -- '-s beta' "$TMUX_LOG"
  grep -q -- '-s gamma' "$TMUX_LOG"
  local calls
  calls=$(wc -l < "$TMUX_LOG")
  [ "$calls" -eq 3 ]
}

@test "_cdev-healthcheck is silent and returns 0 when ~/.cdev-notify is absent" {
  stub_tmux_for_healthcheck
  stub_curl_logging
  CURL_LOG="$TEST_HOME/curl.log"
  export CURL_LOG

  rm -f "$TEST_HOME/.cdev-notify"
  echo "alpha personal /home/x/projects/alpha" > "$CDEV_REGISTRY"

  run _cdev-healthcheck
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$CURL_LOG" ]
}

@test "_cdev-healthcheck fires one webhook per missing session when ~/.cdev-notify holds a URL" {
  stub_tmux_for_healthcheck
  stub_curl_logging
  CURL_LOG="$TEST_HOME/curl.log"
  TMUX_MISSING_NAME="dead"
  export CURL_LOG TMUX_MISSING_NAME

  echo "https://example.com/webhook" > "$TEST_HOME/.cdev-notify"
  cat > "$CDEV_REGISTRY" <<REGEOF
alive personal /home/x/projects/alive
dead personal /home/x/projects/dead
REGEOF

  run _cdev-healthcheck
  [ "$status" -eq 0 ]

  [ -f "$CURL_LOG" ]
  local calls
  calls=$(wc -l < "$CURL_LOG")
  [ "$calls" -eq 1 ]
  grep -q "https://example.com/webhook" "$CURL_LOG"
  grep -q "'dead'" "$CURL_LOG"
  ! grep -q "'alive'" "$CURL_LOG"
}

@test "_cdev-healthcheck also fires for a session whose pane died but is held open by remain-on-exit" {
  # Not just a vanished session: a crashed pane kept around by
  # remain-on-exit still "has" a session under its name, has-session alone
  # would never catch it, the exact gap that let a dead session go
  # unnoticed through a plain reattach too.
  write_stub tmux '
case "$1" in
  has-session) exit 0 ;;
  display-message)
    [ "$3" = "zombie" ] && echo "1" || echo "0"
    ;;
  *) exit 0 ;;
esac
'
  stub_curl_logging
  CURL_LOG="$TEST_HOME/curl.log"
  export CURL_LOG

  echo "https://example.com/webhook" > "$TEST_HOME/.cdev-notify"
  cat > "$CDEV_REGISTRY" <<REGEOF
alive personal $TEST_HOME/projects/alive
zombie personal $TEST_HOME/projects/zombie
REGEOF

  run _cdev-healthcheck
  [ "$status" -eq 0 ]

  [ -f "$CURL_LOG" ]
  local calls
  calls=$(wc -l < "$CURL_LOG")
  [ "$calls" -eq 1 ]
  grep -q "'zombie'" "$CURL_LOG"
  ! grep -q "'alive'" "$CURL_LOG"
}
