#!/usr/bin/env bash
# Own the durable two-phase approval record for a material software ship task.
#
# Usage:
#   fm-ship-end-to-end.sh preflight <task-id> --origin direct --contract <json-file>
#   fm-ship-end-to-end.sh preflight <task-id> --origin direct --contract <json-file> --approved-authority direct-captain --approval-evidence <text>
#   fm-ship-end-to-end.sh bridge-dispatch <task-id> --request <request-id>
#   fm-ship-end-to-end.sh approve <task-id> --fingerprint <sha256> [--authority direct-captain --evidence <text>]
#   fm-ship-end-to-end.sh correct <task-id> --contract <json-file>
#   fm-ship-end-to-end.sh verify <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh verify-current <task-id>
#
# The record is data/<task-id>/ship-preflight.json, mode 0600. Its schema is
# `{schema_version,workflow,fingerprint,origin,state,contract,created_at|approval}`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
NOW=${FM_SHIP_PREFLIGHT_NOW:-$(date +%s)}
MAX_AGE=${FM_SHIP_PREFLIGHT_MAX_AGE:-86400}
MAX_CONTRACT_BYTES=${FM_SHIP_PREFLIGHT_MAX_CONTRACT_BYTES:-32768}
MAX_EVIDENCE_BYTES=${FM_SHIP_PREFLIGHT_MAX_EVIDENCE_BYTES:-4096}

. "$SCRIPT_DIR/fm-x-lib.sh"

usage() { sed -n '2,14p' "$0" | sed 's/^# //'; }
die() { echo "fm-ship-end-to-end: $*" >&2; exit 1; }
sha256_text() { if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'; else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
valid_private() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ]; }
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
valid_fingerprint() { case "$1" in ????????*) [ "${#1}" -eq 64 ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]' ;; *) return 1;; esac; }
valid_direct_authority() { [ "$1" = direct-captain ]; }
valid_request_id() { valid_id "$1"; }

COMMAND=${1:-}
case "$COMMAND" in preflight|bridge-dispatch|approve|correct|verify|verify-current) shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac
ID=${1:-}; shift || true
valid_id "$ID" || die "unsafe task id"
case "$NOW" in ''|*[!0-9]*) die "FM_SHIP_PREFLIGHT_NOW must be an epoch";; esac
case "$MAX_AGE" in ''|*[!0-9]*|0) die "FM_SHIP_PREFLIGHT_MAX_AGE must be a positive integer";; esac
case "$MAX_CONTRACT_BYTES" in ''|*[!0-9]*|0) die "FM_SHIP_PREFLIGHT_MAX_CONTRACT_BYTES must be a positive integer";; esac
case "$MAX_EVIDENCE_BYTES" in ''|*[!0-9]*|0) die "FM_SHIP_PREFLIGHT_MAX_EVIDENCE_BYTES must be a positive integer";; esac

ORIGIN=''
CONTRACT=''
FINGERPRINT=''
AUTHORITY=''
EVIDENCE=''
REQUEST=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --origin|--contract|--fingerprint|--authority|--evidence|--approved-authority|--approval-evidence|--request)
      key=${1#--}; shift; [ "$#" -gt 0 ] || die "--$key needs a value"
      case "$key" in
        origin) ORIGIN=$1;; contract) CONTRACT=$1;; fingerprint) FINGERPRINT=$1;;
        authority|approved-authority) AUTHORITY=$1;; evidence|approval-evidence) EVIDENCE=$1;; request) REQUEST=$1;;
      esac
      ;;
    *) usage >&2; exit 2;;
  esac
  shift
done

REC_DIR="$DATA/$ID"
RECORD="$REC_DIR/ship-preflight.json"

