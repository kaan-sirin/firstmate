#!/usr/bin/env bash
# Behavior tests for the condition->action adapter of the process-to-event
# runner (bin/fm-procevent-when.sh).
#
# Every scenario is exercised through the adapter's public commands plus the
# generic runner, against real condition and action processes; nothing here
# asserts implementation-source bytes. The suite proves the load-bearing
# guarantees: the action fires exactly once on a stable true, never on a flap,
# never twice across a restart, never from a mutated spec, and every failure
# path ends in a captured terminal outcome that reaches the durable wake queue
# instead of a silent retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-when-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

pe()   { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }
when() { FM_HOME="$1" "$ROOT/bin/fm-procevent-when.sh" "${@:2}"; }

# Every home this suite arms is tracked so teardown can stop any runner still
# blocked on a condition that never fires.
WHEN_HOMES=()
when_teardown() {
  local home seen=$'\n'
  for home in ${WHEN_HOMES[@]+"${WHEN_HOMES[@]}"}; do
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap when_teardown EXIT

new_home() { mkdir -p "$1/state"; WHEN_HOMES+=("$1"); }

wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

wait_for_result() {  # <home> <source-id> [tries]
  local n=${3:-150}
  for _ in $(seq 1 "$n"); do
    first_result "$1" "$2" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}

wait_for_file() {  # <file> [tries]
  local n=${2:-150}
  for _ in $(seq 1 "$n"); do [ -e "$1" ] && return 0; sleep 0.1; done
  return 1
}

# A condition that is true exactly when its trigger file exists, and counts
# every evaluation so flap tests can wait on real poll activity.
COND="$TMP_ROOT/cond.sh"
cat > "$COND" <<'SH'
#!/bin/bash
trigger=$1
counter=$2
echo x >> "$counter"
[ -e "$trigger" ]
SH
chmod +x "$COND"

# An action that records every invocation, so exactly-once is observable.
ACT="$TMP_ROOT/act.sh"
cat > "$ACT" <<'SH'
#!/bin/bash
log=$1
exit_code=${2:-0}
echo invoked >> "$log"
echo "action ran against $log"
exit "$exit_code"
SH
chmod +x "$ACT"

count_lines() { [ -e "$1" ] && grep -c . "$1" || echo 0; }

# --- arm binds the pair and refuses a duplicate ------------------------------
H="$TMP_ROOT/h-arm"; new_home "$H"
out=$(when "$H" arm arm-test --interval 0.1 \
  --condition "$COND" "$TMP_ROOT/never" "$TMP_ROOT/arm-count" \
  --action "$ACT" "$TMP_ROOT/arm-act")
assert_contains "$out" "armed: when-arm-test" "arm reports the canonical source id"
assert_present "$H/state/when/when-arm-test.spec" "arm writes the private spec"
assert_present "$H/state/when/when-arm-test.trust" "arm writes the trust binding"
assert_present "$H/state/procevent/when-arm-test.source" "arm registers the process-event source"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$H/state/when/when-arm-test.spec")
assert_contains "$mode" 600 "the spec is private"
if when "$H" arm arm-test --condition true --action true 2>"$TMP_ROOT/dup.err"; then
  fail "re-arming an existing watch must be refused"
fi
assert_grep "already exists" "$TMP_ROOT/dup.err" "the duplicate refusal names the leftover state"
sid=$(when "$H" source-id arm-test)
assert_contains "$sid" "when-arm-test" "source-id prints the canonical id"
out=$(when "$H" retire arm-test)
assert_contains "$out" "retired: when-arm-test" "retire reports the source"
assert_absent "$H/state/when/when-arm-test.spec" "retire removes the spec"
assert_absent "$H/state/when/when-arm-test.trust" "retire removes the trust binding"
assert_absent "$H/state/procevent/when-arm-test.source" "retire drops the registration"
out=$(when "$H" retire arm-test)
assert_contains "$out" "retired: when-arm-test" "retire is idempotent"
pass "arm binds, refuses duplicates, and retire cleans up"

# --- concurrent arms publish exactly one complete registration ---------------
H="$TMP_ROOT/h-concurrent-arm"; new_home "$H"
(
  when "$H" arm race --stable 1 --condition true --action "$ACT" "$TMP_ROOT/race-a" \
    >"$TMP_ROOT/race-a.out" 2>"$TMP_ROOT/race-a.err"
  printf '%s\n' "$?" > "$TMP_ROOT/race-a.rc"
) &
pid_a=$!
(
  when "$H" arm race --stable 1 --condition true --action "$ACT" "$TMP_ROOT/race-b" \
    >"$TMP_ROOT/race-b.out" 2>"$TMP_ROOT/race-b.err"
  printf '%s\n' "$?" > "$TMP_ROOT/race-b.rc"
) &
pid_b=$!
wait "$pid_a" "$pid_b"
rc_a=$(cat "$TMP_ROOT/race-a.rc")
rc_b=$(cat "$TMP_ROOT/race-b.rc")
[ $((rc_a + rc_b)) -eq 1 ] || fail "exactly one concurrent arm must succeed"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-race || fail "the winning concurrent arm did not produce an outcome"
assert_contains "$(( $(count_lines "$TMP_ROOT/race-a") + $(count_lines "$TMP_ROOT/race-b") ))" 1 \
  "only the winning concurrent registration fires"
pass "concurrent arms publish exactly one complete watch"

# --- the happy path: stable true fires the action exactly once ---------------
H="$TMP_ROOT/h-fire"; new_home "$H"
TRIG="$TMP_ROOT/fire-trigger"
ACTLOG="$TMP_ROOT/fire-act"
when "$H" arm fire --interval 0.1 --stable 2 \
  --condition "$COND" "$TRIG" "$TMP_ROOT/fire-count" \
  --action "$ACT" "$ACTLOG" >/dev/null
pe "$H" reconcile >/dev/null
# Let the runner observe some clean falses before the condition turns true.
wait_for_file "$TMP_ROOT/fire-count" || fail "the condition was never polled"
: > "$TRIG"
wait_for_result "$H" when-fire || fail "no outcome was captured after the condition held"
RESULT=$(first_result "$H" when-fire)
assert_grep 'status: fired' "$RESULT" "the outcome records a fired action"
assert_grep 'action_exit: 0' "$RESULT" "the outcome records the action exit"
assert_grep 'action ran against' "$RESULT" "the outcome carries the action output"
assert_contains "$(when "$H" classify "$RESULT")" fired "classify reads the outcome"
when "$H" terminal "$RESULT" || fail "a fired outcome must be terminal"
# The generic runner retires a terminal source: no restart, no second fire.
for _ in $(seq 1 100); do
  [ ! -e "$H/state/procevent/when-fire.source" ] && break
  sleep 0.1
done
assert_absent "$H/state/procevent/when-fire.source" "a fired watch retires its registration"
pe "$H" reconcile >/dev/null
sleep 0.5
assert_contains "$(count_lines "$ACTLOG")" 1 "the action ran exactly once"
payload=$(wake_payloads "$H")
assert_contains "$payload" "procevent when when-fire 1" "the outcome wake reached the durable queue"
assert_not_contains "$payload" "action ran" "action output never reaches the event line"
out=$(pe "$H" handled when-fire 1)
assert_contains "$out" "handled: when-fire 1" "the outcome acknowledges through the generic channel"
pass "a stable true fires the action exactly once and wakes with the outcome"

# --- a flapping condition never fires ----------------------------------------
H="$TMP_ROOT/h-flap"; new_home "$H"
FLAPLOG="$TMP_ROOT/flap-act"
# True on the first poll only, then false forever: with --stable 2 this must
# never fire.
FLAP="$TMP_ROOT/flap.sh"
cat > "$FLAP" <<'SH'
#!/bin/bash
counter=$1
echo x >> "$counter"
[ "$(grep -c . "$counter")" -eq 1 ]
SH
chmod +x "$FLAP"
when "$H" arm flap --interval 0.1 --stable 2 \
  --condition "$FLAP" "$TMP_ROOT/flap-count" \
  --action "$ACT" "$FLAPLOG" >/dev/null
pe "$H" reconcile >/dev/null
for _ in $(seq 1 150); do
  [ "$(count_lines "$TMP_ROOT/flap-count")" -ge 5 ] && break
  sleep 0.1
done
[ "$(count_lines "$TMP_ROOT/flap-count")" -ge 5 ] || fail "the flapping condition was not polled enough to judge"
assert_absent "$FLAPLOG" "a one-shot true below the stable count never fires the action"
assert_absent "$H/state/when/when-flap.fired" "no fire was claimed"
when "$H" retire flap >/dev/null
pass "a flapping condition never reaches the action"

# --- an action failure is captured and surfaced, never swallowed -------------
H="$TMP_ROOT/h-actfail"; new_home "$H"
FAILLOG="$TMP_ROOT/actfail-act"
when "$H" arm actfail --interval 0.1 --stable 1 \
  --condition true \
  --action "$ACT" "$FAILLOG" 7 >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-actfail || fail "no outcome was captured for the failing action"
RESULT=$(first_result "$H" when-actfail)
assert_grep 'status: action-failed' "$RESULT" "the outcome records the failure"
assert_grep 'action_exit: 7' "$RESULT" "the outcome records the exact exit code"
assert_contains "$(when "$H" classify "$RESULT")" action-failed "classify distinguishes the failure"
when "$H" terminal "$RESULT" || fail "a failed action outcome must be terminal"
assert_contains "$(count_lines "$FAILLOG")" 1 "the failing action still ran exactly once"
pass "an action failure wakes with the captured error"

# --- a condition that errors past its budget wakes instead of retrying -------
H="$TMP_ROOT/h-conderr"; new_home "$H"
CONDERRLOG="$TMP_ROOT/conderr-act"
BROKEN="$TMP_ROOT/broken.sh"
cat > "$BROKEN" <<'SH'
#!/bin/bash
echo "cannot reach the service" >&2
exit 3
SH
chmod +x "$BROKEN"
when "$H" arm conderr --interval 0.1 --error-budget 2 \
  --condition "$BROKEN" \
  --action "$ACT" "$CONDERRLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-conderr || fail "no outcome was captured for the erroring condition"
RESULT=$(first_result "$H" when-conderr)
assert_grep 'status: condition-error' "$RESULT" "the outcome records the condition error"
assert_grep 'cannot reach the service' "$RESULT" "the outcome carries the condition diagnostics"
assert_absent "$CONDERRLOG" "an erroring condition never reaches the action"
assert_absent "$H/state/when/when-conderr.fired" "no fire was claimed on an ambiguous condition"
pass "a repeatedly erroring condition wakes firstmate instead of firing"

# --- a deadline that passes wakes with never-true -----------------------------
H="$TMP_ROOT/h-deadline"; new_home "$H"
DEADLOG="$TMP_ROOT/deadline-act"
when "$H" arm deadline --interval 0.1 --deadline 1 \
  --condition false \
  --action "$ACT" "$DEADLOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-deadline || fail "no outcome was captured after the deadline"
RESULT=$(first_result "$H" when-deadline)
assert_grep 'status: never-true' "$RESULT" "the outcome records the expired deadline"
assert_absent "$DEADLOG" "the action never ran"
pass "an expired deadline wakes with never-true"

# --- a poll completing true after its deadline cannot fire -------------------
H="$TMP_ROOT/h-late-true"; new_home "$H"
LATELOG="$TMP_ROOT/late-true-act"
LATE="$TMP_ROOT/late-true.sh"
cat > "$LATE" <<'SH'
#!/bin/bash
sleep 2
exit 0
SH
chmod +x "$LATE"
when "$H" arm late-true --stable 1 --deadline 1 --condition-timeout 3 \
  --condition "$LATE" --action "$ACT" "$LATELOG" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-late-true || fail "no outcome was captured for a condition completing after deadline"
RESULT=$(first_result "$H" when-late-true)
assert_grep 'status: never-true' "$RESULT" "a late true is rejected after the deadline"
assert_absent "$LATELOG" "a condition completing true after deadline never fires"
pass "a late true poll cannot fire after its deadline"

# --- a timed-out action cannot leave descendants running ---------------------
H="$TMP_ROOT/h-timeout"; new_home "$H"
DESCENDANT_EFFECT="$TMP_ROOT/descendant-effect"
DESCENDANT_PID="$TMP_ROOT/descendant-pid"
SPAWNER="$TMP_ROOT/spawner.sh"
cat > "$SPAWNER" <<'SH'
#!/bin/bash
(
  trap '' TERM
  sleep 10
  printf 'late effect\n' > "$1"
) &
printf '%s\n' "$!" > "$2"
wait
SH
chmod +x "$SPAWNER"
when "$H" arm timeout --stable 1 --action-timeout 1 \
  --condition true --action "$SPAWNER" "$DESCENDANT_EFFECT" "$DESCENDANT_PID" >/dev/null
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-timeout || fail "no outcome was captured for the timed-out action"
RESULT=$(first_result "$H" when-timeout)
assert_grep 'status: action-failed' "$RESULT" "the action timeout is captured as a failure"
assert_grep 'action_exit: 124' "$RESULT" "the action timeout uses the shared timeout status"
wait_for_file "$DESCENDANT_PID" || fail "the timeout fixture did not record its descendant"
descendant_pid=$(cat "$DESCENDANT_PID")
for _ in $(seq 1 20); do
  descendant_state=$(ps -o stat= -p "$descendant_pid" 2>/dev/null | tr -d ' ' || true)
  case "$descendant_state" in ''|Z*) break ;; esac
  sleep 0.1
