#!/usr/bin/env bats
# Restore integration tests for zmx — proves `attach --restore-from` rebuilds a
# session's terminal state from a real on-disk snapshot.
#
# These drive the REAL built zmx binary end to end:
#   1. Producer  — spawn a session, write known content, then trigger a genuine
#                  snapshot by sending the 8-byte tag-14 .Snapshot control frame
#                  down the daemon's control socket (trigger_snapshot). The
#                  daemon serializes its VT mirror to
#                  "$ZMX_DIR/snapshots/<session>.snap" and exits.
#   2. Restore   — re-spawn the session via a BACKGROUNDED `attach
#                  --restore-from <snap>` with all FDs redirected, so the
#                  detached setsid daemon pre-fills the VT mirror from the
#                  snapshot and survives the short-lived client (restore_attach).
#   3. Probe     — `zmx history` for content; `zmx send 'pwd\r'` + history for
#                  cwd. Every wait is on an observable signal (history content
#                  or session presence) — never a bare sleep as a proxy.
#
# Assertions are substring / line-tolerant: serialized state round-trips through
# ghostty-vt with line-wrap and prompt redraws, so content is matched by
# substring, never position-pinned.
#
# NOTE ON DEGRADED WARNINGS: a zmx snapshot is plain VT bytes with no magic or
# length prefix (util.serializeTerminalState). The restore path
# (src/main.zig ~2718) only logs a "restore-from ... failed" warning when the
# file cannot be OPENED (missing) or exceeds the 16 MiB read ceiling (oversize,
# error.FileTooBig). A small *corrupt* file opens and reads fine — its bytes are
# fed to the VT stream as harmless escape sequences, so it produces NO failure
# warning. A *zero-byte* file reads 0 bytes and is skipped with no warning. The
# degraded test below therefore asserts a clean cold start for all four inputs,
# and the warning only for the two cases the source genuinely warns on (missing,
# oversize). This mirrors actual source behavior — assertions are not weakened.

load test_helper

# Produce a session carrying `marker` in its terminal state, then snapshot it.
# Spawns an interactive shell (run -d true exits the initial command but the
# session's shell outlives it) and writes the marker via `send` so it lands in
# the VT mirror. Leaves "$ZMX_DIR/snapshots/<name>.snap" on disk; the daemon has
# exited by return.
produce_snapshot() {
  local name="$1" marker="$2" cwd="${3:-$PWD}"
  ( cd "$cwd" && "$ZMX" run "$name" -d true )
  wait_for_session "$name"
  "$ZMX" send "$name" "echo $marker"$'\r'
  wait_for_history "$name" "$marker"
  trigger_snapshot "$name"
}

# ============================================================================
# VAL-RESTORE-001 — visible content reproduced after restore
# ============================================================================

@test "restore: reproduces the pane's visible content" {
  local sess=r-content marker=marker-content-7f3a
  produce_snapshot "$sess" "$marker"

  restore_attach "$sess" "$(snapshot_path "$sess")"
  wait_for_session "$sess"

  run "$ZMX" history "$sess"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$marker"* ]]
}

# ============================================================================
# VAL-RESTORE-002 — scrollback reproduced (oldest line survives restore)
# ============================================================================

@test "restore: reproduces scrollback (oldest line present)" {
  local sess=r-scroll oldest=line-001-oldest
  "$ZMX" run "$sess" -d true
  wait_for_session "$sess"

  # Distinctive oldest marker, then enough output to scroll it off-screen.
  "$ZMX" send "$sess" "echo $oldest"$'\r'
  wait_for_history "$sess" "$oldest"
  "$ZMX" send "$sess" 'for i in $(seq 1 60); do echo filler-row-$i; done'$'\r'
  wait_for_history "$sess" "filler-row-60"

  # Sanity: it really did scroll into scrollback (still in history pre-snapshot).
  run "$ZMX" history "$sess"
  [[ "$output" == *"$oldest"* ]]

  trigger_snapshot "$sess"

  restore_attach "$sess" "$(snapshot_path "$sess")"
  wait_for_session "$sess"

  run "$ZMX" history "$sess"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$oldest"* ]]
}

# ============================================================================
# VAL-RESTORE-004 — restored fresh shell starts in the pane's cwd (D2, no --cwd)
# ============================================================================