prepare_dir() {
  if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
    [ -d "$REC_DIR" ] && [ ! -L "$REC_DIR" ] || die "unsafe task record directory"
  else
    (umask 077; mkdir -p "$REC_DIR") || die "could not create task record directory"
  fi
}
validate_contract() {
  [ -f "$CONTRACT" ] && [ ! -L "$CONTRACT" ] || die "contract must be a regular JSON file"
  [ "$(wc -c < "$CONTRACT" | tr -d ' ')" -le "$MAX_CONTRACT_BYTES" ] || die "contract exceeds the bounded preflight size"
  jq -e '
    type == "object" and
    (. as $contract | ["recommendation","outcome","scope","non_goals","delivery_boundary","external_boundaries","questions"] | all(.[]; . as $k | $contract | has($k))) and
    (.recommendation | type == "string" and length > 0) and
    (.outcome | type == "string" and length > 0) and
    (.scope | type == "string" and length > 0) and
    (.non_goals | type == "string") and
    (.delivery_boundary | type == "string" and length > 0) and
    (.external_boundaries | type == "string" and length > 0) and
    (.questions | type == "array" and all(.[]; type == "string" and length > 0))
  ' "$CONTRACT" >/dev/null || die "contract must contain the concise grouped preflight fields"
}
canonical_contract() { jq -cS . "$CONTRACT"; }
validate_direct_approval() {
  local authority=$1 evidence=$2
  valid_direct_authority "$authority" || die "direct preflight requires direct captain approval"
  [ -n "$evidence" ] || die "approval evidence is required"
  [ "$(printf '%s' "$evidence" | wc -c | tr -d ' ')" -le "$MAX_EVIDENCE_BYTES" ] || die "approval evidence exceeds the bounded size"
}
validate_bridge_dispatched_approval() {
  local request proof receipt
  request=$(jq -r '.approval.request_id // ""' "$RECORD")
  proof=$(jq -r '.approval.evidence // ""' "$RECORD")
  valid_request_id "$request" || die "preflight lacks bridge-dispatched authorization"
  case "$proof" in dispatch-proof:????????????????????????????????????????????????????????????????) ;;
    *) die "preflight lacks bridge-dispatched authorization" ;;
  esac
  receipt="$STATE/ship-dispatch-proofs/$request.json"
  fmx_private_artifact_file_valid "$STATE/ship-dispatch-proofs" "$request.json" 600 \
    || die "preflight lacks a consumed bridge dispatch proof"
  jq -e --arg id "$ID" --arg fp "$(jq -r '.fingerprint' "$RECORD")" --arg proof "${proof#dispatch-proof:}" '
    .schema_version == 1 and
    .task_id == $id and
    .fingerprint == $fp and
    .proof == $proof
  ' "$receipt" >/dev/null || die "preflight bridge dispatch proof does not match this task"
  jq -e --arg request "$request" --arg evidence "$proof" '
    .approval == {
      authority:"agent-bridge",
      evidence:$evidence,
      request_id:$request,
      approved_at:.approval.approved_at,
      complete_plan_bypass:false
    } and
    (.approval.approved_at | type == "number")
  ' "$RECORD" >/dev/null || die "preflight lacks bridge-dispatched authorization"
}
bridge_key() {
  local env_file=$FM_HOME/.env
  fmx_single_link_file_mode_valid "$env_file" 600 || die "no private Agent bridge configuration"
  BRIDGE_KEY=$(fmx_env_get FMX_PAIRING_TOKEN "$env_file")
  [ -n "$BRIDGE_KEY" ] || die "Agent bridge configuration has no pairing token"
  [ "${#BRIDGE_KEY}" -le "$MAX_EVIDENCE_BYTES" ] || die "Agent bridge pairing token is too large"
}
bridge_hmac() {
  local payload=$1 digest
  command -v openssl >/dev/null 2>&1 || die "missing openssl for bridge dispatch proof verification"
  digest=$(printf '%s' "$payload" | openssl dgst -sha256 -hmac "$BRIDGE_KEY" 2>/dev/null | awk '{print $NF}')
  valid_fingerprint "$digest" || die "could not verify bridge dispatch proof"
  printf '%s' "$digest"
}
prepare_proof_dir() {
  PROOF_DIR="$STATE/ship-dispatch-proofs"
  fmx_private_artifact_dir_prepare "$PROOF_DIR" >/dev/null || die "unsafe bridge proof directory"
}
consume_bridge_proof() {
  local receipt rc
  prepare_proof_dir
  receipt="$PROOF_DIR/$REQUEST.json"
  if jq -n --arg request "$REQUEST" --arg id "$ID" --arg fp "$FP" --arg proof "$BRIDGE_PROOF" --argjson approved_at "$BRIDGE_APPROVED_AT" --argjson now "$NOW" \
    '{schema_version:1,request_id:$request,task_id:$id,fingerprint:$fp,proof:$proof,approved_at:$approved_at,consumed_at:$now}' \
    | fmx_private_artifact_publish_stdin_once "$PROOF_DIR" "$REQUEST.json" 600; then
    rc=0
  else
    rc=$?
  fi
  case "$rc" in
    0) return ;;
    1) fmx_private_artifact_file_valid "$PROOF_DIR" "$REQUEST.json" 600 || die "unsafe consumed bridge dispatch proof"; die "bridge dispatch proof was already consumed" ;;
    *) die "could not consume bridge dispatch proof" ;;
  esac
}
load_bridge_dispatch() {
  local inbox unsigned expected
  valid_request_id "$REQUEST" || die "--request must be a safe Relay request id"
  inbox="$STATE/x-inbox/$REQUEST.json"
  fmx_private_artifact_file_valid "$STATE/x-inbox" "$REQUEST.json" 600 \
    || die "no private approved Agent bridge request record"
  jq -e --arg request "$REQUEST" --arg id "$ID" '
    .request_id == $request and
    (.ship_dispatch | type == "object") and
    .ship_dispatch.schema_version == 1 and
    .ship_dispatch.task_id == $id and
    (.ship_dispatch.approved_at | type == "number") and
    (.ship_dispatch.proof | type == "string" and test("^[0-9a-f]{64}$")) and
    (.ship_dispatch.contract | type == "object")
  ' "$inbox" >/dev/null || die "Agent bridge request record lacks a valid dispatch proof"
  CONTRACT_JSON=$(jq -cS '.ship_dispatch.contract' "$inbox") || die "malformed Agent bridge dispatch contract"
  [ "$(printf '%s' "$CONTRACT_JSON" | wc -c | tr -d ' ')" -le "$MAX_CONTRACT_BYTES" ] || die "Agent bridge dispatch contract exceeds the bounded preflight size"
  printf '%s' "$CONTRACT_JSON" | jq -e '
    type == "object" and
    (. as $contract | ["recommendation","outcome","scope","non_goals","delivery_boundary","external_boundaries","questions"] | all(.[]; . as $k | $contract | has($k))) and
    (.recommendation | type == "string" and length > 0) and
    (.outcome | type == "string" and length > 0) and
    (.scope | type == "string" and length > 0) and
    (.non_goals | type == "string") and
    (.delivery_boundary | type == "string" and length > 0) and
    (.external_boundaries | type == "string" and length > 0) and
    (.questions | type == "array" and all(.[]; type == "string" and length > 0))
  ' >/dev/null || die "Agent bridge dispatch contract lacks concise preflight fields"
  BRIDGE_APPROVED_AT=$(jq -r '.ship_dispatch.approved_at' "$inbox")
  [ "$BRIDGE_APPROVED_AT" -le "$NOW" ] || die "Agent bridge dispatch proof timestamp is in the future"
  [ $((NOW - BRIDGE_APPROVED_AT)) -le "$MAX_AGE" ] || die "Agent bridge dispatch proof is stale"
  BRIDGE_PROOF=$(jq -r '.ship_dispatch.proof' "$inbox")
  unsigned=$(jq -cS '{request_id,ship_dispatch:{schema_version:.ship_dispatch.schema_version,task_id:.ship_dispatch.task_id,approved_at:.ship_dispatch.approved_at,contract:.ship_dispatch.contract}}' "$inbox") || die "could not canonicalize Agent bridge dispatch proof"
  bridge_key
  expected=$(bridge_hmac "$unsigned")
  [ "$BRIDGE_PROOF" = "$expected" ] || die "Agent bridge dispatch proof is not trusted"
  FP=$(sha256_text "$CONTRACT_JSON")
}
read_record() {
  local record_contract
  valid_private "$RECORD" || die "no valid private preflight record"
  jq -e '
    .schema_version == 1 and
    .workflow == "ship-end-to-end" and
    (.fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
    (.origin == "direct" or .origin == "slack") and
    (.state == "awaiting_approval" or .state == "approved") and
    (.contract | type == "object")
  ' "$RECORD" >/dev/null || die "malformed preflight record"
  record_contract=$(jq -cS '.contract' "$RECORD") || die "malformed preflight contract"
  [ "$(sha256_text "$record_contract")" = "$(jq -r '.fingerprint' "$RECORD")" ] || die "preflight record fingerprint does not match its contract"
}
publish() {
  local tmp
  tmp=$(umask 077; mktemp "$REC_DIR/.ship-preflight.XXXXXX") || die "could not create record"
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! valid_private "$tmp"; then rm -f -- "$tmp"; die "could not prepare private record"; fi
  mv -f -- "$tmp" "$RECORD"
  valid_private "$RECORD" || die "record publication failed validation"
}
lock_transition() {
  [ -d "$REC_DIR" ] && [ ! -L "$REC_DIR" ] || die "unsafe task record directory"
  STATE=$REC_DIR FM_STATE_OVERRIDE=$REC_DIR . "$SCRIPT_DIR/fm-wake-lib.sh"
  PREFLIGHT_LOCK="$REC_DIR/.ship-preflight.lock"
  fm_lock_acquire_wait "$PREFLIGHT_LOCK" || die "could not lock preflight record"
  trap 'fm_lock_release "$PREFLIGHT_LOCK" || true' EXIT
}
verify_record() {
  local fingerprint=$1 origin authority evidence bypass approved_at
  [ "$(jq -r '.state' "$RECORD")" = approved ] || die "preflight approval is missing"
  [ "$(jq -r '.fingerprint' "$RECORD")" = "$fingerprint" ] || die "preflight fingerprint does not match the approved contract"
  origin=$(jq -r '.origin' "$RECORD")
  if [ "$origin" = direct ]; then
    authority=$(jq -r '.approval.authority // ""' "$RECORD")
    evidence=$(jq -r '.approval.evidence // ""' "$RECORD")
    validate_direct_approval "$authority" "$evidence"
  else
    validate_bridge_dispatched_approval
  fi
  bypass=$(jq -r 'if (.approval | has("complete_plan_bypass")) then .approval.complete_plan_bypass else "" end' "$RECORD")
  case "$bypass" in
    true) jq -e '.contract.complete_plan_approved == true' "$RECORD" >/dev/null || die "approved-complete-plan record lacks its approved plan marker" ;;
    false) ;;
    *) die "approval bypass state is malformed" ;;
  esac
  approved_at=$(jq -r '.approval.approved_at // 0' "$RECORD")
  case "$approved_at" in ''|*[!0-9]*) die "approval timestamp is malformed";; esac
  [ "$approved_at" -le "$NOW" ] || die "preflight approval timestamp is in the future"
  [ $((NOW - approved_at)) -le "$MAX_AGE" ] || die "preflight approval is stale"
}

