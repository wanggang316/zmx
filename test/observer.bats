#!/usr/bin/env bats
# Observer protocol tests — a client that sends .Observe (tag 15) is a
# read-only mirror: it gets an ObserveState snapshot (tag 16), the live Output
# stream, and an ObserveResize notice (tag 17) whenever the leader resizes the
# PTY, and it can never become leader, resize the PTY, or type into it.
#
# The protocol is driven by test/observer_client.py, which speaks the daemon's
# wire format directly (no TTY), against the REAL built zmx binary. Every wait
# is on an observable signal (a reply frame, history content, a file) — the
# daemon handles one client's frames in order, so an ObserveState reply to a
# later .Observe proves the frames sent before it were already processed.

load test_helper

observer_client() {
  python3 "$BATS_TEST_DIRNAME/observer_client.py" "$@"
}

# Spawn a session whose PTY has a known size: a throwaway leader attaches
# with .Init rows×cols and disconnects; the PTY keeps that size.
spawn_sized_session() {
  local name="$1" rows="$2" cols="$3"
  "$ZMX" run "$name" -d true
  wait_for_session "$name"
  observer_client leader-init "$(session_socket "$name")" "$rows" "$cols"
}

# Ask the session's shell for its PTY size and wait for the answer file.
pty_size() {
  local name="$1" out="$BATS_TEST_TMPDIR/stty-$1-$RANDOM"
  "$ZMX" send "$name" "stty size > '$out'"$'\r'
  local i=0
  while (( i < 50 )); do
    [[ -s "$out" ]] && break
    sleep 0.1
    (( i++ )) || true
  done
  cat "$out"
}

@test "observer: first client ever gets an ObserveState with the PTY size" {
  local sess=o-first sock
  # serve spawns the daemon with no client at all (has_had_client=false);
  # the observer snapshot must not wait for a real attach.
  sock="$("$ZMX" serve "$sess" | head -n 1)"
  wait_for_session "$sess"

  run observer_client state "$sock" 0
  [ "$status" -eq 0 ]
  # A real, non-zero window size even though nobody has attached yet.
  [[ "$output" =~ ^state\ [1-9][0-9]*\ [1-9][0-9]*\  ]]
  [[ "$output" == *"reserved=0"* ]]
}

@test "observer: ObserveState reports the leader's size and screen content" {
  local sess=o-state marker=observer-state-4c1e
  spawn_sized_session "$sess" 30 100
  "$ZMX" send "$sess" "echo $marker"$'\r'
  wait_for_history "$sess" "$marker"

  local body="$BATS_TEST_TMPDIR/state-body"
  run observer_client state "$(session_socket "$sess")" 0 "$body"
  [ "$status" -eq 0 ]
  [[ "$output" == "state 30 100 "* ]]
  grep -qF -- "$marker" "$body"
  # The snapshot never switches synchronized output (DECSET 2026) on.
  run grep -qF -- $'\e[?2026h' "$body"
  [ "$status" -ne 0 ]
}

@test "observer: scrollback is capped to the requested rows" {
  local sess=o-scroll oldest=observer-oldest-9b2d
  spawn_sized_session "$sess" 24 80
  "$ZMX" send "$sess" "echo $oldest"$'\r'
  wait_for_history "$sess" "$oldest"
  "$ZMX" send "$sess" 'for i in $(seq 1 60); do echo observer-fill-$i; done'$'\r'
  wait_for_history "$sess" "observer-fill-60"

  local none="$BATS_TEST_TMPDIR/none" all="$BATS_TEST_TMPDIR/all"
  run observer_client state "$(session_socket "$sess")" 0 "$none"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flags=2 "* ]]   # scrollback_truncated, primary screen
  run grep -qF -- "$oldest" "$none"
  [ "$status" -ne 0 ]

  run observer_client state "$(session_socket "$sess")" 100000 "$all"
  [ "$status" -eq 0 ]
  [[ "$output" == *"flags=0 "* ]]
  grep -qF -- "$oldest" "$all"
}

@test "observer: Input, Init and Resize from an observer are ignored" {
  local sess=o-readonly marker=observer-typed-71aa control=observer-control-71aa
  spawn_sized_session "$sess" 30 100

  run observer_client mischief "$(session_socket "$sess")" "$marker"
  [ "$status" -eq 0 ]
  [[ "$output" == *"before 30 100"* ]]
  [[ "$output" == *"after 30 100"* ]]
  [[ "$output" == *"resize_requests 0"* ]]
  [[ "$output" == *"observe_resizes 0"* ]]

  # PTY input is ordered: had the observer's keystrokes been queued they
  # would have reached the shell before this control line.
  "$ZMX" send "$sess" "echo $control"$'\r'
  wait_for_history "$sess" "$control"
  run "$ZMX" history "$sess"
  [[ "$output" != *"$marker"* ]]

  run pty_size "$sess"
  [ "$output" = "30 100" ]
}

@test "observer: a leader resize reaches the observer as ObserveResize" {
  local sess=o-resize
  spawn_sized_session "$sess" 30 100

  run observer_client watch-resize "$(session_socket "$sess")" 40 120 41 121
  [ "$status" -eq 0 ]
  [[ "$output" == *"state 30 100"* ]]
  [[ "$output" == *"resize 40 120"*"resize 41 121"* ]]
  [[ "$output" == *"resynced 41 121"* ]]

  run pty_size "$sess"
  [ "$output" = "41 121" ]
}

@test "observer: receives the live Output stream" {
  local sess=o-output marker=observer-live-3e5f
  spawn_sized_session "$sess" 24 80

  local log="$BATS_TEST_TMPDIR/observer-output"
  observer_client output "$(session_socket "$sess")" "$marker" > "$log" 2>&1 &
  local pid=$!
  local i=0
  while (( i < 50 )); do
    grep -q observing "$log" 2>/dev/null && break
    sleep 0.1
    (( i++ )) || true
  done

  "$ZMX" send "$sess" "echo $marker"$'\r'
  wait "$pid"
  grep -q "output ok" "$log"
}

@test "observer: unknown tags are still ignored" {
  local sess=o-unknown
  spawn_sized_session "$sess" 24 80
  # Tag 200, empty payload: the daemon must log and carry on.
  printf '\310\000\000\000\000\000\000\000' | nc -U "$(session_socket "$sess")"

  run observer_client state "$(session_socket "$sess")" 0
  [ "$status" -eq 0 ]
  [[ "$output" == "state 24 80 "* ]]
}