done
descendant_state=$(ps -o stat= -p "$descendant_pid" 2>/dev/null | tr -d ' ' || true)
case "$descendant_state" in
  ''|Z*) ;;
  *)
    kill -KILL "$descendant_pid" 2>/dev/null || true
    fail "a timed-out action left descendant $descendant_pid alive ($descendant_state)"
    ;;
esac
assert_absent "$DESCENDANT_EFFECT" "a timed-out action leaves no descendant effect"
pass "action timeouts terminate the complete process group"

# --- command output staging remains bounded while the command runs -----------
H="$TMP_ROOT/h-bounded-output"; new_home "$H"
NOISY_READY="$TMP_ROOT/noisy-ready"
NOISY="$TMP_ROOT/noisy.sh"
cat > "$NOISY" <<'SH'
#!/bin/bash
printf 'ready\n' > "$1"
i=0
while [ "$i" -lt 20000 ]; do
  printf '0123456789012345678901234567890123456789\n'
  i=$((i + 1))
done
sleep 1
SH
chmod +x "$NOISY"
FM_WHEN_OUTPUT_TAIL_BYTES=128 when "$H" arm bounded-output --stable 1 \
  --condition true --action "$NOISY" "$NOISY_READY" >/dev/null
FM_WHEN_OUTPUT_TAIL_BYTES=128 pe "$H" reconcile >/dev/null
wait_for_file "$NOISY_READY" || fail "the noisy action did not start"
for staged in "$H/state/when"/.run-out.*; do
  [ -e "$staged" ] || continue
  staged_size=$(wc -c < "$staged" | tr -d ' ')
  [ "$staged_size" -le 128 ] || fail "command output staging exceeded its configured bound"