case "$COMMAND" in
  preflight)
    [ -z "$REQUEST" ] || die "--request applies only to bridge-dispatch"
    case "$ORIGIN" in direct) ;; *) die "direct preflight requires --origin direct";; esac
    validate_contract
    prepare_dir
    lock_transition
    [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || die "preflight already exists; use correct to replace an unapproved contract"
    CANONICAL_CONTRACT=$(canonical_contract) || die "could not canonicalize contract"
    FP=$(sha256_text "$CANONICAL_CONTRACT")
    if [ -n "$AUTHORITY" ] || [ -n "$EVIDENCE" ]; then
      validate_direct_approval "$AUTHORITY" "$EVIDENCE"
      jq -e '.complete_plan_approved == true' "$CONTRACT" >/dev/null || die "approved-complete-plan bypass requires complete_plan_approved=true"
      jq -n --argjson contract "$CANONICAL_CONTRACT" --arg fp "$FP" --arg origin "$ORIGIN" --arg authority "$AUTHORITY" --arg evidence "$EVIDENCE" --argjson now "$NOW" \
        '{schema_version:1,workflow:"ship-end-to-end",fingerprint:$fp,origin:$origin,state:"approved",contract:$contract,approval:{authority:$authority,evidence:$evidence,approved_at:$now,complete_plan_bypass:true}}' | publish
    else
      jq -n --argjson contract "$CANONICAL_CONTRACT" --arg fp "$FP" --arg origin "$ORIGIN" --argjson now "$NOW" \
        '{schema_version:1,workflow:"ship-end-to-end",fingerprint:$fp,origin:$origin,state:"awaiting_approval",contract:$contract,created_at:$now}' | publish
    fi
    printf 'fingerprint=%s\n' "$FP"
    ;;
  bridge-dispatch)
    [ -z "$ORIGIN" ] && [ -z "$CONTRACT" ] && [ -z "$FINGERPRINT" ] && [ -z "$AUTHORITY" ] && [ -z "$EVIDENCE" ] \
      || die "bridge-dispatch accepts only a Relay request proof"
    prepare_dir
    load_bridge_dispatch
    lock_transition
    [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || die "preflight already exists"
    consume_bridge_proof
    jq -n --argjson contract "$CONTRACT_JSON" --arg fp "$FP" --arg request "$REQUEST" --arg proof "$BRIDGE_PROOF" --argjson approved_at "$BRIDGE_APPROVED_AT" \
      '{schema_version:1,workflow:"ship-end-to-end",fingerprint:$fp,origin:"slack",state:"approved",contract:$contract,approval:{authority:"agent-bridge",evidence:("dispatch-proof:" + $proof),request_id:$request,approved_at:$approved_at,complete_plan_bypass:false}}' | publish
    printf 'fingerprint=%s\n' "$FP"
    ;;
  approve)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    lock_transition
    read_record
    origin=$(jq -r '.origin' "$RECORD")
    [ "$origin" != slack ] || die "Slack approval is authorized only by Agent bridge dispatch"
    [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ] || die "preflight is not awaiting approval"
    [ "$(jq -r '.fingerprint' "$RECORD")" = "$FINGERPRINT" ] || die "approval fingerprint does not match the current contract"
    validate_direct_approval "$AUTHORITY" "$EVIDENCE"
    APPROVAL=$(jq -cn --arg authority "$AUTHORITY" --arg evidence "$EVIDENCE" '{authority:$authority,evidence:$evidence,complete_plan_bypass:false}')
    jq --arg fp "$FINGERPRINT" --argjson approval "$APPROVAL" --argjson now "$NOW" \
      'if .state == "awaiting_approval" and .fingerprint == $fp then .state="approved" | .approval=($approval + {approved_at:$now}) else error("preflight changed during approval") end' "$RECORD" | publish
    ;;
  correct)
    validate_contract
    lock_transition
    read_record
    [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ] || die "an approved preflight cannot be corrected; create a new task contract"
    CANONICAL_CONTRACT=$(canonical_contract) || die "could not canonicalize contract"
    FP=$(sha256_text "$CANONICAL_CONTRACT")
    origin=$(jq -r '.origin' "$RECORD")
    jq -n --argjson contract "$CANONICAL_CONTRACT" --arg fp "$FP" --arg origin "$origin" --argjson now "$NOW" \
      '{schema_version:1,workflow:"ship-end-to-end",fingerprint:$fp,origin:$origin,state:"awaiting_approval",contract:$contract,created_at:$now,corrected_at:$now}' | publish
    printf 'fingerprint=%s\n' "$FP"
    ;;
  verify)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    verify_record "$FINGERPRINT"
    printf 'approved\n'
    ;;
  verify-current)
    read_record
    FINGERPRINT=$(jq -r '.fingerprint' "$RECORD")
    verify_record "$FINGERPRINT"
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
esac
