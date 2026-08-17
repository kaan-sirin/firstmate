#!/usr/bin/env bash
# Behavior tests for the two-phase ship preflight record and private dashboard.
set -u
umask 022

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PREFLIGHT="$ROOT/bin/fm-ship-end-to-end.sh"
BRIDGE="$ROOT/bin/fm-agent-bridge-ship-preflight.sh"
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

bridge_env() {
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$BRIDGE" "$@"
}

write_bridge_handoff() {
  local home=$1 id=$2 contract=$3 origin=$4 state=$5 now=$6 contract_json bound fp handoff tmp bypass
  chmod 755 "$home/data"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  mkdir -p "${handoff%/*}"
  chmod 700 "$home/state/agent-bridge" "${handoff%/*}"
  contract_json=$(jq -cS . "$contract") || fail "could not canonicalize bridge contract"
  bound=$(jq -cn --arg id "$id" --argjson contract "$contract_json" '{task_id:$id,contract:$contract}' | jq -cS .) || fail "could not bind bridge preflight"
  if command -v sha256sum >/dev/null 2>&1; then
    fp=$(printf '%s' "$bound" | sha256sum | awk '{print $1}')
  else
    fp=$(printf '%s' "$bound" | shasum -a 256 | awk '{print $1}')
  fi
  bypass=$(jq -c '.complete_plan_approved == true' "$contract") || fail "could not read bypass state"
  tmp=$(umask 077; mktemp "${handoff%/*}/.ship-preflight.XXXXXX") || fail "could not prepare bridge record"
  jq -n --arg id "$id" --argjson contract "$contract_json" --arg fp "$fp" --arg origin "$origin" --arg state "$state" --argjson now "$now" --argjson bypass "$bypass" '
    {schema_version:1,workflow:"ship-end-to-end",task_id:$id,fingerprint:$fp,origin:$origin,state:$state,contract:$contract}
    + (if $state == "approved" then {approval:{authority:(if $origin == "bridge" then "agent-bridge" else "direct-captain" end),evidence:"bridge-submission",approved_at:$now,complete_plan_bypass:$bypass}} else {created_at:$now} end)
  ' > "$tmp" || { rm -f -- "$tmp"; fail "could not write bridge record"; }
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$handoff"; then
    rm -f -- "$tmp"
    fail "could not prepare bridge handoff"
  fi
  printf '%s' "$fp"
}

publish_preflight_record() {
  local home=$1 id=$2 contract=$3 origin=$4 state=$5 now=$6 fp
  fp=$(write_bridge_handoff "$home" "$id" "$contract" "$origin" "$state" "$now") || return 1
  bridge_env "$home" publish "$id" >/dev/null || fail "could not publish bridge record"
  printf '%s' "$fp"
}

