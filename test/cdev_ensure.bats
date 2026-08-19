#!/usr/bin/env bats
# cdev-ensure's registry dedup, and the fact that it does not need a live
# tmux session to do its registry bookkeeping (tmux itself is stubbed out).

bats_require_minimum_version 1.5.0

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
  _cdev-ensure myproj personal "$TEST_HOME/projects/myproj"

  [ -f "$CDEV_REGISTRY" ]
  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 1 ]
  grep -qxF "myproj personal $TEST_HOME/projects/myproj" "$CDEV_REGISTRY"
}

@test "cdev-ensure called twice with the same name/account/dir dedups to one line" {
  _cdev-ensure myproj personal "$TEST_HOME/projects/myproj"
  _cdev-ensure myproj personal "$TEST_HOME/projects/myproj"

  local matches
  matches=$(grep -cxF "myproj personal $TEST_HOME/projects/myproj" "$CDEV_REGISTRY")
  [ "$matches" -eq 1 ]

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 1 ]
}

@test "cdev-ensure records distinct sessions as separate lines" {
  _cdev-ensure proj-a personal "$TEST_HOME/projects/proj-a"
  _cdev-ensure proj-b work "$TEST_HOME/projects/proj-b"

  local total_lines
  total_lines=$(wc -l < "$CDEV_REGISTRY")
  [ "$total_lines" -eq 2 ]
  grep -qxF "proj-a personal $TEST_HOME/projects/proj-a" "$CDEV_REGISTRY"
  grep -qxF "proj-b work $TEST_HOME/projects/proj-b" "$CDEV_REGISTRY"
}

@test "cdev-ensure creates the session directory if it doesn't exist yet" {
  # The natural way to use `cdev <name> [account] [dir]` is for a brand new
  # project with no directory yet; tmux itself refuses to start a session
  # whose working directory is missing, so cdev has to create it first
  # rather than fail and send the user off to mkdir by hand.
  [ ! -d "$TEST_HOME/projects/new-project" ]
  _cdev-ensure new-project personal "$TEST_HOME/projects/new-project"
  [ -d "$TEST_HOME/projects/new-project" ]
}

@test "cdev-ensure git-inits a brand new project directory" {
  # Every session is spawned with --spawn=worktree, which needs $dir to
  # already be a git repository. A brand new project directory naturally
  # isn't one, found live on a VPS: without this, the session died with
  # "Worktree mode requires a git repository", surfacing only once the
  # separate workspace-trust failure was out of the way, since trust is
  # checked first.
  _cdev-ensure git-me personal "$TEST_HOME/projects/git-me"
  git -C "$TEST_HOME/projects/git-me" rev-parse --is-inside-work-tree
}

@test "cdev-ensure's git init also leaves an initial commit for HEAD to resolve" {
  # git init alone is not enough: an empty repo has no commit for HEAD to
  # resolve to, and claude's own worktree creation needs to resolve HEAD as
  # the base branch, found live on a VPS right after the plain git init fix
  # shipped, failing with "Failed to resolve base branch \"HEAD\": git
  # rev-parse failed". Also has to work on a box with no git identity
  # configured at all yet, a fresh VPS is exactly that.
  _cdev-ensure git-me-head personal "$TEST_HOME/projects/git-me-head"
  git -C "$TEST_HOME/projects/git-me-head" rev-parse HEAD
}

@test "cdev-ensure leaves an already-initialized project directory alone" {
  local dir="$TEST_HOME/projects/already-git"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name test
  git -C "$dir" commit --allow-empty -q -m "existing history"

  _cdev-ensure already-git personal "$dir"

  # Still exactly one commit, cdev did not reinitialize or otherwise touch
  # a repo that was already there.
  local commit_count
  commit_count=$(git -C "$dir" rev-list --count HEAD)
  [ "$commit_count" -eq 1 ]
}

@test "cdev-session-alive is false for a session held open by remain-on-exit with a dead pane" {
  write_stub tmux '
case "$1" in
  has-session) exit 0 ;;
  display-message) echo "1" ;;
  *) exit 0 ;;
esac
'
  run ! _cdev-session-alive stale
}

@test "cdev-session-alive is true for a session whose pane is still running" {
  write_stub tmux '
case "$1" in
  has-session) exit 0 ;;
  display-message) echo "0" ;;
  *) exit 0 ;;
esac
'
  _cdev-session-alive fresh
}

@test "cdev-ensure kills and recreates a session left behind with a dead pane" {
  # A leftover dead-but-remain-on-exit pane blocks `tmux new-session` with
  # "duplicate session" under the same name, has-session alone reads it as
  # already up and would never recreate it, exactly the bug that let a
  # crashed session reattach straight back to its own corpse.
  #
  # TEST_HOME is exported here, not just set: the stub below runs as its
  # own subprocess (a real executable on PATH), which does not inherit a
  # plain shell variable the way a sourced function or `run` command would.
  export TEST_HOME
  write_stub tmux '
case "$1" in
  has-session)
    [ -f "$TEST_HOME/.killed" ] && exit 1 || exit 0
    ;;
  display-message)
    echo "1"
    ;;
  kill-session)
    touch "$TEST_HOME/.killed"
    exit 0
    ;;
  new-session)
    echo "$@" >> "$TEST_HOME/new-session.log"
    exit 0
    ;;
  *) exit 0 ;;
esac
'
  _cdev-ensure stale personal "$TEST_HOME/projects/stale"

  [ -f "$TEST_HOME/new-session.log" ]
  grep -q -- '-s stale' "$TEST_HOME/new-session.log"
}
