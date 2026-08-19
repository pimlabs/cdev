#!/usr/bin/env bats
# install.sh's shell rc file detection is no longer used to pick where to
# add a `source` line, cdev is a plain executable now, not a sourced
# function. What it still picks a shell for is the PATH fallback: when
# ~/.local/bin isn't already on PATH, install.sh appends
# `export PATH="$HOME/.local/bin:$PATH"` to ~/.zshrc for zsh users and
# ~/.bashrc otherwise, same zsh-vs-bash-vs-other detection as before, just
# pointed at a different line. Runs the real install.sh against a temp HOME,
# with sudo/systemctl/loginctl stubbed out so nothing touches this machine's
# actual systemd or linger state, and with PATH left as this test's own
# (which never contains $TEST_HOME/.local/bin), so the fallback always fires.

load test_helper

setup() {
  stub_bin_dir
  write_stub systemctl 'exit 0'
  write_stub sudo 'exit 0'
  write_stub loginctl 'exit 0'

  TEST_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$STUB_BIN" "$TEST_HOME"
}

@test "install.sh adds ~/.local/bin to PATH via .zshrc when SHELL is zsh" {
  run env HOME="$TEST_HOME" SHELL="/bin/zsh" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.zshrc" ]
  # shellcheck disable=SC2016
  grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$TEST_HOME/.zshrc"
}

@test "install.sh adds ~/.local/bin to PATH via .bashrc when SHELL is bash" {
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  # shellcheck disable=SC2016
  grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$TEST_HOME/.bashrc"
}

# SHELL is set-but-empty rather than unset on purpose. `env -u SHELL` does
# not survive: bash assigns SHELL from the passwd entry at startup when it
# finds it unset, so on a machine whose login shell is zsh that spelling
# tests the zsh branch by accident and fails here while passing on a CI
# runner whose login shell is bash. An empty SHELL is left alone by bash and
# reaches install.sh as the empty string that `${SHELL:-}` is guarding for.
@test "install.sh adds ~/.local/bin to PATH via .bashrc when SHELL is empty" {
  run env HOME="$TEST_HOME" SHELL="" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  # shellcheck disable=SC2016
  grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$TEST_HOME/.bashrc"
}

@test "install.sh falls back to .bashrc for a shell that is neither bash nor zsh" {
  run env HOME="$TEST_HOME" SHELL="/usr/bin/fish" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  # shellcheck disable=SC2016
  grep -qxF 'export PATH="$HOME/.local/bin:$PATH"' "$TEST_HOME/.bashrc"
}

@test "install.sh does not create a .zshrc when SHELL is bash" {
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ ! -f "$TEST_HOME/.zshrc" ]
}

@test "install.sh does not touch PATH when ~/.local/bin is already on it" {
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$TEST_HOME/.local/bin:$PATH" \
    bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cdev is ready, run 'cdev help' to get started."* ]]

  # No rc file should have been created just to add a PATH line nobody needed.
  [ ! -f "$TEST_HOME/.bashrc" ]
}