test_direct_and_bridge_owned_preflight_authority() {
  local home="$TMP_ROOT/preflight" contract fp out status
  mkdir -p "$home/data" "$home/state"
  contract="$home/contract.json"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" direct-a1 "$contract" direct awaiting_approval 100) || fail "direct preflight should create a record"
  assert_grep '"state": "awaiting_approval"' "$home/data/direct-a1/ship-preflight.json" "direct preflight did not await approval"
  out=$(preflight_env "$home" 101 verify direct-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unapproved preflight must refuse verification"
  assert_contains "$out" "approval is missing" "unapproved refusal was unclear"
  fp=$(publish_preflight_record "$home" direct-a1 "$contract" direct approved 102) || fail "direct approval should work"
  preflight_env "$home" 103 verify direct-a1 --fingerprint "$fp" >/dev/null || fail "approved direct preflight should verify"
  out=$(preflight_env "$home" 103 preflight direct-a1 --contract "$contract" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "direct preflight must reject caller-supplied contract"
  assert_contains "$out" "Usage:" "caller-supplied contract refusal was unclear"

  out=$(preflight_env "$home" 100 preflight slack-a1 --origin slack --contract "$contract" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "public Slack preflight must refuse caller-supplied claims"
  assert_contains "$out" "Usage:" "public Slack preflight refusal was unclear"
  assert_absent "$home/data/slack-a1/ship-preflight.json" "public Slack preflight wrote an approval record"

  fp=$(publish_preflight_record "$home" slack-a1 "$contract" bridge approved 100) || fail "could not prepare bridge-owned preflight"
  preflight_env "$home" 102 verify slack-a1 --fingerprint "$fp" >/dev/null || fail "bridge-owned Slack preflight should verify"

  mkdir -p "$home/state/ship-preflight-submissions"
  printf '%s\n' '{}' > "$home/state/ship-preflight-submissions/generic-a1.json"
  chmod 600 "$home/state/ship-preflight-submissions/generic-a1.json"
  out=$(bridge_env "$home" publish generic-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a generic submission path published a preflight"
  assert_contains "$out" "no valid private bridge handoff" "generic submission refusal was unclear"
  assert_absent "$home/data/generic-a1/ship-preflight.json" "generic submission wrote an approval record"
  pass "typed direct and bridge-owned Slack preflights preserve approval authority"
}

test_preflight_requires_typed_authority_evidence() {
  local home="$TMP_ROOT/preflight-authority" contract="$TMP_ROOT/preflight-authority-contract.json" fp out status record tmp
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" authority-a1 "$contract" bridge approved 100) || fail "could not publish approved bridge preflight"
  record="$home/data/authority-a1/ship-preflight.json"
  tmp=$(mktemp "$home/data/authority-a1/.approval.XXXXXX") || fail "could not prepare malformed approval"
  if ! jq 'del(.approval.authority)' "$record" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    fail "could not remove approval authority"
  fi
  chmod 600 "$record"
  out=$(preflight_env "$home" 101 verify authority-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "approval without typed authority must be refused"
  assert_contains "$out" "typed approval authority evidence" "missing authority refusal was unclear"

  fp=$(publish_preflight_record "$home" evidence-a1 "$contract" direct approved 100) || fail "could not publish approved direct preflight"
  record="$home/data/evidence-a1/ship-preflight.json"
  tmp=$(mktemp "$home/data/evidence-a1/.approval.XXXXXX") || fail "could not prepare malformed evidence"
  if ! jq '.approval.evidence = "unverified"' "$record" > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    fail "could not alter approval evidence"
  fi
  chmod 600 "$record"
  out=$(preflight_env "$home" 101 verify evidence-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "approval without typed evidence must be refused"
  assert_contains "$out" "typed approval authority evidence" "missing evidence refusal was unclear"
  pass "preflight requires typed authority and bridge evidence"
}

test_grouped_questions_and_bounded_contract() {
  local home="$TMP_ROOT/grouped" contract="$TMP_ROOT/grouped-contract.json" out status
  mkdir -p "$home/data"
  printf '%s\n' '{"recommendation":"Build it","outcome":"A tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":["Choose A or B","Confirm rollout"]}' > "$contract"
  publish_preflight_record "$home" grouped-a1 "$contract" direct awaiting_approval 100 >/dev/null || fail "grouped questions must be accepted in one contract"
  jq -e '.contract.questions == ["Choose A or B","Confirm rollout"] and .state == "awaiting_approval"' "$home/data/grouped-a1/ship-preflight.json" >/dev/null \
    || fail "preflight did not preserve grouped questions"
  pass "preflight keeps one grouped question set"
}

test_correction_bypass_and_stale_refusal() {
  local home="$TMP_ROOT/correction" contract changed fp out status
  mkdir -p "$home/data"
  contract="$home/contract.json"; changed="$home/changed.json"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" correction-a1 "$contract" direct awaiting_approval 100) || fail "preflight create failed"
  make_contract "$changed"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Changed tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":[]}' > "$changed"
  fp2=$(publish_preflight_record "$home" correction-a1 "$changed" direct awaiting_approval 101) || fail "correction should replace unapproved contract"
  [ "$fp" != "$fp2" ] || fail "correction should change the fingerprint"
  fp2=$(publish_preflight_record "$home" correction-a1 "$changed" direct approved 102) || fail "current approval failed"
  out=$(preflight_env "$home" 102 verify correction-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "mismatched approval must refuse"
  out=$(FM_SHIP_PREFLIGHT_MAX_AGE=5 preflight_env "$home" 108 verify correction-a1 --fingerprint "$fp2" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "stale approval must refuse"
  assert_contains "$out" "stale" "stale refusal was unclear"
  FM_SHIP_PREFLIGHT_MAX_AGE=5 preflight_env "$home" 108 verify-dispatched correction-a1 --fingerprint "$fp2" >/dev/null \
    || fail "an approved dispatched task must resume after its approval ages"
  out=$(preflight_env "$home" 108 verify-recovery correction-a1 --fingerprint "$fp" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "recovery must refuse a replaced approved contract"
  assert_contains "$out" "fingerprint does not match" "recovery did not preserve its original contract binding"
  preflight_env "$home" 108 verify-recovery correction-a1 --fingerprint "$fp2" >/dev/null \
    || fail "recovery must accept its original approved contract"

  make_contract "$contract" true
  fp=$(publish_preflight_record "$home" bypass-a1 "$contract" direct approved 200) || fail "approved complete plan should bypass duplicate preflight"
  preflight_env "$home" 201 verify bypass-a1 --fingerprint "$fp" >/dev/null || fail "approved complete plan did not verify"
  pass "corrections, stale approvals, and approved complete plans fail closed"
}

test_preflight_rejects_tampering_and_future_approvals() {
  local home="$TMP_ROOT/tamper" contract="$TMP_ROOT/tamper-contract.json" out fp status
  mkdir -p "$home/data"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" tamper-a1 "$contract" direct approved 100) || fail "tamper preflight create failed"
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

test_preflight_rejects_cross_task_records() {
  local home="$TMP_ROOT/cross-task" contract="$TMP_ROOT/cross-task-contract.json" out fp status
  mkdir -p "$home/data"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" approved-a1 "$contract" direct approved 100) || fail "cross-task preflight approval failed"
  chmod 733 "$home/data"
  out=$(preflight_env "$home" 101 verify-current approved-a1 2>&1)
  status=$?
  chmod 755 "$home/data"
  [ "$status" -ne 0 ] || fail "a preflight under a writable data directory must refuse"
  assert_contains "$out" "unsafe task record directory" "writable data directory refusal was unclear"

  chmod 733 "$home/data/approved-a1"
  out=$(preflight_env "$home" 101 verify-current approved-a1 2>&1)
  status=$?
  chmod 700 "$home/data/approved-a1"
  [ "$status" -ne 0 ] || fail "a preflight under a writable task directory must refuse"
  assert_contains "$out" "unsafe task record directory" "writable task directory refusal was unclear"

  ln -s "$home/data" "$home/linked-data"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/linked-data" FM_STATE_OVERRIDE="$home/state" FM_SHIP_PREFLIGHT_NOW=101 "$PREFLIGHT" verify-current approved-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a preflight under a linked data directory must refuse"
  assert_contains "$out" "unsafe task record directory" "linked data directory refusal was unclear"

  ln -s "$home/data/approved-a1" "$home/data/aliased-a1"
  out=$(preflight_env "$home" 101 verify-current aliased-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a task directory symlink reused another task's approved preflight"
  assert_contains "$out" "unsafe task record directory" "cross-task preflight refusal was unclear"

  mkdir -p "$home/data/copied-a1"
  chmod 700 "$home/data/copied-a1"
  cp "$home/data/approved-a1/ship-preflight.json" "$home/data/copied-a1/ship-preflight.json"
  chmod 600 "$home/data/copied-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify-current copied-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a copied preflight record authorized a different task"
  assert_contains "$out" "malformed preflight record" "copied preflight refusal was unclear"

  mkdir -p "$home/data/linked-a1"
  chmod 700 "$home/data/linked-a1"
  ln "$home/data/approved-a1/ship-preflight.json" "$home/data/linked-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify-current linked-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a hard-linked preflight record authorized a different task"
  assert_contains "$out" "no valid private preflight record" "hard-linked preflight refusal was unclear"

  mkdir -p "$home/data/empty-a1"
  chmod 700 "$home/data/empty-a1"
  jq -n --arg id empty-a1 \
    '{schema_version:1,workflow:"ship-end-to-end",task_id:$id,fingerprint:"0000000000000000000000000000000000000000000000000000000000000000",origin:"bridge",state:"approved",contract:{},approval:{authority:"agent-bridge",evidence:"bridge-submission",approved_at:100,complete_plan_bypass:false}}' > "$home/data/empty-a1/ship-preflight.json"
  chmod 600 "$home/data/empty-a1/ship-preflight.json"
  out=$(preflight_env "$home" 101 verify-current empty-a1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "an empty bridge contract authorized a task"
  assert_contains "$out" "malformed preflight contract" "empty bridge contract refusal was unclear"
  pass "preflight refuses cross-task records and empty bridge contracts"
}

test_bridge_preserves_handoff_when_record_directories_are_unsafe() {
  local home="$TMP_ROOT/bridge-unsafe-directories" contract="$TMP_ROOT/bridge-unsafe-directories-contract.json" out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"

  write_bridge_handoff "$home" data-unsafe-a1 "$contract" bridge approved 100 >/dev/null || fail "could not write data-directory handoff"
  chmod 733 "$home/data"
  out=$(bridge_env "$home" publish data-unsafe-a1 2>&1)
  status=$?
  chmod 755 "$home/data"
  [ "$status" -ne 0 ] || fail "bridge published through a writable data directory"
  assert_contains "$out" "unsafe task record directory" "unsafe data directory refusal was unclear"
  [ -f "$home/state/agent-bridge/ship-preflight/data-unsafe-a1.json" ] \
    || fail "unsafe data directory publication consumed its handoff"
  assert_absent "$home/data/data-unsafe-a1/ship-preflight.json" "unsafe data directory publication wrote a record"

  write_bridge_handoff "$home" task-unsafe-a1 "$contract" bridge approved 100 >/dev/null || fail "could not write task-directory handoff"
  mkdir "$home/data/task-unsafe-a1"
  chmod 733 "$home/data/task-unsafe-a1"
  out=$(bridge_env "$home" publish task-unsafe-a1 2>&1)
  status=$?
  chmod 700 "$home/data/task-unsafe-a1"
  [ "$status" -ne 0 ] || fail "bridge published through a writable task directory"
  assert_contains "$out" "unsafe task record directory" "unsafe task directory refusal was unclear"
  [ -f "$home/state/agent-bridge/ship-preflight/task-unsafe-a1.json" ] \
    || fail "unsafe task directory publication consumed its handoff"
  assert_absent "$home/data/task-unsafe-a1/ship-preflight.json" "unsafe task directory publication wrote a record"
  pass "bridge preserves handoffs when record directories are unsafe"
}

test_bridge_claims_a_handoff_before_reading_it() {
  local home="$TMP_ROOT/bridge-claim" id=claim-a1 original="$TMP_ROOT/bridge-claim-original.json" corrected="$TMP_ROOT/bridge-claim-corrected.json" handoff producer fakebin real_cat
  mkdir -p "$home/data" "$home/state"
  make_contract "$original"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"

  write_bridge_handoff "$home" "$id" "$corrected" direct awaiting_approval 101 >/dev/null || fail "could not prepare corrected producer handoff"
  producer=$(umask 077; mktemp "${handoff%/*}/.producer.XXXXXX") || fail "could not reserve corrected producer handoff"
  mv -f -- "$handoff" "$producer" || fail "could not stage corrected producer handoff"
  write_bridge_handoff "$home" "$id" "$original" direct approved 100 >/dev/null || fail "could not prepare original consumer handoff"

  fakebin="$TMP_ROOT/bridge-claim-bin"
  mkdir -p "$fakebin"
  real_cat=$(command -v cat)
  cat > "$fakebin/cat" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  "$FM_BRIDGE_RACE_DIR"/*) mv -f -- "$FM_BRIDGE_RACE_REPLACEMENT" "$FM_BRIDGE_RACE_HANDOFF" ;;
esac
exec "$FM_BRIDGE_REAL_CAT" "$@"
SH
  chmod +x "$fakebin/cat"
  PATH="$fakebin:$PATH" FM_BRIDGE_RACE_DIR="${handoff%/*}" FM_BRIDGE_RACE_REPLACEMENT="$producer" FM_BRIDGE_RACE_HANDOFF="$handoff" FM_BRIDGE_REAL_CAT="$real_cat" \
    bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not publish its claimed handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "bridge did not publish the handoff it claimed"
  jq -e '.state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$handoff" >/dev/null \
    || fail "bridge consumed a newer producer handoff"
  pass "bridge preserves a newer handoff published during record creation"
}

test_bridge_recovers_a_claim_after_interruption() {
  local home="$TMP_ROOT/bridge-claim-recovery" id=claim-recovery-a1 contract="$TMP_ROOT/bridge-claim-recovery-contract.json" handoff claim
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare interrupted bridge handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim.interrupted"
  mv -f -- "$handoff" "$claim" || fail "could not stage interrupted bridge claim"
  assert_absent "$home/data/$id/ship-preflight.json" "interruption published a preflight record"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover its interrupted claim"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "recovered bridge handoff did not publish its original record"
  assert_absent "$home/state/agent-bridge/ship-preflight/$id.json" "recovered bridge handoff remained pending"
  assert_absent "$claim" "recovered bridge claim remained stranded"
  pass "bridge recovers a claimed handoff after interruption"
}

test_bridge_restores_a_claim_interrupted_after_rename() {
  local home="$TMP_ROOT/bridge-rename-interruption" id=rename-interruption-a1 contract="$TMP_ROOT/bridge-rename-interruption-contract.json" handoff fakebin real_mv ready release target_pid publisher attempts status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare rename-interrupted bridge handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  fakebin="$TMP_ROOT/bridge-rename-interruption-bin"
  mkdir -p "$fakebin"
  real_mv=$(command -v mv)
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -eu
interrupt=0
for arg in "$@"; do
  [ "$arg" != "$FM_BRIDGE_INTERRUPT_HANDOFF" ] || interrupt=1
done
"$FM_BRIDGE_REAL_MV" "$@"
[ "$interrupt" -eq 0 ] || {
  printf '%s\n' "$PPID" > "$FM_BRIDGE_INTERRUPT_PID"
  : > "$FM_BRIDGE_INTERRUPT_READY"
  while [ ! -e "$FM_BRIDGE_INTERRUPT_RELEASE" ]; do sleep 0.01; done
}
SH
  chmod +x "$fakebin/mv"

  ready="$home/rename-ready"
  release="$home/rename-release"
  PATH="$fakebin:$PATH" FM_BRIDGE_INTERRUPT_HANDOFF="$handoff" FM_BRIDGE_REAL_MV="$real_mv" FM_BRIDGE_INTERRUPT_PID="$home/rename-pid" FM_BRIDGE_INTERRUPT_READY="$ready" FM_BRIDGE_INTERRUPT_RELEASE="$release" \
    bridge_env "$home" publish "$id" > "$home/rename-publish.out" 2>&1 &
  publisher=$!
  attempts=0
  while [ ! -e "$ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$ready" ]; then
    kill "$publisher" 2>/dev/null || true
    : > "$release"
    wait "$publisher" 2>/dev/null || true
    fail "rename interruption did not reach the claimed handoff"
  fi
  target_pid=$(cat "$home/rename-pid")
  kill -TERM "$target_pid" || fail "could not interrupt the claiming bridge process"
  : > "$release"
  wait "$publisher"
  status=$?
  [ "$status" -ne 0 ] || fail "rename interruption did not stop bridge publication"
  [ -f "$handoff" ] || fail "rename interruption lost the bridge handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$handoff" >/dev/null \
    || fail "rename interruption did not restore the original handoff"
  assert_absent "$home/data/$id/ship-preflight.json" "rename interruption published a preflight record"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not publish the restored rename-interrupted handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "restored rename-interrupted handoff did not publish"
  pass "bridge restores a claim interrupted after rename"
}

test_bridge_recovers_a_hard_linked_claim_after_interruption() {
  local home="$TMP_ROOT/bridge-hard-link-recovery" id=hard-link-recovery-a1 contract="$TMP_ROOT/bridge-hard-link-recovery-contract.json" handoff claim
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare hard-linked bridge handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  claim="${handoff%/*}/.${id}.claim.hard-link"
  ln "$handoff" "$claim" || fail "could not stage hard-linked interrupted claim"
  bridge_env "$home" publish "$id" >/dev/null || fail "bridge did not recover its hard-linked claim"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "hard-linked bridge claim did not publish its original record"
  assert_absent "$claim" "recovered hard-linked bridge claim remained stranded"
  assert_absent "$handoff" "recovered hard-linked bridge handoff remained pending"
  pass "bridge recovers a hard-linked claim after interruption"
}

test_bridge_serializes_concurrent_publish_claims() {
  local home="$TMP_ROOT/bridge-concurrent" id=concurrent-a1 contract="$TMP_ROOT/bridge-concurrent-contract.json" fakebin real_mktemp first second attempts first_status second_status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  write_bridge_handoff "$home" "$id" "$contract" direct approved 100 >/dev/null || fail "could not prepare concurrent bridge handoff"
  fakebin="$TMP_ROOT/bridge-concurrent-bin"
  mkdir -p "$fakebin"
  real_mktemp=$(command -v mktemp)
  cat > "$fakebin/mktemp" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  "$FM_BRIDGE_CONCURRENT_DIR"/.*.claim.*)
    if [ ! -e "$FM_BRIDGE_CONCURRENT_READY" ]; then
      : > "$FM_BRIDGE_CONCURRENT_READY"
      while [ ! -e "$FM_BRIDGE_CONCURRENT_RELEASE" ]; do sleep 0.01; done
    fi
    ;;
esac
exec "$FM_BRIDGE_REAL_MKTEMP" "$@"
SH
  chmod +x "$fakebin/mktemp"
  PATH="$fakebin:$PATH" FM_BRIDGE_CONCURRENT_DIR="$home/state/agent-bridge/ship-preflight" FM_BRIDGE_CONCURRENT_READY="$home/first-ready" FM_BRIDGE_CONCURRENT_RELEASE="$home/release-first" FM_BRIDGE_REAL_MKTEMP="$real_mktemp" \
    bridge_env "$home" publish "$id" > "$home/first.out" 2>&1 &
  first=$!
  attempts=0
  while [ ! -e "$home/first-ready" ] && [ "$attempts" -lt 100 ]; do
    sleep 0.01
    attempts=$((attempts + 1))
  done
  if [ ! -e "$home/first-ready" ]; then
    kill "$first" 2>/dev/null || true
    wait "$first" 2>/dev/null || true
    fail "first bridge publish did not hold its claim path"
  fi
  bridge_env "$home" publish "$id" > "$home/second.out" 2>&1 &
  second=$!
  sleep 0.1
  if ! kill -0 "$second" 2>/dev/null; then
    : > "$home/release-first"
    wait "$first" 2>/dev/null || true
    wait "$second" 2>/dev/null || true
    fail "second bridge publish bypassed the task lock"
  fi
  : > "$home/release-first"
  wait "$first"; first_status=$?
  wait "$second"; second_status=$?
  expect_code 0 "$first_status" "first bridge publish should complete"
  [ "$second_status" -ne 0 ] || fail "second bridge publish should refuse its consumed handoff"
  jq -e '.state == "approved" and .contract.outcome == "A tested PR"' "$home/data/$id/ship-preflight.json" >/dev/null \
    || fail "concurrent bridge publication corrupted the durable preflight"
  assert_absent "$home/state/agent-bridge/ship-preflight/$id.json" "concurrent bridge publication recreated an empty handoff"
  pass "bridge serializes concurrent publish claims without an empty handoff"
}

test_bridge_preserves_approved_record_on_invalid_handoff() {
  local home="$TMP_ROOT/bridge-invalid" id=invalid-bridge-a1 contract="$TMP_ROOT/bridge-invalid-contract.json" fp handoff out status
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" "$id" "$contract" bridge approved 100) || fail "could not publish approved baseline"
  write_bridge_handoff "$home" "$id" "$contract" bridge approved 101 >/dev/null || fail "could not prepare malformed handoff"
  handoff="$home/state/agent-bridge/ship-preflight/$id.json"
  jq 'del(.contract.outcome)' "$handoff" > "$home/malformed.json" || fail "could not corrupt handoff fixture"
  chmod 600 "$home/malformed.json" && mv -f "$home/malformed.json" "$handoff" || fail "could not publish malformed handoff fixture"
  out=$(bridge_env "$home" publish "$id" 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "malformed bridge handoff replaced an approved record"
  assert_contains "$out" "invalid typed private bridge handoff" "malformed handoff refusal was unclear"
  preflight_env "$home" 101 verify "$id" --fingerprint "$fp" >/dev/null || fail "malformed handoff changed the approved record"
  [ -f "$handoff" ] || fail "malformed handoff was not restored"
  pass "bridge preserves approved records when a handoff is malformed"
}

test_spawn_enforces_the_durable_preflight() {
  local home="$TMP_ROOT/spawn" project="$TMP_ROOT/spawn-project" contract="$TMP_ROOT/spawn-contract.json" corrected="$TMP_ROOT/spawn-corrected.json" racebin="$TMP_ROOT/spawn-race-bin" submitbin="$TMP_ROOT/spawn-submit-bin" submit_remote="$TMP_ROOT/spawn-submit-remote.git" submit_worktree="$TMP_ROOT/spawn-submit-worktree" submit_events="$TMP_ROOT/spawn-submit-events" submit_out="$TMP_ROOT/spawn-submit-publish.out" submit_status="$TMP_ROOT/spawn-submit-publish-status" submit_launch="$TMP_ROOT/spawn-submit-launch-literal" out fp status attempts submitted_line published_line
  mkdir -p "$home/data" "$home/state" "$home/config" "$project"
  make_contract "$contract"
  mkdir -p "$home/data/missing-a1"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/missing-a1/brief.md"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" missing-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a missing durable preflight must refuse spawn"
  assert_contains "$out" "preflight record for missing-a1 is missing" "missing preflight refusal was unclear"
  assert_absent "$home/state/missing-a1.meta" "missing preflight refusal wrote task metadata"
  fp=$(publish_preflight_record "$home" spawn-a1 "$contract" direct awaiting_approval 100) || fail "spawn preflight create failed"
  mkdir -p "$home/data/spawn-a1"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/spawn-a1/brief.md"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux "$ROOT/bin/fm-spawn.sh" spawn-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "unapproved durable preflight must refuse spawn"
  assert_contains "$out" "preflight approval is missing" "spawn did not verify the durable preflight"
  assert_absent "$home/state/spawn-a1.meta" "preflight refusal wrote task metadata"

  make_contract "$corrected"
  printf '%s\n' '{"recommendation":"Build it","outcome":"Corrected tested PR","scope":"One change","non_goals":"No deploy","delivery_boundary":"PR only","external_boundaries":"No production write","questions":[]}' > "$corrected"
  fp=$(publish_preflight_record "$home" race-a1 "$contract" direct approved 100) || fail "race preflight create failed"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/race-a1/brief.md"
  write_bridge_handoff "$home" race-a1 "$corrected" direct awaiting_approval 101 >/dev/null || fail "race correction handoff could not be prepared"
  mkdir -p "$racebin"
  cat > "$racebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_RACE_TMUX_LOG"
exit 1
SH
  chmod +x "$racebin/tmux"
  out=$(bridge_env "$home" publish race-a1 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "publisher-first correction did not finish"
  assert_contains "$out" "published" "publisher-first correction did not complete"
  out=$(PATH="$racebin:$PATH" FM_RACE_TMUX_LOG="$home/race-tmux.log" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_SHIP_PREFLIGHT_NOW=101 "$ROOT/bin/fm-spawn.sh" race-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "a corrected preflight must refuse spawn"
  assert_contains "$out" "preflight approval is missing" "corrected preflight refusal was unclear"
  jq -e '.state == "awaiting_approval" and .contract.outcome == "Corrected tested PR"' "$home/data/race-a1/ship-preflight.json" >/dev/null \
    || fail "publisher-first correction did not replace the preflight record"
  assert_absent "$home/state/race-a1.meta" "corrected preflight spawn wrote task metadata"
  [ ! -s "$home/race-tmux.log" ] || fail "corrected preflight created an endpoint"

  git init --bare -q "$submit_remote" || fail "could not create submit test remote"
  git -C "$project" init -q || fail "could not create submit test project"
  git -C "$project" config user.email test@example.invalid || fail "could not configure submit test author"
  git -C "$project" config user.name Test || fail "could not configure submit test author"
  printf '%s\n' 'submit test' > "$project/README.md"
  git -C "$project" add README.md || fail "could not stage submit test project"
  git -C "$project" commit -qm initial || fail "could not commit submit test project"
  git -C "$project" branch -M main || fail "could not name submit test branch"
  git -C "$project" remote add origin "$submit_remote" || fail "could not configure submit test remote"
  git -C "$project" push -qu origin main || fail "could not publish submit test base"
  git --git-dir="$submit_remote" symbolic-ref HEAD refs/heads/main || fail "could not set submit test default branch"
  git clone -q "$submit_remote" "$submit_worktree" || fail "could not create submit test worktree"
  fp=$(publish_preflight_record "$home" race-submit-a1 "$contract" direct approved 100) || fail "submit race preflight create failed"
  printf '%s\n' 'Delivery contract: mode=no-mistakes' > "$home/data/race-submit-a1/brief.md"
  write_bridge_handoff "$home" race-submit-a1 "$corrected" direct awaiting_approval 101 >/dev/null || fail "submit race correction handoff could not be prepared"
  mkdir -p "$submitbin"
  cat > "$submitbin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_RACE_TMUX_LOG"
case "$1" in
  new-window) printf '%s\n' '@1' ;;
  display-message)
    case "$*" in
      *'#{pane_current_path}'*) printf '%s\n' "$FM_RACE_WORKTREE" ;;
      *) printf '%s\n' '%1' ;;
    esac
    ;;
  send-keys)
    case " $* " in
      *" -l "*)
        : > "$FM_RACE_LAUNCH_LITERAL"
        (
          if "$FM_RACE_BRIDGE" publish "$FM_RACE_ID" > "$FM_RACE_PUBLISH_OUT" 2>&1; then
            printf '%s\n' published >> "$FM_RACE_EVENTS"
            printf '%s\n' 0 > "$FM_RACE_PUBLISH_STATUS"
          else
            printf '%s\n' publisher-failed >> "$FM_RACE_EVENTS"
            printf '%s\n' 1 > "$FM_RACE_PUBLISH_STATUS"
          fi
        ) &
        ;;
      *" Enter "*)
        [ ! -e "$FM_RACE_LAUNCH_LITERAL" ] || printf '%s\n' submitted >> "$FM_RACE_EVENTS"
        ;;
    esac
    ;;
esac
SH
  chmod +x "$submitbin/tmux"
  out=$(PATH="$submitbin:$PATH" FM_RACE_BRIDGE="$BRIDGE" FM_RACE_ID=race-submit-a1 FM_RACE_WORKTREE="$submit_worktree" FM_RACE_TMUX_LOG="$home/race-submit-tmux.log" FM_RACE_LAUNCH_LITERAL="$submit_launch" FM_RACE_EVENTS="$submit_events" FM_RACE_PUBLISH_OUT="$submit_out" FM_RACE_PUBLISH_STATUS="$submit_status" FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_SHIP_PREFLIGHT_NOW=101 "$ROOT/bin/fm-spawn.sh" race-submit-a1 "$project" --mode no-mistakes --yolo off --harness codex 2>&1)
  status=$?
  [ "$status" -eq 0 ] || fail "spawn-first correction did not dispatch"
  attempts=0
  while [ ! -e "$submit_status" ] && [ "$attempts" -lt 50 ]; do
    sleep 0.1
    attempts=$((attempts + 1))
  done
  [ "$(cat "$submit_status")" = 0 ] || fail "spawn-first correction did not finish"
  assert_contains "$(cat "$submit_out")" "published" "spawn-first correction did not complete"
  submitted_line=$(grep -n '^submitted$' "$submit_events" | head -n 1 | cut -d: -f1)
  published_line=$(grep -n '^published$' "$submit_events" | head -n 1 | cut -d: -f1)
  [ -n "$submitted_line" ] && [ -n "$published_line" ] && [ "$submitted_line" -lt "$published_line" ] \
    || fail "spawn-first correction published before launch submission"
  pass "spawn verifies the durable preflight without a brief marker"
}

write_snapshot() {
  local file=$1 state=$2 decision=${3:-null} url=${4:-} source=${5:-pane} detail=${6:-} transition=${7:-100} checkpoint=${8:-0} recovery=${9:-'{"state":"none"}'} json
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

test_dashboard_omits_uncheckpointed_active_work() {
  local home="$TMP_ROOT/dashboard-uncheckpointed" mock="$TMP_ROOT/dashboard-uncheckpointed-snapshot" record
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[]' '' pane 'harness busy (grok-regex)' null null
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=150 "$DASHBOARD" refresh >/dev/null || fail "uncheckpointed Grok dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [] and .technical.tasks[0].timing_exact == false and .technical.tasks[0].active_seconds == 0' "$record" >/dev/null \
    || fail "dashboard derived Grok active time without a producer checkpoint"
  write_snapshot "$mock" working '[]' '' pane 'harness busy (muse-session-log)' null null
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=200 "$DASHBOARD" refresh >/dev/null || fail "uncheckpointed Muse dashboard refresh failed"
  jq -e '.projection.in_progress == [] and .technical.tasks[0].timing_exact == false and .technical.tasks[0].active_seconds == 0' "$record" >/dev/null \
    || fail "dashboard derived Muse active time from refresh cadence"
  write_snapshot "$mock" working '[]' '' pane 'harness busy (muse-session-log)' 210 4
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=220 "$DASHBOARD" refresh >/dev/null || fail "checkpointed Muse dashboard refresh failed"
  jq -e '.projection.in_progress == [{id:"dash-a1",name:"Build dashboard",phase:"Building",active_seconds:14}] and .technical.tasks[0].timing_exact == true' "$record" >/dev/null \
    || fail "dashboard did not resume exact timing from the producer checkpoint"
  pass "dashboard omits active work until its producer provides exact timing"
}

test_dashboard_recovers_stale_publication_lock() {
  local home="$TMP_ROOT/dashboard-stale-lock" mock="$TMP_ROOT/dashboard-stale-lock-snapshot" lock record
  mkdir -p "$home/data" "$home/state"
  write_snapshot "$mock" working '[]' '' pane '' 100 0
  lock="$home/data/.dashboard.lock"
  mkdir "$lock"
  printf '%s\n' 999999 > "$lock/pid"
  touch -t 200001010000 "$lock"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh >/dev/null || fail "dashboard refresh did not recover its stale lock"
  record="$home/data/dashboard.json"
  jq -e '.schema_version == 1 and .projection.in_progress[0].id == "dash-a1"' "$record" >/dev/null || fail "dashboard did not publish after stale-lock recovery"
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail "dashboard left its recovered lock behind"
  pass "dashboard recovers stale publication locks"
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
  jq -e '.projection.in_progress == [] and .projection.needs_you == []' "$record" >/dev/null \
    || fail "dashboard must keep ordinary worker failures out of Needs you: $(jq -c . "$record")"
  pass "dashboard maps checking work and filters duplicate or stale alerts"
}

test_dashboard_transition_ledger_tracks_canonical_edges() {
  local home="$TMP_ROOT/dashboard-ledger" state_file="$TMP_ROOT/dashboard-ledger-state" state_bin="$TMP_ROOT/dashboard-ledger-bin" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' > "$home/state/ledger-a1.meta"
  # shellcheck disable=SC2016 # Variables expand in the generated state fixture.
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
  printf '%s\n' parked > "$state_file"
  printf '%s\n' '' > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "untimed parked run-state event failed"
  jq -e '.state == "parked" and .transition_at == null and .active_seconds == 10' "$record" >/dev/null \
    || fail "untimed run-state event did not invalidate the exact checkpoint"
  printf '%s\n' working > "$state_file"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "untimed resumed run-state event failed"
  jq -e '.state == "working" and .transition_at == null and .active_seconds == 10' "$record" >/dev/null \
    || fail "untimed resume revived a stale exact checkpoint"
  printf '%s\n' 140 > "$TMP_ROOT/dashboard-ledger-timestamp"
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" FM_DASHBOARD_RUN_STATE_BIN="$state_bin" FM_DASHBOARD_TEST_STATE="$state_file" FM_DASHBOARD_TEST_TIMESTAMP="$TMP_ROOT/dashboard-ledger-timestamp" "$ROOT/bin/fm-dashboard-run-state.sh" reconcile ledger-a1 \
    || fail "fresh exact run-state event failed"
  jq -e '.state == "working" and .transition_at == 140 and .active_seconds == 10' "$record" >/dev/null \
    || fail "fresh exact run-state event reused an invalidated checkpoint"
  pass "run-state producer persists a compact canonical dashboard checkpoint"
}

test_status_event_persists_transition_before_status() {
  local home="$TMP_ROOT/status-event" fake_date record terminal_record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/status-event-bin"
  printf '%s\n' 'kind=ship' > "$home/state/status-a1.meta"
  fake_date="$TMP_ROOT/status-event-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-status-event.sh" append "$home/state" status-a1 'working: implementation started' || fail "working status event failed"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=110 "$ROOT/bin/fm-status-event.sh" append "$home/state" status-a1 'needs-decision [key=implementation]: captain input required' || fail "decision status event failed"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-status-event.sh" resolve "$home/state" status-a1 'resolved [key=implementation]: captain answered' || fail "resolution status event failed"
  record="$home/state/dashboard-transitions/status-a1.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "status event did not persist canonical transition timing"
  [ "$(wc -l < "$home/state/status-a1.status")" -eq 3 ] || fail "status event did not append all status lines"
  printf '%s\n' 'kind=ship' > "$home/state/status-terminal-a1.meta"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=200 "$ROOT/bin/fm-status-event.sh" append "$home/state" status-terminal-a1 'done: implementation finished' || fail "terminal status event failed"
  PATH="$TMP_ROOT/status-event-bin:$PATH" FM_FAKE_NOW=210 "$ROOT/bin/fm-status-event.sh" resolve "$home/state" status-terminal-a1 'resolved [key=late]: captain answered' || fail "late resolution status event failed"
  terminal_record="$home/state/dashboard-transitions/status-terminal-a1.json"
  jq -e '.state == "done" and .transition_at == 200' "$terminal_record" >/dev/null \
    || fail "late resolution reactivated a terminal task"
  pass "status events persist canonical transitions with status output"
}

test_dashboard_busy_events_preserve_hidden_transitions() {
  local home="$TMP_ROOT/dashboard-busy-events" fake_date gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-busy-bin"
  printf '%s\n' 'kind=ship' > "$home/state/busy-a1.meta"
  fake_date="$TMP_ROOT/dashboard-busy-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
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

test_dashboard_busy_events_replay_interrupted_transitions() {
  local home="$TMP_ROOT/dashboard-busy-replay" fake_date gen record out status
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-busy-replay-bin"
  printf '%s\n' 'kind=ship' > "$home/state/busy-replay-a1.meta"
  fake_date="$TMP_ROOT/dashboard-busy-replay-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
  printf '%s\n' '#!/usr/bin/env bash' 'if [ "$1" = +%s ]; then printf "%s\\n" "$FM_FAKE_NOW"; else command date "$@"; fi' > "$fake_date"
  chmod +x "$fake_date"
  gen=$(PATH="$TMP_ROOT/dashboard-busy-replay-bin:$PATH" FM_FAKE_NOW=100 "$ROOT/bin/fm-busy-event.sh" arm "$home/state" busy-replay-a1) || fail "busy replay arm failed"
  out=$(PATH="$TMP_ROOT/dashboard-busy-replay-bin:$PATH" FM_FAKE_NOW=110 FM_BUSY_EVENT_TESTING=1 FM_BUSY_EVENT_TEST_INTERRUPT_AFTER_TRANSITION=1 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-replay-a1 idle --gen "$gen" --source claude-hook --event stop 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "interrupted busy transition unexpectedly completed"
  PATH="$TMP_ROOT/dashboard-busy-replay-bin:$PATH" FM_FAKE_NOW=120 "$ROOT/bin/fm-busy-event.sh" apply "$home/state" busy-replay-a1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "later busy event did not replay the interrupted pause"
  record="$home/state/dashboard-transitions/busy-replay-a1.json"
  jq -e '.state == "working" and .transition_at == 120 and .active_seconds == 10' "$record" >/dev/null \
    || fail "replayed busy transition included the interrupted pause"
  pass "busy events replay an interrupted transition before later writes"
}

test_dashboard_replays_spawn_busy_event_across_metadata_updates() {
  local home="$TMP_ROOT/dashboard-spawn-replay" fake_date gen record
  mkdir -p "$home/data" "$home/state" "$TMP_ROOT/dashboard-spawn-bin"
  fake_date="$TMP_ROOT/dashboard-spawn-bin/date"
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
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
  # shellcheck disable=SC2016 # Positional parameters expand in the generated spawn fixture.
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

test_dashboard_recovery_defers_preflight_approval() {
  local home="$TMP_ROOT/dashboard-recovery-preflight" state_bin="$TMP_ROOT/dashboard-recovery-preflight-state" agent_bin="$TMP_ROOT/dashboard-recovery-preflight-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-preflight-spawn" record contract fp
  mkdir -p "$home/data" "$home/state"
  contract="$home/contract.json"
  make_contract "$contract"
  fp=$(publish_preflight_record "$home" dash-preflight "$contract" direct awaiting_approval 100) || fail "could not prepare awaiting preflight"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' "preflight_fingerprint=$fp" > "$home/state/dash-preflight.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "fm-ship-end-to-end: preflight approval is missing\\n" >&2' 'exit 1' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-preflight || fail "initial preflight recovery attempt failed"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-preflight || fail "terminal preflight recovery attempt failed"
  record="$home/state/dashboard-recovery/dash-preflight.json"
  jq -e '.state == "unrecoverable" and .attempts == 2' "$record" >/dev/null || fail "legacy preflight recovery did not become terminal"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "ship preflight is awaiting approval\\n" >&2' 'exit 4' > "$spawn_bin"
  chmod +x "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-preflight || fail "awaiting approval recovery must defer"
  jq -e '.state == "pending" and .attempts == 0' "$record" >/dev/null || fail "awaiting approval consumed recovery attempts"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$spawn_bin"
  chmod +x "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-preflight || fail "approved correction did not resume recovery"
  [ ! -e "$record" ] || fail "approved correction left recovery terminal"
  pass "dashboard defers corrected preflight recovery without consuming attempts"
}

test_dashboard_recovery_relaunches_dead_endpoint() {
  local home="$TMP_ROOT/dashboard-recovery-dead" state_bin="$TMP_ROOT/dashboard-recovery-dead-state" agent_bin="$TMP_ROOT/dashboard-recovery-dead-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-dead-spawn"
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-dead.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: endpoint · confirmed endpoint loss\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  # shellcheck disable=SC2016 # Positional parameters expand in the generated spawn fixture.
  printf '%s\n' '#!/usr/bin/env bash' '[ "$2" = --relaunch ] && [ "$3" = --dashboard-recovery ] || exit 2' 'exit 0' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-dead \
    || fail "dead endpoint recovery did not relaunch"
  [ ! -e "$home/state/dashboard-recovery/dash-dead.json" ] || fail "successful dead-endpoint relaunch left a recovery failure"
  pass "dashboard relaunches a confirmed dead endpoint"
}

test_dashboard_recovery_defers_control_lock_contention() {
  local home="$TMP_ROOT/dashboard-recovery-contention" state_bin="$TMP_ROOT/dashboard-recovery-contention-state" agent_bin="$TMP_ROOT/dashboard-recovery-contention-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-contention-spawn" record
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-a4.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: unknown · source: none · endpoint gone\\n"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf missing' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "replacement refused\\n" >&2' 'exit 1' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a4 || fail "initial recovery attempt failed"
  record="$home/state/dashboard-recovery/dash-a4.json"
  jq -e '.state == "pending" and .attempts == 1' "$record" >/dev/null || fail "initial recovery failure must be recorded"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "another lifecycle action is already running\\n" >&2' 'exit 4' > "$spawn_bin"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS=2 "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-a4 || fail "contention recovery must defer"
  jq -e '.state == "pending" and .attempts == 1' "$record" >/dev/null || fail "control-lock contention must not exhaust recovery"
  pass "dashboard defers recovery while task control is busy"
}

test_dashboard_recovery_rechecks_eligibility_under_lock() {
  local home="$TMP_ROOT/dashboard-recovery-stale" state_bin="$TMP_ROOT/dashboard-recovery-stale-state" agent_bin="$TMP_ROOT/dashboard-recovery-stale-agent" spawn_bin="$TMP_ROOT/dashboard-recovery-stale-spawn" state_file="$TMP_ROOT/dashboard-recovery-stale-state-file" spawn_log="$TMP_ROOT/dashboard-recovery-stale-spawn-log" release="$TMP_ROOT/dashboard-recovery-stale-release" first second tries
  mkdir -p "$home/data" "$home/state"
  printf '%s\n' 'kind=ship' 'backend=tmux' 'window=main:worker' > "$home/state/dash-stale.meta"
  printf '%s\n' unknown > "$state_file"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "state: %s · source: endpoint\n" "$(cat "$FM_RECOVERY_STATE_FILE")"' > "$state_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf dead' > "$agent_bin"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "started\n" >> "$FM_RECOVERY_SPAWN_LOG"' 'while [ ! -e "$FM_RECOVERY_RELEASE" ]; do sleep 0.01; done' 'printf "working\n" > "$FM_RECOVERY_STATE_FILE"' > "$spawn_bin"
  chmod +x "$state_bin" "$agent_bin" "$spawn_bin"
  FM_RECOVERY_STATE_FILE="$state_file" FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_RECOVERY_RELEASE="$release" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-stale &
  first=$!
  tries=0
  while [ ! -s "$spawn_log" ] && [ "$tries" -lt 50 ]; do
    sleep 0.02
    tries=$((tries + 1))
  done
  [ -s "$spawn_log" ] || fail "first recovery did not submit a replacement"
  FM_RECOVERY_STATE_FILE="$state_file" FM_RECOVERY_SPAWN_LOG="$spawn_log" FM_RECOVERY_RELEASE="$release" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_RECOVERY_STATE_BIN="$state_bin" FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN="$agent_bin" FM_DASHBOARD_RECOVERY_SPAWN_BIN="$spawn_bin" "$ROOT/bin/fm-dashboard-recovery.sh" observe dash-stale &
  second=$!
  sleep 0.2
  : > "$release"
  wait "$first" || fail "first recovery did not finish"
  wait "$second" || fail "second recovery did not finish"
  [ "$(wc -l < "$spawn_log")" -eq 1 ] || fail "stale recovery eligibility submitted a duplicate replacement"
  pass "dashboard rechecks recovery eligibility after locking the task"
}

test_missing_recovery_control_lock_is_retryable() {
  local home="$TMP_ROOT/recovery-control-lock" out status lock
  mkdir -p "$home/data" "$home/state" "$home/config"
  lock="$home/state/.control-recovery-lock-a1.lock"
  mkdir "$lock"
  printf '%s\n' "$$" > "$lock/pid"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-spawn.sh" recovery-lock-a1 --recover-missing 2>&1)
  status=$?
  [ "$status" -eq 4 ] || fail "missing-endpoint control contention must return retry-later"
  assert_contains "$out" "another lifecycle action" "retry-later refusal was unclear"
  pass "missing-endpoint control contention is retryable"
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
  # shellcheck disable=SC2016 # Variables expand in the generated date fixture.
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
  write_snapshot "$mock" "done" '[]'
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=110 "$DASHBOARD" refresh >/dev/null || fail "completed dashboard refresh failed"
  record="$home/data/dashboard.json"
  jq -e '.projection.in_progress == [] and .projection.needs_you == [] and .technical.tasks == []' "$record" >/dev/null \
    || fail "dashboard must not retain completed tasks as active work"
  pass "dashboard retains only active task records"
}

test_preflight_is_private_and_does_not_touch_lifecycle() {
  local home="$TMP_ROOT/private" contract="$TMP_ROOT/private-contract.json"
  mkdir -p "$home/data" "$home/state"
  make_contract "$contract"
  publish_preflight_record "$home" private-a1 "$contract" direct awaiting_approval 100 >/dev/null || fail "private preflight create failed"
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
  chmod 733 "$home/data"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$DASHBOARD" show 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must reject a writable data directory when reading"
  assert_contains "$out" "unsafe data directory" "unsafe dashboard read refusal was unclear"
  out=$(FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" FM_DASHBOARD_TESTING=1 FM_DASHBOARD_TEST_SNAPSHOT_BIN="$mock" FM_DASHBOARD_NOW=100 "$DASHBOARD" refresh 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "dashboard must reject a writable data directory when publishing"
  assert_contains "$out" "unsafe data directory" "unsafe dashboard publication refusal was unclear"
  assert_absent "$record" "unsafe dashboard directory received a private record"
  chmod 755 "$home/data"
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

test_direct_and_bridge_owned_preflight_authority
test_preflight_requires_typed_authority_evidence
test_grouped_questions_and_bounded_contract
test_correction_bypass_and_stale_refusal
test_preflight_rejects_tampering_and_future_approvals
test_preflight_rejects_cross_task_records
test_bridge_preserves_handoff_when_record_directories_are_unsafe
test_bridge_claims_a_handoff_before_reading_it
test_bridge_recovers_a_claim_after_interruption
test_bridge_restores_a_claim_interrupted_after_rename
test_bridge_recovers_a_hard_linked_claim_after_interruption
test_bridge_serializes_concurrent_publish_claims
test_bridge_preserves_approved_record_on_invalid_handoff
test_spawn_enforces_the_durable_preflight
test_dashboard_projection_and_active_time
test_dashboard_omits_uncheckpointed_active_work
test_dashboard_recovers_stale_publication_lock
test_dashboard_filters_and_checking_phase
test_dashboard_transition_ledger_tracks_canonical_edges
test_status_event_persists_transition_before_status
test_dashboard_busy_events_preserve_hidden_transitions
test_dashboard_busy_events_replay_interrupted_transitions
test_dashboard_replays_spawn_busy_event_across_metadata_updates
test_dashboard_recovery_surfaces_only_exhausted_loss
test_dashboard_recovery_defers_preflight_approval
test_dashboard_recovery_relaunches_dead_endpoint
test_dashboard_recovery_defers_control_lock_contention
test_dashboard_recovery_rechecks_eligibility_under_lock
test_missing_recovery_control_lock_is_retryable
test_dashboard_recovery_surfaces_unsupported_replacement
test_dashboard_recovery_excludes_endpoint_outage
test_dashboard_keeps_only_active_tasks
test_preflight_is_private_and_does_not_touch_lifecycle
test_dashboard_rejects_unsafe_or_oversized_inputs
echo "# all fm-ship-end-to-end tests passed"
