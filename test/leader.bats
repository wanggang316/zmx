#!/usr/bin/env bats
# Leader hand-off tests — the PTY size follows the most recently active
# terminal client. Claim (tag 18) takes the lead without typing, Release
# (tag 19) gives it back, and when the leader leaves the lead returns to the
# most recently active other client that has sent .Init.
#
# Clients are test/observer_client.py `participant` processes: each sends
# .Init with its own size and answers the daemon's size requests the way
# `zmx attach` does, printing `applied N` once its answer reached the PTY.
# Every wait is on an observable signal (a log line, a file); a participant
# holds its connection open until the test touches its stop file.

load test_helper

observer_client() {
  python3 "$BATS_TEST_DIRNAME/observer_client.py" "$@"
}

# Spawn a session whose PTY has a known size and no leader: a throwaway
# client attaches with .Init rows×cols and disconnects.
spawn_sized_session() {
  local name="$1" rows="$2" cols="$3"
  "$ZMX" run "$name" -d true
  wait_for_session "$name"
  observer_client leader-init "$(session_socket "$name")" "$rows" "$cols"
}

# Ask the session's shell for its PTY size and wait for the answer file.
# `zmx send` has no window (.Init), so it types without taking the lead.
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

# start_participant <id> <session> <rows> <cols> <action>...
# Runs a participant in the background; its output goes to "$T/<id>.log"
# and its pid to "$T/<id>.pid". Callers end the action list with
# wait-file:"$T/<id>.stop" and release it with stop_participant.
start_participant() {
  local id="$1" name="$2"
  shift 2
  observer_client participant "$(session_socket "$name")" "$@" \
    > "$T/$id.log" 2>&1 &
  echo $! > "$T/$id.pid"
}

stop_participant() {
  local id="$1"
  touch "$T/$id.stop"
  wait "$(cat "$T/$id.pid")"
}

wait_for_file() {
  local path="$1" i=0
  while (( i < 50 )); do
    [[ -e "$path" ]] && return 0
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for '$path'" >&2
  return 1
}

wait_for_log() {
  local id="$1" needle="$2" i=0
  while (( i < 50 )); do
    grep -qxF -- "$needle" "$T/$id.log" 2>/dev/null && return 0
    sleep 0.1
    (( i++ )) || true
  done
  echo "Timed out waiting for '$needle' in $id.log" >&2
  cat "$T/$id.log" >&2
  return 1
}

# The "Mac" client: attaches first (no leader yet, so .Init makes it the
# leader at 30×100) and keeps answering size requests until stopped.
start_attached_client() {
  local name="$1"
  start_participant mac "$name" 30 100 \
    init await-lead touch:"$T/mac.ready" wait-file:"$T/mac.stop"
  wait_for_file "$T/mac.ready"
}

setup_file_dirs() {
  T="$BATS_TEST_TMPDIR/leader"
  mkdir -p "$T"
}

@test "leader: a participant that only sends Init does not take the size" {
  setup_file_dirs
  local sess=l-init
  spawn_sized_session "$sess" 24 80
  start_attached_client "$sess"

  start_participant phone "$sess" 40 120 \
    init sync touch:"$T/phone.ready" wait-file:"$T/phone.stop"
  wait_for_file "$T/phone.ready"

  run pty_size "$sess"
  [ "$output" = "30 100" ]

  stop_participant phone
  grep -qxF "leads 0" "$T/phone.log"
  stop_participant mac
}

@test "leader: Claim makes the participant leader at its size" {
  setup_file_dirs
  local sess=l-claim
  spawn_sized_session "$sess" 24 80
  start_attached_client "$sess"

  start_participant phone "$sess" 40 120 \
    init sync claim await-lead touch:"$T/phone.led" wait-file:"$T/phone.stop"
  wait_for_file "$T/phone.led"

  run pty_size "$sess"
  [ "$output" = "40 120" ]

  stop_participant phone
  stop_participant mac
}

@test "leader: the participant disconnecting hands the lead back" {
  setup_file_dirs
  local sess=l-leave
  spawn_sized_session "$sess" 24 80
  start_attached_client "$sess"

  start_participant phone "$sess" 40 120 \
    init sync claim await-lead touch:"$T/phone.led" wait-file:"$T/phone.stop"
  wait_for_file "$T/phone.led"
  run pty_size "$sess"
  [ "$output" = "40 120" ]

  stop_participant phone
  # The mac client was asked for its size again and its answer applied.
  wait_for_log mac "applied 2"
  run pty_size "$sess"
  [ "$output" = "30 100" ]

  stop_participant mac
}

@test "leader: Release hands the lead back while the participant stays" {
  setup_file_dirs
  local sess=l-release
  spawn_sized_session "$sess" 24 80
  start_attached_client "$sess"

  start_participant phone "$sess" 40 120 \
    init sync claim await-lead touch:"$T/phone.led" \
    wait-file:"$T/phone.go" release sync touch:"$T/phone.released" \
    wait-file:"$T/phone.stop"
  wait_for_file "$T/phone.led"
  run pty_size "$sess"
  [ "$output" = "40 120" ]

  touch "$T/phone.go"
  wait_for_file "$T/phone.released"
  wait_for_log mac "applied 2"
  run pty_size "$sess"
  [ "$output" = "30 100" ]

  # Still connected after releasing, and not asked for its size again.
  kill -0 "$(cat "$T/phone.pid")"
  stop_participant phone
  grep -qxF "leads 1" "$T/phone.log"
  stop_participant mac
}

@test "leader: user input from the participant makes it leader" {
  setup_file_dirs
  local sess=l-input marker=leader-typed-5d2c
  spawn_sized_session "$sess" 24 80
  start_attached_client "$sess"

  start_participant phone "$sess" 40 120 \
    init sync "input:echo $marker" await-lead touch:"$T/phone.led" \
    wait-file:"$T/phone.stop"
  wait_for_file "$T/phone.led"
  wait_for_history "$sess" "$marker"

  run pty_size "$sess"
  [ "$output" = "40 120" ]

  stop_participant phone
  stop_participant mac
}

@test "leader: Claim from an observer or a never-Init client changes nothing" {
  setup_file_dirs
  local sess=l-noclaim
  spawn_sized_session "$sess" 24 80
  start_attached_client "$sess"

  # A control connection: never sends .Init.
  run observer_client participant "$(session_socket "$sess")" 40 120 claim sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"leads 0"* ]]

  # An observer, including one that tried to .Init first.
  run observer_client participant "$(session_socket "$sess")" 41 121 \
    observe init sync claim sync
  [ "$status" -eq 0 ]
  [[ "$output" == *"leads 0"* ]]

  run pty_size "$sess"
  [ "$output" = "30 100" ]
  # The attached client kept the lead: it was never asked for its size again.
  run grep -cx "applied [0-9]*" "$T/mac.log"
  [ "$output" = "1" ]

  stop_participant mac
}

@test "leader: ObserveState advertises leader hand-off" {
  local sess=l-flag
  spawn_sized_session "$sess" 24 80

  run observer_client state "$(session_socket "$sess")" 0
  [ "$status" -eq 0 ]
  [[ "$output" =~ flags=([0-9]+) ]]
  (( BASH_REMATCH[1] & 4 ))
}
