#!/usr/bin/env bash
# Persistent, multi-account Claude Code sessions on this VPS.
# Sourced from the shell rc file at install time. Single entrypoint: `cdev
# <subcommand> ...` dispatches to the underscore-prefixed functions below,
# which are implementation detail and not meant to be called directly. The
# systemd units call `cdev restore` and `cdev healthcheck` the same way a
# human would, after sourcing this file.

CDEV_VERSION="0.2.0"
CDEV_REGISTRY="$HOME/.cdev-sessions"
CDEV_REGISTRY_LOCK="$CDEV_REGISTRY.lock"
CDEV_REPO="${CDEV_REPO:-pimlabs/cdev}"

# Map an account to its CLAUDE_CONFIG_DIR. 'personal' uses ~/.claude, any
# other account uses ~/.claude-<account>. One helper so _cdev-ensure,
# _cdev-init, and _cdev-attach can't drift from each other on this mapping.
_cdev-config-dir() {
  local account="${1:-personal}"
  if [ "$account" = "personal" ]; then
    echo "$HOME/.claude"
  else
    echo "$HOME/.claude-$account"
  fi
}

# Runs "$@" with the registry file locked, so a concurrent append
# (_cdev-ensure), removal (_cdev-kill), or restore step can't interleave and
# corrupt the file or resurrect a line another call just removed. Falls back
# to running unlocked when flock isn't available (this box's local dev
# machine has none; every target VPS does, it ships in util-linux), which is
# no worse than before this existed.
#
# Never nest two calls to this function: flock's lock is per open-file-
# description, not reentrant across nested subshells on the same process
# tree, so an outer _cdev-registry-locked call would block forever waiting
# for an inner one to release a lock it can never acquire. Two separate,
# sequential calls are fine, one call wrapping another is a deadlock.
_cdev-registry-locked() {
  if command -v flock >/dev/null 2>&1; then
    (
      flock -x 200
      "$@"
    ) 200>"$CDEV_REGISTRY_LOCK"
  else
    "$@"
  fi
}

# The append half of _cdev-ensure, run under _cdev-registry-locked so it
# can't interleave with a concurrent _cdev-kill's read-modify-write.
_cdev-ensure-append() {
  local name="$1" account="$2" dir="$3"
  touch "$CDEV_REGISTRY"
  # The `--` matters: without it a registry line starting with a dash makes
  # grep read the line as its own options, fail, and take the `||` branch,
  # so the line is appended again on every single call. Paired with
  # _cdev-restore reading this same file line by line, that turns into a
  # loop that never ends and a registry that grows without limit.
  grep -qxF -- "$name $account $dir" "$CDEV_REGISTRY" ||
    echo "$name $account $dir" >> "$CDEV_REGISTRY"
}

# Create the tmux + Remote Control session if it doesn't already exist, and
# record it in the registry. Does not attach, so it is safe to call with no
# terminal attached, which is what the boot path depends on.
_cdev-ensure() {
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir
  config_dir=$(_cdev-config-dir "$account")

  if ! tmux has-session -t "$name" 2>/dev/null; then
    # Passed as separate argv items, plus -e for the env var, rather than one
    # interpolated string: tmux execs a multi-argument command directly with
    # no shell involved, so a name or account containing quotes/semicolons/etc
    # can't break out into arbitrary shell execution (requires tmux >= 3.2
    # for -e on new-session).
    if ! tmux new-session -d -s "$name" -c "$dir" -e "CLAUDE_CONFIG_DIR=$config_dir" \
      claude remote-control --name "$name" --spawn=worktree; then
      # tmux itself refused (no server, name clash, tmux older than 3.2).
      # Report it and skip the registry write rather than recording a
      # session that was never created.
      echo "cdev: failed to create tmux session '$name'" >&2
      return 1
    fi
    tmux set-environment -t "$name" CDEV_ACCOUNT "$account"
  fi

  _cdev-registry-locked _cdev-ensure-append "$name" "$account" "$dir"
}