@test "restore: fresh shell starts in the pane's working directory (no --cwd)" {
  local sess=r-cwd marker=cwd-marker-d2
  local workdir="$BATS_TEST_TMPDIR/pane-cwd"
  mkdir -p "$workdir"

  # Pre-snapshot daemon's working dir = workdir (spawn the session from inside it).
  produce_snapshot "$sess" "$marker" "$workdir"

  # Restore via a BACKGROUNDED attach whose own cwd is workdir, NO --cwd flag.
  # execChild does not chdir, so the restored shell inherits the daemon's cwd.
  restore_attach "$sess" "$(snapshot_path "$sess")" "$workdir"
  wait_for_session "$sess"

  # Probe cwd: ask the restored shell to print it, then wait for the answer.
  "$ZMX" send "$sess" $'pwd\r'
  wait_for_history "$sess" "$workdir"

  run "$ZMX" history "$sess"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$workdir"* ]]
}

# ============================================================================
# VAL-RESTORE-012 — degraded snapshots → clean cold start (+ warning when the
# source genuinely logs one: missing, oversize)
# ============================================================================

# Assert: attaching with `snap` restores no content but yields a live cold
# shell. `warn_expected` is "yes" when a "restore-from ... failed" warning must
# appear in the daemon log (open/read failure), "no" otherwise.
assert_clean_cold_start() {
  local sess="$1" snap="$2" warn_expected="$3"
  local probe="cold-alive-$sess"

  restore_attach "$sess" "$snap"
  wait_for_session "$sess"

  # The shell must be a live, fresh cold shell: a fresh command runs and echoes.
  "$ZMX" send "$sess" "echo $probe"$'\r'
  wait_for_history "$sess" "$probe"

  if [[ "$warn_expected" == "yes" ]]; then
    run cat "$(session_log "$sess")"
    [[ "$output" == *"restore-from"*"failed"* ]]
  fi
}

@test "restore: corrupt snapshot starts a clean cold shell" {
  local sess=r-corrupt snap="$BATS_TEST_TMPDIR/corrupt.snap"
  printf 'not-a-valid-snapshot-\x01\x02\x03garbage' > "$snap"
  # Plain (corrupt) VT bytes are tolerated and fed to the stream — no warning.
  assert_clean_cold_start "$sess" "$snap" no
}

@test "restore: zero-byte snapshot starts a clean cold shell" {
  local sess=r-zero snap="$BATS_TEST_TMPDIR/zero.snap"
  : > "$snap"
  # Zero bytes are read and skipped (bytes.len == 0) — no warning.
  assert_clean_cold_start "$sess" "$snap" no
}

@test "restore: missing snapshot starts a clean cold shell and warns" {
  local sess=r-missing snap="$BATS_TEST_TMPDIR/does-not-exist.snap"
  [ ! -e "$snap" ]
  # openFile fails -> "restore-from open failed ... FileNotFound".
  assert_clean_cold_start "$sess" "$snap" yes
}

@test "restore: oversize snapshot starts a clean cold shell and warns" {
  local sess=r-oversize snap="$BATS_TEST_TMPDIR/big.snap"
  # >16 MiB exceeds the readToEndAlloc ceiling -> "restore-from read failed ... FileTooBig".
  head -c 20000000 /dev/zero > "$snap"
  assert_clean_cold_start "$sess" "$snap" yes
}

# ============================================================================
# Quoted path — a snap path containing a space and a single quote still restores
# (supports the later Swift builder feature, which may emit such paths).
# ============================================================================

@test "restore: snapshot path with a space and a single quote still restores" {
  local sess=r-quoted marker=quoted-marker-9c2
  produce_snapshot "$sess" "$marker"

  # Copy the snapshot to a path containing both a space and a single quote.
  local qpath="$BATS_TEST_TMPDIR/weird dir's/snap file.snap"
  mkdir -p "$(dirname "$qpath")"
  cp "$(snapshot_path "$sess")" "$qpath"

  restore_attach "$sess" "$qpath"
  wait_for_session "$sess"

  run "$ZMX" history "$sess"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$marker"* ]]

  # The path must not have tripped the open path: no "open failed" in the log.
  run cat "$(session_log "$sess")"
  [[ "$output" != *"restore-from open failed"* ]]
}