done
wait_for_result "$H" when-bounded-output || fail "no outcome was captured for the noisy action"
pass "command output staging stays within its byte bound"

# --- a restart after a claimed fire never runs the action twice ---------------
H="$TMP_ROOT/h-crash"; new_home "$H"
CRASHLOG="$TMP_ROOT/crash-act"
when "$H" arm crash --interval 0.1 --stable 1 \
  --condition true \
  --action "$ACT" "$CRASHLOG" >/dev/null
# Simulate a runner that claimed the fire and died before capturing an outcome.
date +%s > "$H/state/when/when-crash.fired"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-crash || fail "no outcome was captured after the simulated crash"
RESULT=$(first_result "$H" when-crash)
assert_grep 'status: ambiguous' "$RESULT" "the outcome reports the uncaptured earlier fire"
assert_absent "$CRASHLOG" "the action was not fired a second time"
assert_contains "$(when "$H" classify "$RESULT")" ambiguous "classify reads the ambiguity"
when "$H" terminal "$RESULT" || fail "an ambiguous outcome must be terminal"
pass "a restart after a claimed fire reports ambiguity instead of double-firing"

# --- a mutated spec is refused without executing anything ---------------------
H="$TMP_ROOT/h-tamper"; new_home "$H"
TAMPERLOG="$TMP_ROOT/tamper-act"
when "$H" arm tamper --interval 0.1 --stable 1 \
  --condition "$COND" "$TMP_ROOT/tamper-trigger" "$TMP_ROOT/tamper-count" \
  --action "$ACT" "$TAMPERLOG" >/dev/null