# One-time interactive login for an account, run inside the target project
# directory. Claude Code's first-run trust dialog is never saved for $HOME,
# so this has to happen in $dir, not wherever the SSH session happens to
# land, or the login "succeeds" but the project still isn't trusted. Safe to
# call again, no-ops if the account's config dir already exists. Deliberately
# NOT called from _cdev-ensure: that path also runs at boot with no attached
# terminal, and an interactive login/trust prompt there would just hang the
# restore service.
_cdev-init() {
  local account="${1:?Usage: cdev init <account> <dir>}"
  local dir="${2:?Usage: cdev init <account> <dir>}"
  local config_dir
  config_dir=$(_cdev-config-dir "$account")

  if [ -d "$config_dir" ]; then
    echo "Account '$account' already initialized ($config_dir)."
    return 0
  fi

  echo "No login yet for account '$account', starting one-time login in $dir..."
  ( cd "$dir" && CLAUDE_CONFIG_DIR="$config_dir" claude )
}

# Interactive entry point: log the account in first if needed, ensure the
# session exists, then attach to it. Reached via `cdev open <name>
# [account] [dir]` (and the older `cdev -- <name> [account] [dir]` escape
# hatch), never via a bare unrecognized word any more, so a name never has
# to avoid colliding with a subcommand.
_cdev-attach() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev open <project-name> [account] [dir]"
    return 1
  fi
  local name="$1"
  local account="${2:-personal}"
  local dir="${3:-$HOME/projects/$name}"
  local config_dir
  config_dir=$(_cdev-config-dir "$account")
  [ -d "$config_dir" ] || _cdev-init "$account" "$dir"

  local was_running=0
  tmux has-session -t "$name" 2>/dev/null && was_running=1
  _cdev-ensure "$name" "$account" "$dir"

  # Only pay for the liveness check on a session this call actually created.
  # A session that was already up cannot be failing at spawn time, so
  # checking before every reattach would tax the common case for nothing.
  # Poll instead of one fixed sleep: a slow/cold-start VPS can take longer
  # than a single early check to get past claude's own startup, and a blind
  # 1s sleep would misdiagnose that as an untrusted-directory failure. The
  # printed fix is shell-quoted so it survives copy-paste.
  if [ "$was_running" -eq 0 ]; then
    local tries=0
    until tmux has-session -t "$name" 2>/dev/null || [ "$tries" -ge 6 ]; do
      sleep 0.5
      tries=$((tries + 1))
    done
    if ! tmux has-session -t "$name" 2>/dev/null; then
      echo "Session '$name' isn't running, it most likely exited immediately"
      echo "because account '$account' isn't trusted in '$dir' yet."
      echo "Fix: cd '$dir' && CLAUDE_CONFIG_DIR='$config_dir' claude"
      echo "Accept the trust prompt, exit, then retry cdev."
      return 1
    fi
  fi

  tmux attach -t "$name"
}

# List the per-account config dirs that exist. Uses find rather than a glob
# on purpose: install.sh now sources this file from ~/.zshrc for zsh users,
# and under zsh's default nomatch an unmatched .claude-* glob aborts the
# command with "no matches found" instead of expanding to nothing, so a box
# with only ~/.claude and no other account would print an error and list
# nothing.
_cdev-accounts() {
  find "$HOME" -maxdepth 1 \( -type d -o -type l \) \
    \( -name '.claude' -o -name '.claude-*' \) 2>/dev/null | sort
}

# Format a duration in seconds as a short human string, e.g. '3d 4h', '12h',
# '45m'. Used by _cdev-status for the UPTIME column.
_cdev-format-duration() {
  local secs="${1:-0}"
  local days=$(( secs / 86400 ))
  local hours=$(( (secs % 86400) / 3600 ))
  local mins=$(( (secs % 3600) / 60 ))

  if [ "$days" -gt 0 ]; then
    printf '%dd %dh' "$days" "$hours"
  elif [ "$hours" -gt 0 ]; then
    printf '%dh' "$hours"
  else
    printf '%dm' "$mins"
  fi
}

