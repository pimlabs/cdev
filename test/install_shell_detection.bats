#!/usr/bin/env bats
# install.sh's shell rc file detection: zsh picks ~/.zshrc, bash or an unset
# SHELL picks ~/.bashrc. Runs the real install.sh against a temp HOME, with
# sudo/systemctl/loginctl stubbed out so nothing touches this machine's
# actual systemd or linger state.

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

@test "install.sh sources cdev.sh from .zshrc when SHELL is zsh" {
  run env HOME="$TEST_HOME" SHELL="/bin/zsh" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.zshrc" ]
  grep -qxF 'source "$HOME/.cdev.sh"' "$TEST_HOME/.zshrc"
}

@test "install.sh sources cdev.sh from .bashrc when SHELL is bash" {
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  grep -qxF 'source "$HOME/.cdev.sh"' "$TEST_HOME/.bashrc"
}

# SHELL is set-but-empty rather than unset on purpose. `env -u SHELL` does
# not survive: bash assigns SHELL from the passwd entry at startup when it
# finds it unset, so on a machine whose login shell is zsh that spelling
# tests the zsh branch by accident and fails here while passing on a CI
# runner whose login shell is bash. An empty SHELL is left alone by bash and
# reaches install.sh as the empty string that `${SHELL:-}` is guarding for.
@test "install.sh sources cdev.sh from .bashrc when SHELL is empty" {
  run env HOME="$TEST_HOME" SHELL="" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  grep -qxF 'source "$HOME/.cdev.sh"' "$TEST_HOME/.bashrc"
}

@test "install.sh falls back to .bashrc for a shell that is neither bash nor zsh" {
  run env HOME="$TEST_HOME" SHELL="/usr/bin/fish" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ -f "$TEST_HOME/.bashrc" ]
  grep -qxF 'source "$HOME/.cdev.sh"' "$TEST_HOME/.bashrc"
}

@test "install.sh does not create a .zshrc when SHELL is bash" {
  run env HOME="$TEST_HOME" SHELL="/bin/bash" PATH="$PATH" bash "$CDEV_ROOT/install.sh"
  [ "$status" -eq 0 ]

  [ ! -f "$TEST_HOME/.zshrc" ]
}