# Mutate the registered spec after arming: swap the action for a different one.
perl -pi -e "s/\Qtamper-act\E/tamper-EVIL/" "$H/state/when/when-tamper.spec"
: > "$TMP_ROOT/tamper-trigger"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-tamper || fail "no outcome was captured for the mutated spec"
RESULT=$(first_result "$H" when-tamper)
assert_grep 'status: rejected' "$RESULT" "the outcome reports the trust refusal"
assert_grep 'trust' "$RESULT" "the refusal names the trust binding"
assert_absent "$TAMPERLOG" "nothing from the original spec was executed"
assert_absent "$TMP_ROOT/tamper-count" "nothing from the mutated spec was executed either"
assert_contains "$(when "$H" classify "$RESULT")" rejected "classify reads the refusal"
pass "a mutated spec is refused without executing anything"

# --- interpreter command forms are refused before registration ---------------
H="$TMP_ROOT/h-interpreter"; new_home "$H"
INTERPRETED="$TMP_ROOT/interpreted.sh"
cat > "$INTERPRETED" <<'SH'
#!/bin/bash
printf 'interpreter script ran\n' >> "$1"
SH
if when "$H" arm interpreter-condition --condition /bin/sh "$INTERPRETED" --action "$ACT" "$TMP_ROOT/interpreter-condition-act" \
  >"$TMP_ROOT/interpreter-condition.out" 2>"$TMP_ROOT/interpreter-condition.err"; then
  fail "an interpreter condition command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-condition.err" \
  "the condition refusal explains the safe invocation form"