# List live sessions with account, attach state, and uptime.
_cdev-status() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}|#{session_attached}|#{session_created}' 2>/dev/null)
  if [ -z "$sessions" ]; then
    echo "No cdev sessions running."
    return
  fi
  printf '%-20s %-14s %-10s %-8s\n' "SESSION" "ACCOUNT" "ATTACHED" "UPTIME"
  echo "$sessions" | while IFS='|' read -r s att created; do
    local acct uptime_secs uptime
    acct=$(tmux show-environment -t "$s" CDEV_ACCOUNT 2>/dev/null | cut -d= -f2)
    [ "$att" = "1" ] && att="yes" || att="no"
    uptime_secs=$(( $(date +%s) - created ))
    uptime=$(_cdev-format-duration "$uptime_secs")
    printf '%-20s %-14s %-10s %-8s\n' "$s" "${acct:-personal}" "$att" "$uptime"
  done
}

# The registry-removal half of _cdev-kill, run under _cdev-registry-locked.
# Uses awk instead of grep -v: the previous `grep -vF -- "$name "` matched
# the name as a SUBSTRING anywhere in the line (account or dir field
# included), so killing "foo" could also silently drop an unrelated line
# whose dir happened to contain the literal text "foo ". awk's $1 is exactly
# the name field (the first whitespace-delimited token, regardless of
# spaces later in the dir field, since $1 stops at the first delimiter),
# compared with plain string equality, never treated as a pattern.
_cdev-kill-remove() {
  local name="$1"
  [ -f "$CDEV_REGISTRY" ] || return 0
  awk -v name="$name" '$1 != name' "$CDEV_REGISTRY" > "$CDEV_REGISTRY.tmp"
  local awk_status=$?
  if [ "$awk_status" -eq 0 ]; then
    mv "$CDEV_REGISTRY.tmp" "$CDEV_REGISTRY"
  else
    rm -f "$CDEV_REGISTRY.tmp"
  fi
}

# Kill a session AND remove it from the registry, so it does not come back
# on the next reboot. A session stopped some other way (crash, VPS restart)
# stays in the registry and gets recreated by `cdev restore`.
_cdev-kill() {
  if [ -z "${1:-}" ]; then
    echo "Usage: cdev kill <project-name>"
    return 1
  fi
  tmux kill-session -t "$1" 2>/dev/null && echo "Session '$1' killed." || echo "Session '$1' not found."
  _cdev-registry-locked _cdev-kill-remove "$1"
}

# Checked under _cdev-registry-locked right before _cdev-restore recreates
# each snapshot entry, so a `cdev kill` that ran after the snapshot was
# taken (but before the loop reached this entry) is honoured instead of
# silently undone. This doesn't close the race completely, a kill landing
# in the gap between this check and the _cdev-ensure call right after it
# can still slip through, but it shrinks the window from "the whole restore
# run" to one fast file check, which is the reasonable stopping point for a
# check-then-act pattern without full transactional locking across both
# operations.
_cdev-restore-still-registered() {
  local name="$1"
  [ -f "$CDEV_REGISTRY" ] || return 1
  awk -v name="$name" '$1 == name { found=1 } END { exit !found }' "$CDEV_REGISTRY"
}

# Recreate every registered session. Run at boot by cdev-restore.service,
# and safe to run by hand since _cdev-ensure no-ops on sessions that are
# already up. This file is sourced into an interactive shell, so it can't
# lean on `set -e` the way a standalone script would; the loop therefore
# handles a failing session explicitly. One session that can't come up must
# not stop the others from being restored, so the failure is counted and
# the loop continues, with a non-zero return at the end so systemd still
# marks the unit failed rather than reporting a clean boot.
_cdev-restore() {
  [ -f "$CDEV_REGISTRY" ] || return 0

  # Iterate over a snapshot, not over the live file. _cdev-ensure appends to
  # the registry, so reading the file directly means the loop can be fed by
  # its own writes and never reach the end.
  local snapshot name account dir failed=0
  snapshot=$(cat "$CDEV_REGISTRY")
  while read -r name account dir; do
    [ -z "$name" ] && continue
    if ! _cdev-registry-locked _cdev-restore-still-registered "$name"; then
      continue
    fi
    if ! _cdev-ensure "$name" "$account" "$dir"; then
      failed=$((failed + 1))
    fi
  done <<< "$snapshot"

  if [ "$failed" -gt 0 ]; then
    echo "cdev restore: $failed session(s) failed to restore" >&2
    return 1
  fi
}

