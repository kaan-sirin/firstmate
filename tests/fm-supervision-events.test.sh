#!/usr/bin/env bash
# tests/fm-supervision-events.test.sh - unit tests for the watcher's native
# event-wait splice (event_wait_or_sleep in bin/fm-watch.sh and
# handle_push_transition in bin/fm-push-transition-lib.sh). The watcher's source
# guard lets this file source it to load
# the functions WITHOUT acquiring the singleton lock or entering the blocking
# loop; wake/sleep and the backend dispatchers are overridden so the exemptions,
# capability memo, and fail-closed disable are asserted deterministically with no
# real herdr, watcher process, or blocking sleeps.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-supervision-events)
STATE_DIR="$TMP/state"
mkdir -p "$STATE_DIR"

# Source the watcher with an isolated state/home. The guard returns before the
# lock/loop, so only the functions load.
export FM_STATE_OVERRIDE="$STATE_DIR"
export FM_ROOT_OVERRIDE="$ROOT"
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$TMP"/panes "$TMP"/wtcalls \
    "$TMP"/wtcalled 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
}

mkrec() {  # <pane_id> <status>
  fm_transition_record "$1" "wG" "" "$2" claude
}

# --- handle_push_transition: enqueue + wake for a non-paused blocked crew -----

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
[ -e "$STATE_DIR/.wake-queue" ] || fail "handle_push_transition should enqueue a wake for a blocked crew"
grep -q 'stale' "$STATE_DIR/.wake-queue" || fail "the enqueued wake must be a stale record: $(cat "$STATE_DIR/.wake-queue")"
grep -q 'default:wG:pQ' "$STATE_DIR/.wake-queue" || fail "the stale record must name the crew's window"
grep -q 'herdr: agent blocked' "$STATE_DIR/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$WAKE_LOG" ] || fail "handle_push_transition must wake the supervisor for a blocked crew"
[ -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "handle_push_transition must commit dedupe only after enqueue"
pass "handle_push_transition: a blocked crew enqueues a stale wake naming its window and wakes the supervisor"

reset_state
fm_write_meta "$STATE_DIR/tk1.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
(
  # shellcheck disable=SC2329 # Runtime override called by the isolated production owner.
  fm_wake_append() { return 1; }
  handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
) >/dev/null 2>&1 || true
[ ! -e "$STATE_DIR/.herdr-escalated-default_wG_pQ" ] || fail "a failed durable enqueue must leave the blocked edge eligible for reconnect reconciliation"
pass "handle_push_transition: enqueue failure cannot commit the Herdr dedupe marker"

# --- handle_push_transition: absorb (no wake, no enqueue) for a declared pause -

reset_state
fm_write_meta "$STATE_DIR/tk2.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
printf 'paused: waiting on the upstream release\n' > "$STATE_DIR/tk2.status"
handle_push_transition herdr default "$(mkrec wG:pQ blocked)"
if [ -e "$STATE_DIR/.wake-queue" ] && grep -q 'stale' "$STATE_DIR/.wake-queue"; then
  fail "a declared-pause crew must NOT be fast-escalated: $(cat "$STATE_DIR/.wake-queue")"
fi
[ ! -s "$WAKE_LOG" ] || fail "a declared-pause crew must not wake the supervisor from the event fast-path"
grep -q 'absorbed push' "$STATE_DIR/.watch-triage.log" 2>/dev/null || fail "the paused absorb should be logged to the triage log"
pass "handle_push_transition: a declared-pause crew is absorbed (no fast wake), left to the poll loop's long cadence"

# --- event_wait_or_sleep: secondmate windows are excluded from the pane list --

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
fm_write_meta "$STATE_DIR/sm1.meta" "window=default:wA:pS" "backend=herdr" "kind=secondmate"
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { shift 4; printf '%s\n' "$*" > "$TMP/panes"; return 1; }
event_wait_or_sleep
PANES=$(cat "$TMP/panes" 2>/dev/null || true)
case "$PANES" in *"default:wG:pQ"*) : ;; *) fail "the ship window must be in the event pane list, got '$PANES'" ;; esac
case "$PANES" in *"default:wA:pS"*) fail "a kind=secondmate window must be EXCLUDED from the event pane list, got '$PANES'" ;; *) : ;; esac
pass "event_wait_or_sleep: herdr windows go on the event pane list, but kind=secondmate endpoints are excluded"