assert_absent "$H/state/procevent/when-interpreter-condition.source" \
  "a refused condition command form is never registered"
if when "$H" arm interpreter-action --condition true --action /bin/sh "$INTERPRETED" "$TMP_ROOT/interpreter-action-act" \
  >"$TMP_ROOT/interpreter-action.out" 2>"$TMP_ROOT/interpreter-action.err"; then
  fail "an interpreter action command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-action.err" \
  "the action refusal explains the safe invocation form"
assert_absent "$H/state/procevent/when-interpreter-action.source" \
  "a refused action command form is never registered"
INTERPRETER_LINK="$TMP_ROOT/approved-runner"
ln -s /bin/sh "$INTERPRETER_LINK"
if when "$H" arm interpreter-symlink --condition true --action "$INTERPRETER_LINK" "$INTERPRETED" "$TMP_ROOT/interpreter-symlink-act" \
  >"$TMP_ROOT/interpreter-symlink.out" 2>"$TMP_ROOT/interpreter-symlink.err"; then
  fail "a symlink to an interpreter command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-symlink.err" \
  "the symlink target is classified as an interpreter"
assert_absent "$H/state/procevent/when-interpreter-symlink.source" \
  "an interpreter symlink command form is never registered"
INTERPRETER_COPY="$TMP_ROOT/approved-runner-copy"
cp /bin/sh "$INTERPRETER_COPY"
chmod +x "$INTERPRETER_COPY"
if when "$H" arm interpreter-copy --condition true --action "$INTERPRETER_COPY" "$INTERPRETED" "$TMP_ROOT/interpreter-copy-act" \
  >"$TMP_ROOT/interpreter-copy.out" 2>"$TMP_ROOT/interpreter-copy.err"; then
  fail "a renamed interpreter command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-copy.err" \
  "the copied interpreter is classified by its executable identity"
assert_absent "$H/state/procevent/when-interpreter-copy.source" \
  "a copied interpreter command form is never registered"