# Notice when a registered session disappeared unexpectedly (a crash), as
# opposed to a clean `cdev kill`, which already removes its own registry
# line so it is never flagged as missing. Opt-in and silent by default:
# does nothing unless ~/.cdev-notify holds a webhook URL. Run every 5
# minutes by cdev-healthcheck.timer, safe to run by hand too.
_cdev-healthcheck() {
  [ -f "$CDEV_REGISTRY" ] || return 0

  local notify_file="$HOME/.cdev-notify"
  [ -s "$notify_file" ] || return 0
  local webhook_url
  webhook_url="$(head -n 1 "$notify_file")"
  [ -n "$webhook_url" ] || return 0

  # Without tmux on PATH every has-session below fails, which would read as
  # "every registered session crashed" and fire one webhook per line. That
  # is a broken check, not a finding, so stop quietly instead. Worth
  # guarding even though tmux is a hard requirement of cdev: this also runs
  # from a systemd --user unit, whose PATH is not the login shell's.
  command -v tmux >/dev/null 2>&1 || return 0

  local host now name account _dir message
  host="$(hostname 2>/dev/null || echo unknown-host)"
  now="$(date -u +%H:%M 2>/dev/null || echo '??:??')"

  while read -r name account _dir; do
    [ -z "$name" ] && continue
    if ! tmux has-session -t "$name" 2>/dev/null; then
      message="cdev: session '$name' (account $account, box $host) disappeared unexpectedly at $now UTC. Registry still lists it; run 'cdev status' to confirm, or 'cdev $name' to respawn."
      # A webhook that is down is not a reason to skip the remaining
      # sessions, and its response body is noise in the journal every 5
      # minutes, so the call is silenced and its failure swallowed.
      curl -fsS -X POST "$webhook_url" -H 'Content-Type: text/plain' -d "$message" >/dev/null 2>&1 || true
    fi
  done < "$CDEV_REGISTRY"
}

# Resolve the newest release tag by following the redirect that
# /releases/latest issues to /releases/tag/<tag>. No JSON to parse without
# jq, and no unauthenticated API rate limit to hit. install.sh carries its
# own copy of this: it has to run before cdev.sh is installed, so the two
# cannot share it.
_cdev-latest-tag() {
  command -v curl >/dev/null 2>&1 || return 1
  local url tag
  url=$(curl -fsSL --connect-timeout 3 --max-time 10 -o /dev/null \
    -w '%{url_effective}' "https://github.com/$CDEV_REPO/releases/latest") || return 1
  tag="${url##*/tag/}"
  case "$tag" in
    v[0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$tag" ;;
    *) return 1 ;;
  esac
}

# Portable sha256: Linux ships sha256sum, macOS ships shasum -a 256, prefer
# whichever exists rather than assuming one. Prints the hex digest only.
# install.sh carries its own copy of this, cdev_sha256, for the same reason
# it carries its own copy of the tag-resolution logic: it has to run before
# cdev.sh is on the box at all, so the two cannot share code.
_cdev-sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    return 1
  fi
}

