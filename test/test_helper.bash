# test_helper.bash — shared setup/teardown for zmx BATS tests

REPO_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

setup() {
  # Build once per test suite (skips if already built)
  if [[ ! -x "$REPO_DIR/zig-out/bin/zmx" ]]; then
    cd "$REPO_DIR" && zig build
  fi
  ZMX="$REPO_DIR/zig-out/bin/zmx"

  # When the suite runs from inside a live zmx session, ZMX_SESSION is
  # inherited by the bats process. `attach` consults it (getSeshNameFromEnv)
  # and, when set, switches to that session instead of attaching to the one
  # under test — so restore.bats' backgrounded attaches would silently target
  # the wrong session. Clear both for a clean, session-agnostic environment.
  unset ZMX_SESSION ZMX_SESSION_PREFIX

  # Isolate socket dir so tests don't interfere with real sessions or each other
  export ZMX_DIR="$BATS_TEST_TMPDIR/zmx-sockets"
  mkdir -p "$ZMX_DIR"
}

teardown() {
  # Kill any sessions created during this test
  if [[ -d "$ZMX_DIR" ]]; then
    local sessions
    sessions=$("$ZMX" list --short 2>/dev/null) || true
    if [[ -n "$sessions" ]]; then
      echo "$sessions" | xargs "$ZMX" kill --force 2>/dev/null || true
    fi
  fi
}

# Helper: wait for a session to appear in list (up to N seconds)
wait_for_session() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" list --short 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name'" >&2
  return 1
}

# ============================================================================
# Restore helpers (used by restore.bats)
# ============================================================================

# Path to a session's per-session control socket. The daemon binds
# "$ZMX_DIR/<session>" (socket.getSocketPath: socket_dir + "/" + name).
session_socket() {
  echo "$ZMX_DIR/$1"
}

# Path to the snapshot the daemon writes on a tag-14 .Snapshot frame
# ("$ZMX_DIR/snapshots/<session>.snap"; see Daemon.handleSnapshot).
snapshot_path() {
  echo "$ZMX_DIR/snapshots/$1.snap"
}

# Path to a session's daemon log ("$ZMX_DIR/logs/<session>.log").
session_log() {
  echo "$ZMX_DIR/logs/$1.log"
}

# Wait until a session disappears from `list --short` (daemon exited and
# deleted its socket). Used after a snapshot, which shuts the daemon down.
wait_for_no_session() {
  local name="$1" timeout="${2:-5}" i=0
  while (( i < timeout * 10 )); do
    if ! "$ZMX" list --short 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for session '$name' to exit" >&2
  return 1
}

# Poll a session's history until it contains a substring, or time out.
# An observable readiness signal — never sleep as a proxy for output.
wait_for_history() {
  local name="$1" needle="$2" timeout="${3:-8}" i=0
  while (( i < timeout * 10 )); do
    if "$ZMX" history "$name" 2>/dev/null | grep -qF -- "$needle"; then
      return 0
    fi
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for '$needle' in history of '$name'" >&2
  echo "--- history ---" >&2
  "$ZMX" history "$name" 2>&1 >&2 || true
  return 1
}

# Trigger a real snapshot by hand-rolling the 8-byte .Snapshot control frame
# and sending it down the session's control socket, then wait for the snapshot
# file to land and the daemon to exit.
#
# Wire frame: ipc.Header is `packed struct { tag: u8, len: u32 }` whose
# @sizeOf is 8 (u40 rounded up). On the wire that is [tag][len LE 4][pad 3].
# .Snapshot is tag 14 (0x0E) with len 0 ->  \016 \000 \000 \000 \000 \000 \000 \000
# (mirrors SessionReaper.sendOneShotKill's .Kill frame [0x05, 0, ...]).
trigger_snapshot() {
  local name="$1" sock
  sock="$(session_socket "$name")"
  printf '\016\000\000\000\000\000\000\000' | nc -U "$sock"
  # Daemon writes "$ZMX_DIR/snapshots/<name>.snap" via atomic rename, then exits.
  local snap; snap="$(snapshot_path "$name")"
  local i=0
  while (( i < 50 )); do
    [[ -f "$snap" ]] && break
    sleep 0.1
    (( i++ )) || true
  done
  [[ -f "$snap" ]] || { echo "Snapshot file '$snap' never appeared" >&2; return 1; }
  wait_for_no_session "$name"
}

# Re-spawn a session via a BACKGROUNDED attach that restores from a snapshot.
# All FDs are redirected so the detached setsid daemon pre-fills the VT mirror
# and survives this short-lived client. Optionally runs the attach from within
# a given working dir (D2 cwd check) — the daemon inherits that cwd because
# execChild does not chdir; the restored shell starts there with no --cwd flag.
#
#   restore_attach <session> <snap-path> [cwd]
restore_attach() {
  local name="$1" snap="$2" cwd="${3:-$PWD}"
  ( cd "$cwd" && exec "$ZMX" attach "$name" --restore-from "$snap" \
      </dev/null >/dev/null 2>&1 ) &
  # The backgrounded pid is recorded so teardown-adjacent cleanup can reap it;
  # callers generally just rely on `kill --force` in teardown().
  RESTORE_ATTACH_PID=$!
}
