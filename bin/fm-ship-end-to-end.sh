#!/usr/bin/env bash
# Own the durable two-phase approval record for a material software ship task.
#
# Usage:
#   fm-ship-end-to-end.sh verify <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh verify-current <task-id>
#   fm-ship-end-to-end.sh verify-dispatched <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh verify-recovery <task-id> --fingerprint <sha256>
#   fm-ship-end-to-end.sh validate <task-id>
#
# The record is data/<task-id>/ship-preflight.json, mode 0600. Its schema is
# `{schema_version,workflow,task_id,fingerprint,origin,state,contract,created_at|approval}`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NOW=${FM_SHIP_PREFLIGHT_NOW:-$(date +%s)}
MAX_AGE=${FM_SHIP_PREFLIGHT_MAX_AGE:-86400}

usage() { sed -n '2,8p' "$0" | sed -e 's/^#$//' -e 's/^# //'; }
die() { echo "fm-ship-end-to-end: $*" >&2; exit 1; }
sha256_text() { if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'; else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
links_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi; }
owner_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi; }
valid_private() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ] && [ "$(links_of "$1" 2>/dev/null || true)" = 1 ]; }
valid_private_dir() {
  local path=$1 mode owner group other
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  owner=$(owner_of "$path" 2>/dev/null || true)
  [ "$owner" = "$(id -u)" ] || return 1
  mode=$(mode_of "$path" 2>/dev/null || true)
  case "$mode" in [0-7][0-7][0-7]) ;; *) return 1 ;; esac
  group=${mode#?}; group=${group%?}
  other=${mode#??}
  case "$group$other" in *[2367]*) return 1 ;; esac
}
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
valid_fingerprint() { case "$1" in ????????*) [ "${#1}" -eq 64 ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]' ;; *) return 1;; esac; }

COMMAND=${1:-}
case "$COMMAND" in verify|verify-current|verify-dispatched|verify-recovery|validate) shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac
ID=${1:-}; shift || true
valid_id "$ID" || die "unsafe task id"
case "$NOW" in ''|*[!0-9]*) die "FM_SHIP_PREFLIGHT_NOW must be an epoch";; esac
case "$MAX_AGE" in ''|*[!0-9]*|0) die "FM_SHIP_PREFLIGHT_MAX_AGE must be a positive integer";; esac

FINGERPRINT=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fingerprint)
      key=${1#--}; shift; [ "$#" -gt 0 ] || die "--$key needs a value"
      case "$key" in
        fingerprint) FINGERPRINT=$1;;
      esac
      ;;
    *) usage >&2; exit 2;;
  esac
  shift
done

REC_DIR="$DATA/$ID"
RECORD="$REC_DIR/ship-preflight.json"

contract_valid() {
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
  ' "${1:--}" >/dev/null
}
preflight_fingerprint() {
  local contract=$1 bound
  bound=$(jq -cn --arg id "$ID" --argjson contract "$contract" '{task_id:$id,contract:$contract}' | jq -cS .) || return 1
  sha256_text "$bound"
}
read_record() {
  local record_contract
  if ! { [ -e "$DATA" ] || [ -L "$DATA" ]; }; then
    die "no valid private preflight record"
  fi
  valid_private_dir "$DATA" || die "unsafe task record directory"
  if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
    valid_private_dir "$REC_DIR" || die "unsafe task record directory"
  else
    die "no valid private preflight record"
  fi
  valid_private "$RECORD" || die "no valid private preflight record"
  jq -e --arg id "$ID" '
    .schema_version == 1 and
    .workflow == "ship-end-to-end" and
    .task_id == $id and
    (.fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
    (.origin == "direct" or .origin == "bridge") and
    (.state == "awaiting_approval" or .state == "approved") and
    (.contract | type == "object")
  ' "$RECORD" >/dev/null || die "malformed preflight record"
  record_contract=$(jq -cS '.contract' "$RECORD") || die "malformed preflight contract"
  printf '%s\n' "$record_contract" | contract_valid || die "malformed preflight contract"
  [ "$(preflight_fingerprint "$record_contract")" = "$(jq -r '.fingerprint' "$RECORD")" ] || die "preflight record fingerprint does not match its contract"
}
verify_record() {
  local fingerprint=$1 require_fresh=${2:-1} bypass approved_at
  [ "$(jq -r '.state' "$RECORD")" = approved ] || die "preflight approval is missing"
  [ "$(jq -r '.fingerprint' "$RECORD")" = "$fingerprint" ] || die "preflight fingerprint does not match the approved contract"
  jq -e '
    (.approval | type == "object") and
    (.approval.approved_at | type == "number") and
    (.approval.complete_plan_bypass | type == "boolean") and
    (.approval.evidence == "bridge-submission") and
    ((.origin == "direct" and .approval.authority == "direct-captain") or
     (.origin == "bridge" and .approval.authority == "agent-bridge"))
  ' "$RECORD" >/dev/null || die "preflight lacks typed approval authority evidence"
  bypass=$(jq -r 'if (.approval | has("complete_plan_bypass")) then .approval.complete_plan_bypass else "" end' "$RECORD")
  case "$bypass" in
    true) jq -e '.contract.complete_plan_approved == true' "$RECORD" >/dev/null || die "approved-complete-plan record lacks its approved plan marker" ;;
    false) ;;
    *) die "approval bypass state is malformed" ;;
  esac
  approved_at=$(jq -r '.approval.approved_at // 0' "$RECORD")
  case "$approved_at" in ''|*[!0-9]*) die "approval timestamp is malformed";; esac
  [ "$approved_at" -le "$NOW" ] || die "preflight approval timestamp is in the future"
  [ "$require_fresh" = 0 ] || [ $((NOW - approved_at)) -le "$MAX_AGE" ] || die "preflight approval is stale"
}

case "$COMMAND" in
  validate)
    read_record
    if [ "$(jq -r '.state' "$RECORD")" = approved ]; then
      verify_record "$(jq -r '.fingerprint' "$RECORD")" 0
    else
      jq -e '.created_at | type == "number" and . >= 0' "$RECORD" >/dev/null || die "preflight creation timestamp is malformed"
    fi
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
  verify-dispatched)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    verify_record "$FINGERPRINT" 0
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
  verify-recovery)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    if [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ]; then
      exit 4
    fi
    verify_record "$FINGERPRINT" 0
    printf 'fingerprint=%s\n' "$FINGERPRINT"
    ;;
esac