# Move this box to the latest release. Exists because an install made with
# `curl ... | bash` has no checkout, so there is no `git pull` to run.
_cdev-upgrade() {
  for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "cdev upgrade: $cmd is required." >&2
      return 1
    }
  done

  local tag
  tag=$(_cdev-latest-tag) || {
    echo "cdev upgrade: could not reach GitHub to check for a release." >&2
    return 1
  }

  if [ "$tag" = "v$CDEV_VERSION" ]; then
    echo "Already on the latest release (cdev $CDEV_VERSION)."
    return 0
  fi

  # Deliberately not deciding which of the two is newer. Comparing version
  # strings portably is more machinery than it is worth here, and "install
  # what the project currently publishes" is a defensible answer either way,
  # so the versions are printed and the user can stop if that is not what
  # they wanted.
  echo "Installed: cdev $CDEV_VERSION"
  echo "Latest release: $tag"
  echo "Installing $tag..."

  local work
  work=$(mktemp -d) || return 1

  # Downloaded to a file rather than piped straight into tar, so the
  # checksum below can verify the exact bytes before anything is unpacked.
  if ! curl -fsSL --connect-timeout 5 --max-time 120 \
    "https://github.com/$CDEV_REPO/archive/refs/tags/$tag.tar.gz" \
    -o "$work/source.tar.gz"; then
    echo "cdev upgrade: could not download $tag." >&2
    rm -rf "$work"
    return 1
  fi

  echo "Verifying checksum..."
  if ! curl -fsSL --connect-timeout 5 --max-time 20 \
    "https://github.com/$CDEV_REPO/releases/download/$tag/SHA256SUMS" \
    -o "$work/SHA256SUMS"; then
    echo "cdev upgrade: could not download SHA256SUMS for $tag, aborting." >&2
    echo "This is what protects the downloaded archive against tampering." >&2
    rm -rf "$work"
    return 1
  fi

  local expected actual
  # A single awk rather than grep piped into awk, matching install.sh's
  # cdev_sha256 sibling: grep exiting 1 on no match plus a pipe would make
  # this assignment fail too under a stricter caller, and it is simpler
  # besides, one command instead of two.
  expected="$(awk '$0 ~ / source\.tar\.gz$/ {print $1}' "$work/SHA256SUMS")"
  if [ -z "$expected" ]; then
    echo "cdev upgrade: SHA256SUMS for $tag has no entry for source.tar.gz, aborting." >&2
    rm -rf "$work"
    return 1
  fi

  actual="$(_cdev-sha256 "$work/source.tar.gz")" || {
    echo "cdev upgrade: no sha256sum or shasum available to verify the download." >&2
    rm -rf "$work"
    return 1
  }

  if [ "$expected" != "$actual" ]; then
    echo "cdev upgrade: checksum mismatch for $tag, refusing to install." >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    rm -rf "$work"
    return 1
  fi
  echo "Checksum OK."

  if ! tar -xz -C "$work" --strip-components=1 -f "$work/source.tar.gz"; then
    echo "cdev upgrade: could not unpack $tag." >&2
    rm -rf "$work"
    return 1
  fi

  if [ ! -f "$work/install.sh" ]; then
    echo "cdev upgrade: the $tag tarball has no install.sh." >&2
    rm -rf "$work"
    return 1
  fi

  ( cd "$work" && bash ./install.sh )
  local status=$?
  rm -rf "$work"

  if [ "$status" -eq 0 ]; then
    echo ""
    echo "Upgraded. This shell still holds the old functions, open a new one"
    echo "or run 'source ~/.cdev.sh' to pick up $tag."
  fi
  return "$status"
}

# Reverse what install.sh did to this box: the systemd units, the source
# line in the shell rc file, and the ~/.cdev.sh copy.
#
# A subcommand rather than its own script, unlike install.sh, because of when
# each one runs. install.sh has to work before cdev exists on the box, so it
# must stand alone. Uninstall only ever runs after cdev is installed, so the
# code is already here. That also means it needs no network, which matters:
# people usually remove something because it is misbehaving.
#
# Note every failure path returns rather than exits. This file is sourced
# into the user's interactive shell, so an `exit` here would close their
# terminal.
#
# Deliberately conservative by default, since the things this could destroy
# are the things people actually care about:
#   - running tmux sessions are left alone. Uninstalling the launcher is not
#     a reason to kill live Claude sessions and lose whatever they were in
#     the middle of. Pass --kill-sessions to stop them too.
#   - ~/.cdev-sessions and ~/.cdev-notify are kept. The registry is a record
#     of your projects and the notify file is your webhook config, so both
#     survive a reinstall. Pass --purge to delete them.
#   - linger stays enabled. install.sh turned it on with sudo, but other
#     systemd --user services may depend on it by now, and turning it off
#     would stop them silently. The command to undo it is printed instead.
_cdev-uninstall() {
  local purge=0 kill_sessions=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --purge) purge=1 ;;
      --kill-sessions) kill_sessions=1 ;;
      -h|--help)
        cat <<'EOF'
Usage: cdev uninstall [--kill-sessions] [--purge]

Removes the cdev install from this box: systemd units, the source line in
the shell rc file, and ~/.cdev.sh.

  --kill-sessions  Also stop every running tmux session in the registry.
                   Off by default, uninstalling should not kill live work.
  --purge          Also delete ~/.cdev-sessions (the registry) and
                   ~/.cdev-notify (the webhook URL). Off by default, both
                   survive so a reinstall picks up where you left off.

