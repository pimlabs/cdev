#!/usr/bin/env bats
# cdev-kill's registry line removal. tmux is stubbed so `tmux kill-session`
# succeeds without a real session behind it.

load test_helper

setup() {
  stub_bin_dir
  stub_tmux_no_session

  TEST_HOME="$(mktemp -d)"
  HOME="$TEST_HOME"

  source "$CDEV_ROOT/cdev.sh"
  CDEV_REGISTRY="$TEST_HOME/.cdev-sessions"

  cat > "$CDEV_REGISTRY" <<REGEOF
alpha personal /home/x/projects/alpha
beta work /home/x/projects/beta
gamma personal /home/x/projects/gamma
REGEOF
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

@test "cdev-kill removes only the matching registry line" {
  _cdev-kill beta

  run grep -c '^beta ' "$CDEV_REGISTRY"
  [ "$output" = "0" ]

  grep -qxF "alpha personal /home/x/projects/alpha" "$CDEV_REGISTRY"
  grep -qxF "gamma personal /home/x/projects/gamma" "$CDEV_REGISTRY"

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 2 ]
}

@test "cdev-kill on a name not in the registry leaves it untouched" {
  _cdev-kill nonexistent

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 3 ]
}

@test "cdev-kill on a name with regex metacharacters doesn't wipe the registry" {
  echo '[bracket personal /home/x/projects/bracket' >> "$CDEV_REGISTRY"

  _cdev-kill '[bracket'

  grep -qxF "alpha personal /home/x/projects/alpha" "$CDEV_REGISTRY"
  grep -qxF "beta work /home/x/projects/beta" "$CDEV_REGISTRY"
  grep -qxF "gamma personal /home/x/projects/gamma" "$CDEV_REGISTRY"

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 3 ]
}