reset_state
fm_write_meta "$STATE_DIR/tk3.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
CAP_CALLS=0
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { CAP_CALLS=$((CAP_CALLS + 1)); return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() {
  [ "${FM_BACKEND_EVENTS_CAPABILITY_CONFIRMED:-0}" = 1 ] || fail "cached capability verdict was not passed to the wait"
  return 1
}
event_wait_or_sleep
event_wait_or_sleep
[ "$CAP_CALLS" = 1 ] || fail "capability probe must be memoized across waits, got $CAP_CALLS calls"
pass "event_wait_or_sleep: one cached capability probe owns validation across bounded waits"

# --- event_wait_or_sleep: a tmux-only home never runs the event path ----------

reset_state
fm_write_meta "$STATE_DIR/tk4.meta" "window=fmses:fm-tk4" "kind=ship"   # no backend= -> tmux
# shellcheck disable=SC2329 # Runtime override called by the isolated watcher.
fm_backend_wait_transition() { printf 'CALLED\n' > "$TMP/wtcalled"; return 1; }
event_wait_or_sleep
[ ! -e "$TMP/wtcalled" ] || fail "a tmux-only home must never invoke the event wait path"
grep -q 'SLEEP' "$SLEEP_LOG" || fail "a tmux-only home must sleep POLL exactly as before"
pass "event_wait_or_sleep: a home with no push-capable window is inert (sleeps POLL, never touches the event path)"

# --- event_wait_or_sleep: runtime failures disable the event path (fail-closed)

reset_state
fm_write_meta "$STATE_DIR/tk5.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship"
export EVENT_CAP_FAIL_MAX=2
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_events_capable() { return 0; }
# shellcheck disable=SC2329 # Runtime overrides called by the isolated watcher.
fm_backend_wait_transition() { printf 'WT\n' >> "$TMP/wtcalls"; return 2; }
: > "$TMP/wtcalls"
event_wait_or_sleep   # fails=1
event_wait_or_sleep   # fails=2 -> disable
event_wait_or_sleep   # disabled: sleeps without calling wait_transition
WTN=$(wc -l < "$TMP/wtcalls" | tr -d '[:space:]')
[ "$WTN" = 2 ] || fail "after EVENT_CAP_FAIL_MAX connect failures the event path must be disabled for the process (expected 2 wait_transition calls, got $WTN)"
pass "event_wait_or_sleep: consecutive event-path failures disable the fast-path and revert to pure polling (fail-closed)"


ordinary_check_state="$TMP/ordinary-check-state"
ordinary_check="$TMP/ordinary-check.sh"
ordinary_check_pid="$TMP/ordinary-check.pid"
ordinary_check_out="$TMP/ordinary-check.out"
mkdir -p "$ordinary_check_state"
cat > "$ordinary_check" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_ORDINARY_CHECK_PID"
trap '' TERM
while :; do sleep 1; done
SH
chmod +x "$ordinary_check"
if ! FM_STATE_OVERRIDE="$ordinary_check_state" FM_ORDINARY_CHECK_PID="$ordinary_check_pid" \
  bash -c '
    set -u
    . "$1"
    run_check_capture "$2" &
    runner=$!
    i=0
    while [ ! -s "$3" ] && [ "$i" -lt 50 ]; do sleep 0.01; i=$((i + 1)); done
    [ -s "$3" ] || exit 1
    check_pid=$(cat "$3")
    pgid=$(ps -o pgid= -p "$check_pid" 2>/dev/null | tr -d "[:space:]")
    case "$pgid" in ""|*[!0-9]*) exit 1 ;; esac
    trap "kill -KILL -- -$pgid 2>/dev/null || true; wait \"$runner\" 2>/dev/null || true" EXIT
    kill -TERM "$runner"
    wait "$runner"
    runner_status=$?
    [ "$runner_status" -eq 1 ] || exit 1
    kill -0 "$check_pid" 2>/dev/null
  ' _ "$ROOT/bin/fm-watch.sh" "$ordinary_check" "$ordinary_check_pid" > "$ordinary_check_out" 2>&1; then
  fail "an ordinary check signal stopped its active check group: $(cat "$ordinary_check_out")"
fi
pass "ordinary checks keep their original signal behavior"

normal_home="$TMP/normal-usr1-home"
normal_state="$normal_home/state"
normal_data="$normal_home/data"
normal_out="$TMP/normal-usr1.out"
mkdir -p "$normal_state" "$normal_data"
FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$normal_home" FM_STATE_OVERRIDE="$normal_state" \
  FM_DATA_OVERRIDE="$normal_data" FM_POLL=60 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$normal_out" 2>&1 &
normal_pid=$!
normal_ready=0
for _ in $(seq 1 50); do
  if [ -s "$normal_state/.watch.lock/pid" ]; then
    normal_ready=1
    break
  fi
  kill -0 "$normal_pid" 2>/dev/null || break
  command sleep 0.02
done
if [ "$normal_ready" -ne 1 ]; then
  kill "$normal_pid" 2>/dev/null || true
  wait "$normal_pid" 2>/dev/null || true
  fail "an ordinary watcher did not start for the USR1 regression: $(cat "$normal_out")"
fi
kill -USR1 "$normal_pid" || fail "could not signal the ordinary watcher with USR1"
wait "$normal_pid"
normal_status=$?
[ "$normal_status" -eq 138 ] \
  || fail "an ordinary watcher changed its USR1 termination status: $normal_status"
pass "ordinary watcher keeps default USR1 termination behavior"

echo "# fm-supervision-events.test.sh: all assertions passed"