Linger is never disabled, other systemd --user services may rely on it.
EOF
        return 0
        ;;
      *)
        echo "cdev uninstall: unknown option '$1'" >&2
        echo "Run 'cdev uninstall --help' for usage." >&2
        return 1
        ;;
    esac
    shift
  done

  local -a live_sessions=()
  local name
  if command -v tmux >/dev/null 2>&1 && [ -f "$CDEV_REGISTRY" ]; then
    local _account _dir
    while read -r name _account _dir; do
      [ -z "$name" ] && continue
      if tmux has-session -t "$name" 2>/dev/null; then
        live_sessions+=("$name")
      fi
    done < "$CDEV_REGISTRY"
  fi

  if [ "${#live_sessions[@]}" -gt 0 ]; then
    if [ "$kill_sessions" -eq 1 ]; then
      for name in "${live_sessions[@]}"; do
        tmux kill-session -t "$name" 2>/dev/null && echo "Killed session '$name'." ||
          echo "Could not kill session '$name'."
      done
    else
      echo "Leaving ${#live_sessions[@]} running session(s) alone: ${live_sessions[*]}"
      echo "They keep running under tmux. Re-run with --kill-sessions to stop them,"
      echo "or attach with 'tmux attach -t <name>' once cdev is gone."
    fi
  fi

  local unit_dir="$HOME/.config/systemd/user"
  local -a units=(cdev-restore.service cdev-healthcheck.service cdev-healthcheck.timer)
  local unit

  if command -v systemctl >/dev/null 2>&1; then
    # `disable --now` also stops a running unit. Guarded because a unit that
    # was never installed, or a box where the user systemd bus is not
    # reachable, must not stop the rest of the uninstall.
    for unit in "${units[@]}"; do
      systemctl --user disable --now "$unit" >/dev/null 2>&1 || true
    done
    echo "Disabled systemd units."
  else
    echo "No systemd on this box, skipping unit teardown."
  fi

  for unit in "${units[@]}"; do
    rm -f "$unit_dir/$unit"
  done
  echo "Removed unit files from $unit_dir."

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi

  # Clean both rc files, not just the one matching $SHELL today. install.sh
  # picks the rc file by the shell active at install time, and someone who
  # has switched shells since would otherwise be left with a dangling source
  # line in the other file, which errors on every new shell once ~/.cdev.sh
  # is gone.
  # The single quotes are deliberate, the same way install.sh writes this
  # line: the literal string $HOME is what sits in the rc file, so that is
  # what has to be matched, not its expansion.
  # shellcheck disable=SC2016
  local source_line='source "$HOME/.cdev.sh"'
  local rc grep_status
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    grep -qxF -- "$source_line" "$rc" || continue

    # grep -vF into a temp file, then replace, for the same portability
    # reason _cdev-kill does it: `sed -i` takes a mandatory backup suffix on
    # BSD sed and none on GNU sed. Status 1 is not a failure, it means
    # nothing was selected, which is exactly what an rc file holding nothing
    # but the source line produces, and that empty result is the correct new
    # contents. Only status 2 and up is a real error, and there the file is
    # left alone rather than truncated.
    grep_status=0
    grep -vxF -- "$source_line" "$rc" > "$rc.cdev-tmp" || grep_status=$?
    if [ "$grep_status" -le 1 ]; then
      mv "$rc.cdev-tmp" "$rc"
      echo "Removed the cdev source line from $rc."
    else
      rm -f "$rc.cdev-tmp"
      echo "Could not rewrite $rc, leaving it untouched. Remove this line by hand:" >&2
      echo "  $source_line" >&2
    fi
  done

  # .cdev-restore-all.sh and .cdev-healthcheck.sh are from installs predating
  # the move to `cdev restore` / `cdev healthcheck` subcommands. Deleting
  # ~/.cdev.sh out from under this running function is safe: the shell parsed
  # it into memory when it was sourced and never reads the file again.
  rm -f "$HOME/.cdev.sh" "$HOME/.cdev-restore-all.sh" "$HOME/.cdev-healthcheck.sh"
  echo "Removed ~/.cdev.sh."

  if [ "$purge" -eq 1 ]; then
    rm -f "$CDEV_REGISTRY" "$HOME/.cdev-notify"
    echo "Purged the registry and notify file."
  else
    [ -f "$CDEV_REGISTRY" ] && echo "Kept $CDEV_REGISTRY (pass --purge to delete it)."
    [ -f "$HOME/.cdev-notify" ] && echo "Kept $HOME/.cdev-notify (pass --purge to delete it)."
  fi

  echo ""
  echo "Uninstalled. The cdev function is still defined in this shell, open a"
  echo "new one or run 'unset -f cdev' to clear it."
  if command -v loginctl >/dev/null 2>&1; then
    echo "Linger is still enabled. If nothing else on this box needs it:"
    echo "  sudo loginctl disable-linger $(whoami)"
  fi
  return 0
}

