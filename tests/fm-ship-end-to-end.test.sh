#!/usr/bin/env bash
# Behavior tests for the two-phase ship preflight record and private dashboard.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-ship-end-to-end.sh"
DASHBOARD="$ROOT/bin/fm-dashboard.sh"
TMP_ROOT=$(fm_test_tmproot fm-ship-end-to-end)

make_contract() {
  local path=$1 complete=${2:-false}
  printf '%s\n' '{"recommendation":"Build it","outcome":"A tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":[],"complete_plan_approved":'"$complete"'}' > "$path"
}

preflight_env() {
  local home=$1 now=${2:-100}
  shift 2
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_SHIP_PREFLIGHT_NOW="$now" "$PREFLIGHT" "$@"
}

test_direct_and_slack_preflight_authority() {
  local home="$TMP_ROOT/preflight" contract fp out status
  mkdir -p "$home/data" "$home/state"
  contract="$home/contract.json"
  make_contract "$contract"
  out=$(preflight_env "$home" 100 preflight direct-a1 --origin direct --contract "$contract") || fail "direct preflight should create a record"
  fp=${out#fingerprint=}
  assert_grep '"state": "awaiting_approval"' "$home/data/direct-a1/ship-preflight.json" "direct preflight did not await approval"
  out=$(preflight_env "$home" 101 verify direct-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unapproved preflight must refuse verification"
  assert_contains "$out" "approval is missing" "unapproved refusal was unclear"
  preflight_env "$home" 102 approve direct-a1 --fingerprint "$fp" --authority direct-captain --evidence 'captain approved' >/dev/null || fail "direct approval should work"
  preflight_env "$home" 103 verify direct-a1 --fingerprint "$fp" >/dev/null || fail "approved direct preflight should verify"
  out=$(preflight_env "$home" 103 approve direct-a1 --fingerprint "$fp" --authority trusted-slack-owner --evidence wrong 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct preflight must not accept Slack authority"
  assert_contains "$out" "not awaiting approval" "re-approval should not mutate an approved direct record"

  out=$(preflight_env "$home" 100 preflight slack-a1 --origin slack --contract "$contract" --authority direct-captain --evidence 'caller supplied' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Slack preflight must reject caller-supplied authority"
  assert_contains "$out" "caller-supplied authority" "Slack authority refusal was unclear"
  out=$(preflight_env "$home" 100 preflight slack-a1 --origin slack --contract "$contract") || fail "bridge-dispatched Slack preflight should create a record"
  fp=${out#fingerprint=}
  out=$(preflight_env "$home" 101 approve slack-a1 --fingerprint "$fp" --authority direct-captain --evidence 'message text' 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Slack approval must remain bridge-owned"
  assert_contains "$out" "Agent bridge dispatch" "Slack approval refusal was unclear"
  out=$(preflight_env "$home" 101 approve slack-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "Slack approval command must remain bridge-owned"
  assert_contains "$out" "Agent bridge dispatch" "Slack bridge-only refusal was unclear"
  preflight_env "$home" 102 verify slack-a1 --fingerprint "$fp" >/dev/null || fail "bridge-dispatched Slack preflight should verify"
  pass "typed direct and bridge-dispatched Slack preflights preserve approval authority"
}

test_grouped_questions_and_bounded_contract() {
  local home="$TMP_ROOT/grouped" contract="$TMP_ROOT/grouped-contract.json" out status
  mkdir -p "$home/data"
  printf '%s\n' '{"recommendation":"Build it","outcome":"A tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":["Choose A or B","Confirm rollout"]}' > "$contract"
  out=$(preflight_env "$home" 100 preflight grouped-a1 --origin direct --contract "$contract") || fail "grouped questions must be accepted in one contract"
  jq -e '.contract.questions == ["Choose A or B","Confirm rollout"] and .state == "awaiting_approval"' "$home/data/grouped-a1/ship-preflight.json" >/dev/null \
    || fail "preflight did not preserve grouped questions"
  printf '%040000d\n' 0 > "$contract"
  out=$(FM_SHIP_PREFLIGHT_MAX_CONTRACT_BYTES=8 preflight_env "$home" 101 preflight too-large-a1 --origin direct --contract "$contract" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "oversized contracts must fail closed"
  assert_contains "$out" "bounded preflight size" "oversized contract refusal was unclear"
  pass "preflight keeps one grouped question set and bounds input"
}

test_correction_bypass_and_stale_refusal() {
  local home="$TMP_ROOT/correction" contract changed fp out status
  mkdir -p "$home/data"
  contract="$home/contract.json"; changed="$home/changed.json"
  make_contract "$contract"
  out=$(preflight_env "$home" 100 preflight correction-a1 --origin direct --contract "$contract") || fail "preflight create failed"
  fp=${out#fingerprint=}
  make_contract "$changed"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Changed tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":[]}' > "$changed"
  out=$(preflight_env "$home" 101 correct correction-a1 --contract "$changed") || fail "correction should replace unapproved contract"
  fp2=${out#fingerprint=}
  [ "$fp" != "$fp2" ] || fail "correction should change the fingerprint"
  out=$(preflight_env "$home" 102 approve correction-a1 --fingerprint "$fp" --authority direct-captain --evidence approved 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched approval must refuse"
  preflight_env "$home" 102 approve correction-a1 --fingerprint "$fp2" --authority direct-captain --evidence approved >/dev/null || fail "current approval failed"
  out=$(FM_SHIP_PREFLIGHT_MAX_AGE=5 preflight_env "$home" 108 verify correction-a1 --fingerprint "$fp2" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "stale approval must refuse"
  assert_contains "$out" "stale" "stale refusal was unclear"

  make_contract "$contract" true
  out=$(preflight_env "$home" 200 preflight bypass-a1 --origin direct --contract "$contract" --approved-authority direct-captain --approval-evidence 'approved complete plan') || fail "approved complete plan should bypass duplicate preflight"
  preflight_env "$home" 201 verify bypass-a1 --fingerprint "${out#fingerprint=}" >/dev/null || fail "approved complete plan did not verify"
  pass "corrections, stale approvals, and approved complete plans fail closed"
}

test_preflight_rejects_tampering_and_future_approvals() {
  local home="$TMP_ROOT/tamper" contract="$TMP_ROOT/tamper-contract.json" out fp status
  mkdir -p "$home/data"
  make_contract "$contract"
  out=$(preflight_env "$home" 100 preflight tamper-a1 --origin direct --contract "$contract") || fail "tamper preflight create failed"
  fp=${out#fingerprint=}
  preflight_env "$home" 100 approve tamper-a1 --fingerprint "$fp" --authority direct-captain --evidence approved >/dev/null || fail "tamper approval failed"
  out=$(preflight_env "$home" 99 verify tamper-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "future approvals must refuse verification"
  assert_contains "$out" "in the future" "future approval refusal was unclear"
  jq '.contract.outcome = "changed after approval"' "$home/data/tamper-a1/ship-preflight.json" > "$home/tampered.json"
  chmod 600 "$home/tampered.json"
  mv "$home/tampered.json" "$home/data/tamper-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify tamper-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a record whose contract changed after approval must refuse"
  assert_contains "$out" "fingerprint does not match" "tampered contract refusal was unclear"
  pass "preflight verifies its approved contract and approval clock"
}

test_spawn_enforces_the_durable_preflight() {
  local home="$TMP_ROOT/spawn" project="$TMP_ROOT/spawn-project" contract="$TMP_ROOT/spawn-contract.json" out fp status
  mkdir -p "$home/data" "$home/state" "$home/config" "$project"
  make_contract "$contract"
  out=$(preflight_env "$home" 100 preflight spawn-a1 --origin direct --contract "$contract") || fail "spawn preflight create failed"
  fp=${out#fingerprint=}
  mkdir -p "$home/data/spawn-a1"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/spawn-a1/brief.md"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" spawn-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unapproved durable preflight must refuse spawn"
  assert_contains "$out" "preflight approval is missing" "spawn did not verify the durable preflight"
  assert_absent "$home/state/spawn-a1.meta" "preflight refusal wrote task metadata"
  pass "spawn verifies the durable preflight without a brief marker"
}

write_snapshot() {
  local file=$1 state=$2 decision=${3:-null} url=${4:-} source=${5:-pane} detail=${6:-} transition=${7:-null} checkpoint=${8:-null} recovery=${9:-'{"state":"none"}'} json
  json=$(printf '{"schema":"fm-fleet-snapshot.v1","tasks":[{"id":"dash-a1","kind":"ship","backlog":{"title":"Build dashboard"},"x_request":"r1","x_thread_url":"%s","current_state":{"state":"%s","source":"%s","detail":"%s","transition_at":%s,"active_seconds":%s},"recovery":%s,"hints":{"open_decisions":%s}}]}' "$url" "$state" "$source" "$detail" "$transition" "$checkpoint" "$recovery" "$decision")
  printf '%s\n' '#!/usr/bin/env bash' > "$file"
  printf "printf '%%s\\n' '%s'\n" "$json" >> "$file"
  chmod +x "$file"
}

test_dashboard_projection_and_active_time() {
  local home="$TMP_ROOT/dashboard" mock="$TMP_ROOT/dashboard-snapshot" record
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[]' 'https://slack.example/thread/1' pane '' 100 0
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "initial dashboard refresh failed"
  write_snapshot "$mock" working '[]' 'https://slack.example/thread/1' pane '' 120 10
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=130 "$DASHBOARD" refresh >/dev/null || fail "active dashboard refresh failed"
  write_snapshot "$mock" paused '[]' 'https://slack.example/thread/1' pane '' 132 22
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=140 "$DASHBOARD" refresh >/dev/null || fail "pause dashboard refresh failed"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=170 "$DASHBOARD" refresh >/dev/null || fail "continued pause dashboard refresh failed"
  jq -e '.technical.tasks[0].active_seconds == 22 and .technical.tasks[0].state_transition_at == 132' "$home/data/dashboard.json" >/dev/null || fail "dashboard must exclude a full paused interval between refreshes"
  write_snapshot "$mock" parked '[{"key":"ask","verb":"needs-decision","summary":"Choose"}]' 'https://slack.example/thread/1' pane '' 175 22
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=175 "$DASHBOARD" refresh >/dev/null || fail "decision dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '(.projection.needs_you | length) == 1 and .projection.needs_you[0].slack_thread_url == "https://slack.example/thread/1"' "$record" >/dev/null || fail "dashboard did not preserve the Slack decision link"
  write_snapshot "$mock" working '[]' 'https://slack.example/thread/1' pane '' 180 22
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=200 "$DASHBOARD" refresh >/dev/null || fail "resume dashboard refresh failed"
  record="$home/data/dashboard.json"
  [ "$(stat -c %a "$record")" = 600 ] || fail "dashboard record must be mode 0600"
  jq -e '.schema_version == 1 and .projection.in_progress[0].phase == "Building" and .projection.in_progress[0].active_seconds == 42 and (.projection.needs_you | length) == 0 and .projection.empty_text == "Nothing needs you."' "$record" >/dev/null || fail "dashboard projection or timing was wrong"
  find "$home/data" -maxdepth 1 -name '.dashboard.*' | grep -q . && fail "dashboard refresh left a non-atomic temporary file"
  pass "dashboard uses one private atomic projection with paused time excluded"
}

test_dashboard_filters_and_checking_phase() {
  local home="$TMP_ROOT/dashboard-filter" mock="$TMP_ROOT/dashboard-filter-snapshot" record
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[{"key":"d1","verb":"needs-decision","summary":"Choose"},{"key":"b1","verb":"blocked","summary":"Ignore duplicate"}]' '' run-step 'ci running'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "checking dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [{id:"dash-a1",name:"Build dashboard",phase:"Checking",active_seconds:0}] and .projection.needs_you == []' "$record" >/dev/null \
    || fail "dashboard must not duplicate a stale decision while checking"
  write_snapshot "$mock" parked '[{"key":"d1","verb":"needs-decision","summary":"Choose"},{"key":"b1","verb":"blocked","summary":"Ignore duplicate"}]' '' run-step 'parked at authority gate' 103 3
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=105 "$DASHBOARD" refresh >/dev/null || fail "decision dashboard refresh failed"
  jq -e '.projection.in_progress == [] and (.projection.needs_you | length) == 1 and .projection.needs_you[0].kind == "needs-decision" and .technical.tasks[0].active_seconds == 3' "$record" >/dev/null \
    || fail "dashboard must show one genuine decision"
  write_snapshot "$mock" unknown '[]' '' pane 'endpoint unavailable'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=110 "$DASHBOARD" refresh >/dev/null || fail "unknown dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [] and .technical.tasks[0].recovery == "automatic-recovery-pending"' "$record" >/dev/null \
    || fail "dashboard must keep recoverable endpoint loss out of Needs you"
  write_snapshot "$mock" failed '[]' '' run-step 'run failed'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=115 "$DASHBOARD" refresh >/dev/null || fail "failed dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [{id:"dash-a1",name:"Build dashboard",kind:"failed",summary:"Worker stopped",slack_thread_url:null}]' "$record" >/dev/null \
    || fail "dashboard must surface only unrecoverable stops after work ends: $(jq -c . "$record")"
  pass "dashboard maps checking work and filters duplicate or stale alerts"
}

test_dashboard_transition_ledger_tracks_canonical_edges() {
  local home="$TMP_ROOT/dashboard-ledger" state_file="$TMP_ROOT/dashboard-ledger-state" state_bin="$TMP_ROOT/dashboard-ledger-bin" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' > "$home/state/ledger-a1.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'IFS= read -r state < "$FM_DASHBOARD_TEST_STATE"' 'IFS= read -r timestamp < "$FM_DASHBOARD_TEST_TIMESTAMP"' 'printf "state: %s · source: run-step · transition_at: %s\\n" "$state" "$timestamp"' > "$state_bin"
  chmod +x "$state_bin"
  printf '%s\n' working > "$state_file"
  printf '%s\n' 100 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "initial run-state event failed"
  printf '%s\n' parked > "$state_file"
  printf '%s\n' 110 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "parked run-state event failed"
  printf '%s\n' working > "$state_file"
  printf '%s\n' 120 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "resumed run-state event failed"
  record="$home/state/dashboard-transitions/ledger-a1.json"
  jq -e '.schema_version == 1 and .state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "canonical transition ledger did not preserve the producer checkpoint"
  pass "run-state producer persists a compact canonical dashboard checkpoint"
}

test_dashboard_busy_events_preserve_hidden_transitions() {
  local home="$TMP_ROOT/dashboard-busy-events" fake_date gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-busy-bin"
  printf '%s\n' 'kind=ship' > "$home/state/busy-a1.meta"
  fake_date="$TMP_ROOT/dashboard-busy-bin/date"
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-busy-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" busy-a1) || fail "busy event arm failed"
  PATH="$TMP_ROOT/dashboard-busy-bin:$PATH" FM_FAKE_NOW=110 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-a1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "busy event pause failed"
  PATH="$TMP_ROOT/dashboard-busy-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-a1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "busy event resume failed"
  record="$home/state/dashboard-transitions/busy-a1.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "busy event producer did not preserve the hidden pause interval"
  pass "busy events persist exact active-time transitions"
}

test_dashboard_replays_spawn_busy_event_across_metadata_updates() {
  local home="$TMP_ROOT/dashboard-spawn-replay" fake_date gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-spawn-bin"
  fake_date="$TMP_ROOT/dashboard-spawn-bin/date"
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-spawn-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" replay-a1) || fail "pre-metadata busy event failed"
  [ ! -e "$home/state/dashboard-transitions/replay-a1.json" ] || fail "pre-metadata busy event must wait for task identity"
  printf '%s\n' 'kind=ship' 'dashboard_incarnation=i-replay-a1' > "$home/state/replay-a1.meta"
  "$ROOT/bin/fm-dashboard-transition.sh" replay-busy "$home/state" replay-a1 || fail "spawn replay failed"
  printf '%s\n' 'x_thread_url=https://slack.example/thread/1' >> "$home/state/replay-a1.meta"
  PATH="$TMP_ROOT/dashboard-spawn-bin:$PATH" FM_FAKE_NOW=110 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" replay-a1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "post-metadata pause failed"
  record="$home/state/dashboard-transitions/replay-a1.json"
  jq -e '.incarnation == "i-replay-a1" and .state == "parked" and .active_seconds == 10' "$record" >/dev/null \
    || fail "metadata update reset accumulated active time"
  pass "spawn replay preserves active time across metadata updates"
}

test_dashboard_recovery_surfaces_only_exhausted_loss() {
  local home="$TMP_ROOT/dashboard-recovery" state_bin="$TMP_ROOT/dashboard-recovery-state" agent_bin="$TMP_ROOT/dashboard-recovery-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-spawn" mock="$TMP_ROOT/dashboard-recovery-snapshot" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-a1.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' '[ "$2" = --recover-missing ] || exit 2' 'printf "replacement refused\\n" >&2' 'exit 1' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a1 || fail "first automatic recovery attempt failed"
  jq -e '.state == "pending" and .attempts == 1' "$home/state/dashboard-recovery/dash-a1.json" >/dev/null || fail "first recovery failure must remain recoverable"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a1 || fail "exhausted recovery attempt failed"
  record="$home/state/dashboard-recovery/dash-a1.json"
  jq -e '.state == "unrecoverable" and .attempts == 2' "$record" >/dev/null || fail "recovery owner did not persist exhaustion"
  write_snapshot "$mock" unknown '[]' '' pane 'endpoint unavailable' null null '{"state":"unrecoverable"}'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=120 "$DASHBOARD" refresh >/dev/null || fail "unrecoverable dashboard refresh failed"
  jq -e '.projection.needs_you == [{id:"dash-a1",name:"Build dashboard",kind:"failed",summary:"Worker recovery failed",slack_thread_url:null}] and .technical.tasks[0].recovery == "unrecoverable"' "$home/data/dashboard.json" >/dev/null \
    || fail "dashboard did not surface an exhausted worker recovery"
  pass "dashboard surfaces only exhausted worker recovery"
}

test_dashboard_recovery_surfaces_unsupported_replacement() {
  local home="$TMP_ROOT/dashboard-recovery-unsupported" state_bin="$TMP_ROOT/dashboard-recovery-unsupported-state" agent_bin="$TMP_ROOT/dashboard-recovery-unsupported-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-unsupported-spawn" mock="$TMP_ROOT/dashboard-recovery-unsupported-snapshot" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=zellij' 'window=main:worker' > "$home/state/dash-a2.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "replacement unavailable\\n" >&2' 'exit 3' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a2 || fail "unsupported recovery record failed"
  record="$home/state/dashboard-recovery/dash-a2.json"
  jq -e '.state == "unrecoverable" and .attempts == 0 and .reason == "replacement unavailable"' "$record" >/dev/null \
    || fail "unsupported recovery did not become terminal"
  write_snapshot "$mock" unknown '[]' '' pane 'endpoint unavailable' null null '{"state":"unrecoverable"}'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=120 "$DASHBOARD" refresh >/dev/null || fail "unsupported dashboard refresh failed"
  jq -e '.projection.needs_you == [{id:"dash-a1",name:"Build dashboard",kind:"failed",summary:"Worker recovery failed",slack_thread_url:null}]' "$home/data/dashboard.json" >/dev/null \
    || fail "dashboard did not surface unsupported recovery"
  pass "dashboard surfaces unsupported worker replacement"
}

test_dashboard_recovery_excludes_endpoint_outage() {
  local home="$TMP_ROOT/dashboard-recovery-timing" state_bin="$TMP_ROOT/dashboard-recovery-timing-state" agent_bin="$TMP_ROOT/dashboard-recovery-timing-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-timing-spawn" fake_date="$TMP_ROOT/dashboard-recovery-timing-bin/date" gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-recovery-timing-bin"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' 'dashboard_incarnation=i-recovery-timing' > "$home/state/dash-a3.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$spawn_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin" "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-recovery-timing-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" dash-a3) || fail "initial busy event failed"
  PATH="$TMP_ROOT/dashboard-recovery-timing-bin:$PATH" FM_FAKE_NOW=110 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a3 || fail "recovery confirmation failed"
  PATH="$TMP_ROOT/dashboard-recovery-timing-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" dash-a3 >/dev/null || fail "replacement busy event failed"
  record="$home/state/dashboard-transitions/dash-a3.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "endpoint outage was counted as active time"
  pass "dashboard excludes confirmed endpoint outage time"
}

test_dashboard_keeps_only_active_tasks() {
  local home="$TMP_ROOT/dashboard-active" mock="$TMP_ROOT/dashboard-active-snapshot" record
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[]'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "active dashboard refresh failed"
  write_snapshot "$mock" done '[]'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=110 "$DASHBOARD" refresh >/dev/null || fail "completed dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [] and .technical.tasks == []' "$record" >/dev/null \
    || fail "dashboard must not retain completed tasks as active work"
  pass "dashboard retains only active task records"
}

test_preflight_is_private_and_does_not_touch_lifecycle() {
  local home="$TMP_ROOT/private" contract="$TMP_ROOT/private-contract.json" out
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  out=$(preflight_env "$home" 100 preflight private-a1 --origin direct --contract "$contract") || fail "private preflight create failed"
  [ -f "$home/data/private-a1/ship-preflight.json" ] || fail "preflight did not write its private record"
  [ ! -e "$home/state/private-a1.meta" ] || fail "preflight must not create a worker lifecycle record"
  [ ! -e "$home/projects" ] || fail "preflight must not create or modify a project copy"
  jq -e '.state == "awaiting_approval" and .origin == "direct"' "$home/data/private-a1/ship-preflight.json" >/dev/null \
    || fail "private preflight record did not preserve its approval boundary"
  pass "preflight remains private and separate from worker and production lifecycle"
}

test_dashboard_rejects_unsafe_or_oversized_inputs() {
  local home="$TMP_ROOT/dashboard-safety" mock="$TMP_ROOT/dashboard-safety-snapshot" record out status
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[]'
  record="$home/data/dashboard.json"
  printf '%s\n' '{"schema_version":1,"technical":{"tasks":[]}}' > "$record"
  chmod 644 "$record"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must reject an unsafe existing record"
  assert_contains "$out" "existing dashboard record is unsafe" "unsafe record refusal was unclear"
  chmod 600 "$record"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_MAX_SNAPSHOT_BYTES=8 FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must bound its canonical snapshot input"
  assert_contains "$out" "snapshot exceeds the bounded size" "bounded snapshot refusal was unclear"
  pass "dashboard rejects unsafe records and bounds canonical input"
}

test_direct_and_slack_preflight_authority
test_grouped_questions_and_bounded_contract
test_correction_bypass_and_stale_refusal
test_preflight_rejects_tampering_and_future_approvals
test_spawn_enforces_the_durable_preflight
test_dashboard_projection_and_active_time
test_dashboard_filters_and_checking_phase
test_dashboard_transition_ledger_tracks_canonical_edges
test_dashboard_busy_events_preserve_hidden_transitions
test_dashboard_replays_spawn_busy_event_across_metadata_updates
test_dashboard_recovery_surfaces_only_exhausted_loss
test_dashboard_recovery_surfaces_unsupported_replacement
test_dashboard_recovery_excludes_endpoint_outage
test_dashboard_keeps_only_active_tasks
test_preflight_is_private_and_does_not_touch_lifecycle
test_dashboard_rejects_unsafe_or_oversized_inputs
echo "# all fm-ship-end-to-end tests passed"