INTERPRETER_AWK_COPY="$TMP_ROOT/approved-runner-awk-copy"
INTERPRETED_AWK="$TMP_ROOT/interpreted.awk"
printf 'BEGIN { exit 0 }\n' > "$INTERPRETED_AWK"
cp "$(type -P awk)" "$INTERPRETER_AWK_COPY"
chmod +x "$INTERPRETER_AWK_COPY"
if when "$H" arm interpreter-awk-copy --condition true --action "$INTERPRETER_AWK_COPY" -f "$INTERPRETED_AWK" \
  >"$TMP_ROOT/interpreter-awk-copy.out" 2>"$TMP_ROOT/interpreter-awk-copy.err"; then
  fail "a renamed non-shell interpreter command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-awk-copy.err" \
  "the copied non-shell interpreter is classified by its executable identity"
assert_absent "$H/state/procevent/when-interpreter-awk-copy.source" \
  "a copied non-shell interpreter command form is never registered"
MAKE_BIN_DIR="$TMP_ROOT/make-bin"
MAKEFILE="$TMP_ROOT/mutable.mk"
RENAMED_MAKE="$TMP_ROOT/approved-runner-make-copy"
mkdir -p "$MAKE_BIN_DIR"
cat > "$MAKE_BIN_DIR/make" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$MAKE_BIN_DIR/make"
printf 'all:\n\t@true\n' > "$MAKEFILE"
cp "$MAKE_BIN_DIR/make" "$RENAMED_MAKE"
chmod +x "$RENAMED_MAKE"
if PATH="$MAKE_BIN_DIR:$PATH" when "$H" arm interpreter-make-copy --condition true --action "$RENAMED_MAKE" -f "$MAKEFILE" \
  >"$TMP_ROOT/interpreter-make-copy.out" 2>"$TMP_ROOT/interpreter-make-copy.err"; then
  fail "a renamed make command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-make-copy.err" \
  "the copied make executable is classified by its executable identity"
assert_absent "$H/state/procevent/when-interpreter-make-copy.source" \
  "a copied make command form is never registered"
FIND_BIN=$(type -P find)
FIND_COPY="$TMP_ROOT/approved-runner-find-copy"
cp "$FIND_BIN" "$FIND_COPY"
chmod +x "$FIND_COPY"
if when "$H" arm interpreter-find-copy --condition true --action "$FIND_COPY" "$TMP_ROOT" -exec "$INTERPRETED" ';' \
  >"$TMP_ROOT/interpreter-find-copy.out" 2>"$TMP_ROOT/interpreter-find-copy.err"; then
  fail "a renamed find dispatcher command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-find-copy.err" \
  "the copied find dispatcher is classified by its executable identity"
assert_absent "$H/state/procevent/when-interpreter-find-copy.source" \
  "a copied find dispatcher command form is never registered"
GIT_BIN=$(type -P git)
GIT_COPY="$TMP_ROOT/approved-runner-git-copy"
cp "$GIT_BIN" "$GIT_COPY"
chmod +x "$GIT_COPY"
if when "$H" arm interpreter-git-copy --condition true --action "$GIT_COPY" -C "$TMP_ROOT/git-hook-repo" \
  -c "core.hooksPath=$TMP_ROOT/git-hooks" -c user.name=x -c user.email=x commit --allow-empty -m x \
  >"$TMP_ROOT/interpreter-git-copy.out" 2>"$TMP_ROOT/interpreter-git-copy.err"; then
  fail "a renamed git dispatcher command form must be refused"
fi
assert_grep 'interpreter command forms are not supported' "$TMP_ROOT/interpreter-git-copy.err" \
  "the copied git dispatcher is classified by its executable identity"
assert_absent "$H/state/procevent/when-interpreter-git-copy.source" \
  "a copied git dispatcher command form is never registered"
pass "interpreter command forms cannot register mutable scripts"

H="$TMP_ROOT/h-symlink-cycle"; new_home "$H"
CYCLE_A="$TMP_ROOT/cycle-a"
CYCLE_B="$TMP_ROOT/cycle-b"
ln -s "$CYCLE_B" "$CYCLE_A"
ln -s "$CYCLE_A" "$CYCLE_B"
FM_HOME="$H" "$ROOT/bin/fm-procevent-when.sh" arm symlink-cycle \
  --condition "$CYCLE_A" --action "$ACT" "$TMP_ROOT/symlink-cycle-act" \
  >"$TMP_ROOT/symlink-cycle.out" 2>"$TMP_ROOT/symlink-cycle.err" &