# Print one line of _cdev-doctor's systemd unit report for $1, given that
# systemctl is already known to exist. `is-active` exits non-zero for a unit
# that is merely inactive, so it gets `|| true`: the word it prints is the
# answer we want, not an error. Factored out so this handling only needs to
# be right in one place as more units get added.
_cdev-doctor-unit() {
  local unit="$1" enabled active
  if enabled=$(systemctl --user is-enabled "$unit" 2>/dev/null); then
    active=$(systemctl --user is-active "$unit" 2>/dev/null) || true
    echo "$unit: $enabled, ${active:-unknown}"
  else
    echo "$unit: not installed"
  fi
}

# Report install health: version, matching systemd units, and linger state.
# Every systemctl/loginctl call is guarded so a machine without systemd, or
# without a given unit installed, doesn't crash the function.
_cdev-doctor() {
  echo "Installed: cdev $CDEV_VERSION (~/.cdev.sh)"

  # The $PWD comparison only ever helps someone developing in a checkout,
  # and it is skipped silently everywhere else. An install made with
  # `curl ... | bash` has no checkout at all, so the released version has to
  # come from GitHub or doctor would report nothing and read as up to date.
  if [ -f "./cdev.sh" ]; then
    local repo_version
    repo_version=$(grep '^CDEV_VERSION=' "./cdev.sh" | head -n1 | sed -E 's/CDEV_VERSION="?([^"]*)"?/\1/')
    if [ -n "$repo_version" ]; then
      echo "Repo:      cdev $repo_version (this checkout)"
      if [ "$repo_version" != "$CDEV_VERSION" ]; then
        echo "Versions differ, run ./install.sh again to update."
      fi
    fi
  fi

  local latest
  if latest=$(_cdev-latest-tag); then
    echo "Released:  cdev ${latest#v}"
    if [ "$latest" != "v$CDEV_VERSION" ]; then
      echo "A different version is published, run 'cdev upgrade' to move to $latest."
    fi
  else
    # Offline, no curl, or no releases yet. Not a fault worth an error, but
    # not something to leave looking like a clean bill of health either.
    echo "Released:  could not check (no network, no curl, or no release yet)"
  fi

  echo ""

  # Absent systemd and an uninstalled unit are two different answers, so
  # check for the binary once rather than reporting "not installed" for
  # every unit on a box that could never have installed them. `is-active`
  # exits non-zero for a unit that is merely inactive, so it gets `|| true`:
  # the word it prints is the answer we want, not an error.
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "cdev-restore.service: no systemd on this box"
    echo "cdev-healthcheck.timer: no systemd on this box"
  else
    _cdev-doctor-unit cdev-restore.service
    _cdev-doctor-unit cdev-healthcheck.timer
  fi

  local linger
  if ! command -v loginctl >/dev/null 2>&1; then
    echo "loginctl linger: no loginctl on this box"
  elif linger=$(loginctl show-user "$(whoami)" -p Linger 2>/dev/null); then
    if [ "$linger" = "Linger=yes" ]; then
      echo "loginctl linger: enabled"
    else
      echo "loginctl linger: disabled"
    fi
  else
    echo "loginctl linger: unknown"
  fi
}

