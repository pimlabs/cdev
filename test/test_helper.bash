# Shared setup for the cdev bats suite.
#
# Nothing here may touch the real HOME, the real ~/.cdev-sessions registry,
# or a real tmux/systemd. Every test that needs those points HOME (and, for
# cdev.sh, CDEV_REGISTRY) at a throwaway temp directory created in its own
# setup(), and stubs any external command it calls by putting a fake
# executable earlier on PATH.

CDEV_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Create a temp directory, prepend it to PATH, and remember it in $STUB_BIN
# so write_stub can drop fake executables into it and teardown can remove it.
# Also drops in a flock stub straight away: this dev machine has no real
# flock at all (macOS, verified with `command -v flock`), while every
# target VPS does (util-linux). Without a stub every test would silently
# exercise cdev.sh's unlocked fallback path instead of the locked one that
# actually runs in production, so `command -v flock` has to succeed here.
# The stub does no real locking, it just runs "flock -x 200" as a no-op and
# lets the command after it run, which is enough to exercise the locked
# code path (see _cdev-registry-locked in cdev.sh) without a real lock.
stub_bin_dir() {
  STUB_BIN="$(mktemp -d)"
  PATH="$STUB_BIN:$PATH"
  write_stub flock 'exit 0'
}

# write_stub <name> <body>
# Writes an executable fake command named <name> into $STUB_BIN. <body> is
# shell code that becomes the stub's script body, so it can inspect "$@" and
# exit with whatever status the test needs.
write_stub() {
  local name="$1"
  local body="$2"
  cat > "$STUB_BIN/$name" <<STUBEOF
#!/usr/bin/env bash
$body
STUBEOF
  chmod +x "$STUB_BIN/$name"
}

# A tmux stub good enough for cdev-ensure and cdev-kill tests: reports no
# session ever exists (so cdev-ensure always proceeds to create one) and
# succeeds on every other subcommand (new-session, set-environment,
# kill-session, ...) without starting anything real.
stub_tmux_no_session() {
  write_stub tmux '
case "$1" in
  has-session) exit 1 ;;
  *) exit 0 ;;
esac
'
}