cycle_pid=$!
for _ in $(seq 1 20); do
  kill -0 "$cycle_pid" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$cycle_pid" 2>/dev/null; then
  kill -TERM "$cycle_pid" 2>/dev/null || true
  wait "$cycle_pid" 2>/dev/null || true
  fail "a cyclic command symlink must be rejected without hanging"
fi
wait "$cycle_pid" || cycle_rc=$?
[ "${cycle_rc:-0}" -ne 0 ] || fail "a cyclic command symlink must be refused"
assert_absent "$H/state/procevent/when-symlink-cycle.source" \
  "a cyclic command symlink is never registered"
pass "cyclic command symlinks are rejected within a fixed bound"

# --- a changed shebang interpreter is refused before the command runs --------
H="$TMP_ROOT/h-shebang-action"; new_home "$H"
SHEBANG_ACTION_RUNNER="$TMP_ROOT/shebang-action-runner"
SHEBANG_ACTION="$TMP_ROOT/shebang-action.sh"
SHEBANG_ACTION_LOG="$TMP_ROOT/shebang-action.log"
cp /bin/sh "$SHEBANG_ACTION_RUNNER"
printf '#!%s\nprintf "registered action ran\\n" >> "$1"\n' "$SHEBANG_ACTION_RUNNER" > "$SHEBANG_ACTION"
chmod +x "$SHEBANG_ACTION"
when "$H" arm shebang-action --stable 1 --condition true \
  --action "$SHEBANG_ACTION" "$SHEBANG_ACTION_LOG" >/dev/null
cat > "$SHEBANG_ACTION_RUNNER" <<SH
#!/bin/bash
printf 'mutated action interpreter ran\n' >> '$SHEBANG_ACTION_LOG'
exit 0
SH
chmod +x "$SHEBANG_ACTION_RUNNER"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-shebang-action || fail "no outcome was captured for the changed action interpreter"
RESULT=$(first_result "$H" when-shebang-action)
assert_grep 'status: rejected' "$RESULT" "a changed action interpreter is rejected"
assert_absent "$SHEBANG_ACTION_LOG" "the changed action interpreter was not executed"

H="$TMP_ROOT/h-shebang-condition"; new_home "$H"
SHEBANG_CONDITION_RUNNER="$TMP_ROOT/shebang-condition-runner"
SHEBANG_CONDITION="$TMP_ROOT/shebang-condition.sh"
SHEBANG_CONDITION_LOG="$TMP_ROOT/shebang-condition.log"
SHEBANG_CONDITION_ACTION="$TMP_ROOT/shebang-condition-action.log"
cp /bin/sh "$SHEBANG_CONDITION_RUNNER"
printf '#!%s\nprintf "registered condition ran\\n" >> "$1"\nexit 0\n' "$SHEBANG_CONDITION_RUNNER" > "$SHEBANG_CONDITION"
chmod +x "$SHEBANG_CONDITION"
when "$H" arm shebang-condition --stable 1 \
  --condition "$SHEBANG_CONDITION" "$SHEBANG_CONDITION_LOG" \
  --action "$ACT" "$SHEBANG_CONDITION_ACTION" >/dev/null
cat > "$SHEBANG_CONDITION_RUNNER" <<SH
#!/bin/bash
printf 'mutated condition interpreter ran\n' >> '$SHEBANG_CONDITION_LOG'
exit 0
SH
chmod +x "$SHEBANG_CONDITION_RUNNER"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-shebang-condition || fail "no outcome was captured for the changed condition interpreter"
RESULT=$(first_result "$H" when-shebang-condition)
assert_grep 'status: rejected' "$RESULT" "a changed condition interpreter is rejected"
assert_absent "$SHEBANG_CONDITION_LOG" "the changed condition interpreter was not executed"
assert_absent "$SHEBANG_CONDITION_ACTION" "a changed condition interpreter never reaches the action"
pass "changed shebang interpreters are refused before execution"