_cdev-help() {
  echo "cdev $CDEV_VERSION"
  echo ""
  cat <<'EOF'
Usage: cdev open <name> [account] [dir]
  Attaches to (creating if needed) a persistent session for <name>.
  account defaults to 'personal', mapping to ~/.claude-<account>.
  dir defaults to ~/projects/<name>.
  `cdev -- <name> [account] [dir]` is an older equivalent, still works,
  kept for anyone already using it.

Subcommands:
  open <name> [account] [dir]
                           Create (if needed) and attach to a session.
                           account defaults to 'personal', dir defaults to
                           ~/projects/<name>.
  status                   List running sessions with account, attach state,
                           and uptime.
  kill <name>              Kill a session and remove it from the reboot
                           registry.
  init <account> <dir>     One-time interactive login/trust setup for an
                           account.
  accounts                 List configured account config directories.
  doctor                   Show install version and systemd/linger health.
  upgrade                  Install the latest release. For installs made with
                           the one-line curl command, which have no checkout
                           to git pull.
  uninstall [flags]        Remove the cdev install from this box. Leaves live
                           sessions running and keeps the registry unless
                           told otherwise, see 'cdev uninstall --help'.
  restore                  Recreate every registered session. Run at boot by
                           cdev-restore.service, safe to run by hand.
  healthcheck              Report registered sessions that vanished from tmux.
                           Run every 5 minutes by cdev-healthcheck.timer, and
                           silent unless ~/.cdev-notify holds a webhook URL.
  version (--version, -v)  Print the installed cdev version.
  help (--help, -h)        Show this message.
EOF
}

# Single entrypoint. Routes to the functions above; `cdev open <name>
# [account] [dir]` (or the older `cdev -- <name> ...`) is the only way to
# reach _cdev-attach now, an unrecognized word is an error rather than an
# implicit project name.
cdev() {
  local sub="${1:-}"
  case "$sub" in
    --)
      shift
      _cdev-attach "$@"
      ;;
    open)
      shift
      _cdev-attach "$@"
      ;;
    status)
      shift
      _cdev-status "$@"
      ;;
    kill)
      shift
      _cdev-kill "$@"
      ;;
    init)
      shift
      _cdev-init "$@"
      ;;
    accounts)
      shift
      _cdev-accounts "$@"
      ;;
    doctor)
      shift
      _cdev-doctor "$@"
      ;;
    upgrade)
      shift
      _cdev-upgrade "$@"
      ;;
    uninstall)
      shift
      _cdev-uninstall "$@"
      ;;
    restore)
      shift
      _cdev-restore "$@"
      ;;
    healthcheck)
      shift
      _cdev-healthcheck "$@"
      ;;
    version|--version|-v)
      echo "cdev $CDEV_VERSION"
      ;;
    help|--help|-h|"")
      _cdev-help
      ;;
    -*)
      # A dedicated case rather than letting this fall through to the
      # generic *) below: the message here is specific to flag typos, and
      # points at `cdev -- $sub` for a genuinely dash-named project, which
      # the generic "not a recognized subcommand" message below does not
      # know to suggest.
      echo "cdev: unknown option '$sub'" >&2
      echo "Run 'cdev help' for usage, or 'cdev -- $sub' to use it as a project name." >&2
      return 1
      ;;
    *)
      # No more implicit attach-by-bare-word: a project name that happened
      # to match nothing above used to silently register and attach, which
      # is exactly the collision risk this exists to avoid (see CLAUDE.md /
      # ROADMAP.md). Say so explicitly instead of guessing.
      echo "cdev: '$sub' isn't a recognized subcommand." >&2
      echo "Run 'cdev open $sub' to create or attach to a session named '$sub'," >&2
      echo "or 'cdev help' for the full subcommand list." >&2
      return 1
      ;;
  esac
}

# Let `./cdev.sh <args>` work directly too, not only `source cdev.sh` then
# `cdev <args>`. `return` only succeeds inside a function or a sourced file,
# so wrapping it in a subshell and checking the result is the standard,
# reliable way to tell sourced from executed. The comparison this used to
# do, BASH_SOURCE[0] against $0, looks equivalent but is not: anything that
# invokes bash with an explicit $0 matching the sourced path, which a test
# harness can do easily, makes that comparison misreport a sourced call as a
# direct one. This is a no-op for the installed, sourced-into-rc-file case.
if ! (return 0 2>/dev/null); then
  cdev "$@"
fi
