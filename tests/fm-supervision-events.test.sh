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
FAST_REPAIR_PROGRESS_TICK_PRODUCTION=$(declare -f fast_repair_progress_tick)

# Overrides: capture wake reasons and neutralize real sleeps (POLL is 15s).
WAKE_LOG="$TMP/wakes"
SLEEP_LOG="$TMP/sleeps"
wake() { printf '%s\n' "$1" >> "$WAKE_LOG"; return 0; }
sleep() { printf 'SLEEP\n' >> "$SLEEP_LOG"; }

reset_state() {
  rm -f "$STATE_DIR"/*.meta "$STATE_DIR"/*.status "$STATE_DIR"/.wake-queue \
    "$STATE_DIR"/.wake-queue.seq "$STATE_DIR"/.watch-triage.log \
    "$STATE_DIR"/.herdr-escalated-* "$STATE_DIR"/.fast-repair-progress-wake \
    "$STATE_DIR"/.fast-repair-progress-* "$STATE_DIR"/.last-fast-repair-progress* \
    "$STATE_DIR"/.fast-repair-progress-handoff-* \
    "$STATE_DIR"/.fast-repair-progress-timer.* \
    "$TMP"/panes "$TMP"/wtcalls "$TMP"/wtcalled "$TMP"/fast-repair-transition-complete \
    "$TMP"/fast-repair-parent-returned "$TMP"/fast-repair-handoff-blocked 2>/dev/null || true
  : > "$WAKE_LOG"
  : > "$SLEEP_LOG"
  _event_cap_key=""
  _event_cap_ok=0
  _event_cap_fails=0
  FAST_REPAIR_TIMER_MARKER=
  FAST_REPAIR_TIMER_GENERATION=0
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

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_ACTIVE=0
: > "$TMP/forge-called"
fast_repair_progress_tick() { printf 'called\n' >> "$TMP/forge-called"; }
fast_repair_progress_discover
[ "$FAST_REPAIR_ACTIVE" = 1 ] || fail "Fast Repair metadata was not discovered for its wait-time timer"
[ ! -s "$TMP/forge-called" ] || fail "Fast Repair Forge progress work ran in the main supervision loop"
pass "fast_repair_progress_discover: main supervision reads only Fast Repair metadata"

reset_state
unset -f sleep
FAST_REPAIR_ACTIVE=1
FAST_REPAIR_TIMER_PID=
FAST_REPAIR_TIMER_MARKER=
FAST_REPAIR_PROGRESS_INTERVAL=1
POLL=10
WATCHER_PID=$$
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
touch "$STATE_DIR/.last-fast-repair-progress"
: > "$TMP/fast-repair-timer-ticks"
fast_repair_progress_tick() {
  printf 'tick\n' >> "$TMP/fast-repair-timer-ticks"
  FAST_REPAIR_ACTIVE=1
}
fast_repair_progress_timer_start
command sleep 4.5
fast_repair_progress_timer_finish
wait "$FAST_REPAIR_TIMER_PID" 2>/dev/null || true
[ "$(wc -l < "$TMP/fast-repair-timer-ticks" | tr -d '[:space:]')" -ge 2 ] \
  || fail "a long Fast Repair wait did not repeat its progress timer"
pass "fast_repair_progress_timer_start: Fast Repair repeats progress ticks during a long wait"
eval "$FAST_REPAIR_PROGRESS_TICK_PRODUCTION"

reset_state
fm_write_meta "$STATE_DIR/tk6.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_ACTIVE=1
FAST_REPAIR_TIMER_GENERATION=1
WATCHER_PID=${BASHPID:-$$}
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
fast_repair_progress_timer_start() {
  (
    command sleep 0.05
    printf '%s\n%s\n%s\n' 1 tk6 'fast-repair tk6 broader-tests-failed' \
      > "$STATE_DIR/.fast-repair-progress-handoff-tk6-1"
  ) &
}
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() {
  command sleep 0.15
  printf 'complete\n' > "$TMP/fast-repair-transition-complete"
  return 1
}
event_wait_or_sleep
[ -e "$TMP/fast-repair-transition-complete" ] || fail "a Fast Repair timer interrupted the existing backend transition wait"
grep -q 'check: fast-repair tk6 broader-tests-failed' "$WAKE_LOG" \
  || fail "the durable Fast Repair timer result was not surfaced after the backend transition wait"
pass "event_wait_or_sleep: Fast Repair keeps its timer result durable through the full backend wait"

reset_state
fm_write_meta "$STATE_DIR/tk7.meta" "window=default:wG:pQ" "backend=herdr" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_ACTIVE=1
FAST_REPAIR_TIMER_MARKER=
PARENT_PID=${BASHPID:-$$}
WATCHER_PID=$PARENT_PID
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
trap 'fast_repair_progress_timer_wake' USR1
wake() { printf '%s\t%s\n' "${BASHPID:-$$}" "$1" >> "$WAKE_LOG"; return 0; }
fast_repair_progress_timer_start() {
  local marker closing parent=$WATCHER_PID generation
  FAST_REPAIR_TIMER_GENERATION=$((FAST_REPAIR_TIMER_GENERATION + 1))
  generation=$FAST_REPAIR_TIMER_GENERATION
  marker=$(mktemp "$STATE_DIR/.fast-repair-progress-timer.XXXXXX")
  closing="$marker.closing"
  FAST_REPAIR_TIMER_MARKER=$marker
  (
    command sleep 0.5
    [ -e "$TMP/fast-repair-parent-returned" ] || : > "$TMP/fast-repair-handoff-blocked"
    FM_FAST_REPAIR_TIMER_PARENT="$parent" \
      FM_FAST_REPAIR_TIMER_CLOSING="$closing" \
      FM_FAST_REPAIR_TIMER_GENERATION="$generation" \
      fast_repair_progress_timer_publish tk7 'fast-repair tk7 pr-checks-failed'
    FM_FAST_REPAIR_TIMER_PARENT="$parent" \
      FM_FAST_REPAIR_TIMER_CLOSING="$closing" \
      fast_repair_progress_timer_notify
  ) &
  FAST_REPAIR_TIMER_PID=$!
}
fm_backend_events_capable() { return 0; }
fm_backend_wait_transition() {
  command sleep 0.05
  printf 'complete\n' > "$TMP/fast-repair-transition-complete"
  return 1
}
event_wait_or_sleep
: > "$TMP/fast-repair-parent-returned"
command sleep 0.6
[ -e "$TMP/fast-repair-transition-complete" ] || fail "the shutdown handoff interrupted the backend transition wait"
[ ! -e "$TMP/fast-repair-handoff-blocked" ] || fail "the shutdown handoff blocked on the Fast Repair check"
[ ! -s "$WAKE_LOG" ] || fail "a shutdown handoff woke the watcher outside its safe boundary"
fast_repair_progress_timer_wake
grep -q "^$PARENT_PID.*check: fast-repair tk7 pr-checks-failed" "$WAKE_LOG" \
  || fail "a result written after timer shutdown was not delivered"
pass "event_wait_or_sleep: Fast Repair delivers a result that races timer shutdown"

reset_state
fm_write_meta "$STATE_DIR/tk8.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
PARENT_PID=${BASHPID:-$$}
WATCHER_PID=$PARENT_PID
mkdir -p "$WATCH_LOCK"
printf '%s\n' "$WATCHER_PID" > "$WATCH_LOCK/pid"
FAST_REPAIR_TIMER_GENERATION=2
: > "$STATE_DIR/current.closing"
: > "$STATE_DIR/stale.closing"
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
FM_FAST_REPAIR_TIMER_CLOSING="$STATE_DIR/current.closing" \
FM_FAST_REPAIR_TIMER_GENERATION=2 \
  fast_repair_progress_timer_publish tk8 'fast-repair tk8 pr-checks-green'
fast_repair_progress_timer_wake
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
FM_FAST_REPAIR_TIMER_CLOSING="$STATE_DIR/stale.closing" \
FM_FAST_REPAIR_TIMER_GENERATION=1 \
  fast_repair_progress_timer_publish tk8 'fast-repair tk8 pr-checks-failed'
fast_repair_progress_timer_wake
grep -q 'check: fast-repair tk8 pr-checks-green' "$WAKE_LOG" \
  || fail "the newest Fast Repair result was not delivered"
if grep -q 'check: fast-repair tk8 pr-checks-failed' "$WAKE_LOG"; then
  fail "an older Fast Repair timer result published after a newer result"
fi
pass "fast_repair_progress_timer_wake: stale timer results cannot publish"

reset_state
fm_write_meta "$STATE_DIR/tk12.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
OLD_WATCHER=41001
NEW_WATCHER=41002
WATCHER_PID=$OLD_WATCHER
FM_FAST_REPAIR_TIMER_PARENT="$OLD_WATCHER" \
  FM_FAST_REPAIR_TIMER_GENERATION=7 \
  fast_repair_progress_timer_publish tk12 'fast-repair tk12 broader-tests-failed'
WATCHER_PID=$NEW_WATCHER
fast_repair_progress_timer_wake
grep -q 'fast-repair:tk12' "$STATE_DIR/.wake-queue" \
  || fail "a replacement watcher did not deliver a prior watcher's Fast Repair handoff"
pass "fast_repair_progress_timer_wake: task handoffs survive watcher replacement"

reset_state
fm_write_meta "$STATE_DIR/tk13.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FM_FAST_REPAIR_TIMER_GENERATION=8 \
  fast_repair_progress_timer_publish tk13 'fast-repair tk13 pr-checks-failed'
rm -f "$STATE_DIR/tk13.meta"
fast_repair_progress_timer_wake
[ ! -e "$STATE_DIR/.wake-queue" ] \
  || fail "a torn-down Fast Repair task surfaced a queued progress result"
[ ! -e "$STATE_DIR/.fast-repair-progress-handoff-tk13-8" ] \
  || fail "a torn-down Fast Repair handoff was not discarded after lifecycle revalidation"
pass "fast_repair_progress_timer_wake: torn-down tasks discard pending handoffs"

reset_state
fm_write_meta "$STATE_DIR/tk14.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
FAST_REPAIR_PROGRESS_INTERVAL=20
PROGRESS_CHECKS=0
run_check_capture() {
  PROGRESS_CHECKS=$((PROGRESS_CHECKS + 1))
  FM_CHECK_RESULT=
}
FM_FAST_REPAIR_TIMER_GENERATION=9 fast_repair_progress_tick
FM_FAST_REPAIR_TIMER_GENERATION=10 fast_repair_progress_tick
[ "$PROGRESS_CHECKS" = 1 ] || fail "short waits reset the Fast Repair progress cadence"
pass "fast_repair_progress_tick: short waits retain the task progress cadence"

reset_state
fm_write_meta "$STATE_DIR/tk9a.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
fm_write_meta "$STATE_DIR/tk9b.meta" "window=default:wG:pR" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FAST_REPAIR_TIMER_GENERATION=3
run_check_capture() {
  case "${!#}" in
    tk9a) FM_CHECK_RESULT='fast-repair tk9a pr-checks-green' ;;
    tk9b) FM_CHECK_RESULT='fast-repair tk9b broader-tests-failed' ;;
    *) fail "unexpected Fast Repair progress task: ${!#}" ;;
  esac
}
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
  FM_FAST_REPAIR_TIMER_GENERATION=3 \
  fast_repair_progress_tick
fast_repair_progress_timer_wake
grep -q 'fast-repair:tk9a' "$STATE_DIR/.wake-queue" \
  || fail "the first Fast Repair task was not queued"
grep -q 'fast-repair:tk9b' "$STATE_DIR/.wake-queue" \
  || fail "a later Fast Repair task was starved by the first task"
pass "fast_repair_progress_tick: one timer generation queues every eligible task"

reset_state
fm_write_meta "$STATE_DIR/tk10.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FAST_REPAIR_TIMER_GENERATION=5
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
  FM_FAST_REPAIR_TIMER_GENERATION=4 \
  fast_repair_progress_timer_publish tk10 'fast-repair tk10 pr-checks-failed'
fast_repair_progress_timer_wake
grep -q 'fast-repair:tk10' "$STATE_DIR/.wake-queue" \
  || fail "a late prior-generation handoff was not delivered"
pass "fast_repair_progress_timer_wake: late prior-generation handoffs remain deliverable"

reset_state
fm_write_meta "$STATE_DIR/tk11.meta" "window=default:wG:pQ" "kind=ship" "mode=fast-repair" "fast_repair=eligible"
WATCHER_PID=${BASHPID:-$$}
FAST_REPAIR_TIMER_GENERATION=6
FM_FAST_REPAIR_TIMER_PARENT="$WATCHER_PID" \
  FM_FAST_REPAIR_TIMER_GENERATION=6 \
  fast_repair_progress_timer_publish tk11 'fast-repair tk11 pr-checks-failed'
APPEND_ATTEMPTS=0
fm_wake_append() {
  APPEND_ATTEMPTS=$((APPEND_ATTEMPTS + 1))
  [ "$APPEND_ATTEMPTS" -gt 1 ] || return 1
  printf 'retry\t%s\t%s\n' "$2" "$3" >> "$STATE_DIR/.wake-queue"
}
fast_repair_progress_timer_wake
compgen -G "$STATE_DIR/.fast-repair-progress-handoff-tk11-6" >/dev/null \
  || fail "a failed durable append discarded its Fast Repair handoff"
fast_repair_progress_timer_wake
[ ! -e "$STATE_DIR/.fast-repair-progress-handoff-tk11-6" ] \
  || fail "a successfully queued Fast Repair handoff was not retired"
grep -q 'fast-repair:tk11' "$STATE_DIR/.wake-queue" \
  || fail "a retained Fast Repair handoff did not retry its append"
pass "fast_repair_progress_timer_wake: append failure retains the handoff for retry"

echo "# fm-supervision-events.test.sh: all assertions passed"