H="$TMP_ROOT/h-shebang-symlink"; new_home "$H"
SHEBANG_SYMLINK_RUNNER="$TMP_ROOT/shebang-symlink-runner"
SHEBANG_SYMLINK_ACTION="$TMP_ROOT/shebang-symlink-action.sh"
SHEBANG_SYMLINK_LOG="$TMP_ROOT/shebang-symlink.log"
ln -s /bin/sh "$SHEBANG_SYMLINK_RUNNER"
printf '#!%s\nprintf "registered symlink action ran\\n" >> "$1"\n' "$SHEBANG_SYMLINK_RUNNER" > "$SHEBANG_SYMLINK_ACTION"
chmod +x "$SHEBANG_SYMLINK_ACTION"
when "$H" arm shebang-symlink --stable 1 --condition true \
  --action "$SHEBANG_SYMLINK_ACTION" "$SHEBANG_SYMLINK_LOG" >/dev/null
ln -sfn /bin/false "$SHEBANG_SYMLINK_RUNNER"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-shebang-symlink || fail "no outcome was captured for the retargeted shebang symlink"
RESULT=$(first_result "$H" when-shebang-symlink)
assert_grep 'status: rejected' "$RESULT" "a retargeted shebang symlink is rejected"
assert_absent "$SHEBANG_SYMLINK_LOG" "the retargeted shebang symlink was not executed"
pass "retargeted shebang symlinks are refused before execution"

# --- mutated condition bytes are refused before the next poll ----------------
H="$TMP_ROOT/h-condition-tamper"; new_home "$H"
CONDITION_TAMPER_LOG="$TMP_ROOT/condition-tamper-act"
MUTABLE_COND="$TMP_ROOT/mutable-cond.sh"
cat > "$MUTABLE_COND" <<'SH'
#!/bin/bash
printf 'original condition ran\n' >> "$1"
exit 0
SH
chmod +x "$MUTABLE_COND"
when "$H" arm condition-tamper --stable 1 \
  --condition "$MUTABLE_COND" "$TMP_ROOT/condition-tamper-polls" \
  --action "$ACT" "$CONDITION_TAMPER_LOG" >/dev/null
cat > "$MUTABLE_COND" <<'SH'
#!/bin/bash
printf 'mutated condition ran\n' >> "$1"
exit 0
SH
chmod +x "$MUTABLE_COND"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-condition-tamper || fail "no outcome was captured for the mutated condition"
RESULT=$(first_result "$H" when-condition-tamper)
assert_grep 'status: rejected' "$RESULT" "the outcome reports the condition trust refusal"
assert_grep 'condition: its bytes do not match the registered trust binding' "$RESULT" \
  "the refusal identifies the condition binding"
assert_absent "$TMP_ROOT/condition-tamper-polls" "the mutated condition was not executed"
assert_absent "$CONDITION_TAMPER_LOG" "a rejected condition never reaches the action"
pass "mutated condition bytes are refused before polling"

# --- mutated action bytes are refused before the fire is claimed -------------
H="$TMP_ROOT/h-action-tamper"; new_home "$H"
ACTION_TAMPER_LOG="$TMP_ROOT/action-tamper-act"
MUTABLE_ACT="$TMP_ROOT/mutable-act.sh"
cat > "$MUTABLE_ACT" <<'SH'
#!/bin/bash
printf 'original action ran\n' >> "$1"
SH
chmod +x "$MUTABLE_ACT"
when "$H" arm action-tamper --stable 1 \
  --condition true --action "$MUTABLE_ACT" "$ACTION_TAMPER_LOG" >/dev/null
cat > "$MUTABLE_ACT" <<'SH'
#!/bin/bash
printf 'mutated action ran\n' >> "$1"
SH
chmod +x "$MUTABLE_ACT"
pe "$H" reconcile >/dev/null
wait_for_result "$H" when-action-tamper || fail "no outcome was captured for the mutated action"
RESULT=$(first_result "$H" when-action-tamper)
assert_grep 'status: rejected' "$RESULT" "the outcome reports the action trust refusal"
assert_grep 'trust binding' "$RESULT" "the refusal names the action trust binding"
assert_absent "$ACTION_TAMPER_LOG" "the mutated action was not executed"
assert_absent "$H/state/when/when-action-tamper.fired" "no fire was claimed for mutated action bytes"
pass "mutated action bytes are refused before claiming the fire"

printf 'all fm-procevent-when tests passed\n'
