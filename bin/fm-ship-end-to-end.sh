#!/usr/bin/env bash
# Own the durable two-phase approval record for a material software ship task.
#
# Usage:
#   fm-ship-end-to-end.sh preflight <task-id> --origin <direct|slack> --contract <json-file>
#   fm-ship-end-to-end.sh preflight <task-id> --origin <direct|slack> --contract <json-file> --approved-authority <authority> --approval-evidence <text>
#   fm-ship-end-to-end.sh approve <task-id> --fingerprint <sha256> --authority <authority> --evidence <text>
#   fm-ship-end-to-end.sh correct <task-id> --contract <json-file>
#   fm-ship-end-to-end.sh verify <task-id> --fingerprint <sha256>
#
# The record is data/<task-id>/ship-preflight.json, mode 0600. Its schema is
# `{schema_version,fingerprint,origin,state,contract,created_at|approval}`.
# `contract` is the canonical JSON object supplied at preflight. `approval`,
# when present, is `{authority,evidence,approved_at,complete_plan_bypass}`.
# `preflight` is phase 1 and creates an awaiting-approval contract. `approve` begins phase 2
# only when the approver repeats the current fingerprint. An explicitly
# approved complete plan may use the second preflight form, but an untrusted
# Slack authority is always refused. `verify` is the spawn gate used when a
# ship brief carries `Ship preflight: fingerprint=<sha256>`.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
NOW=${FM_SHIP_PREFLIGHT_NOW:-$(date +%s)}
MAX_AGE=${FM_SHIP_PREFLIGHT_MAX_AGE:-86400}
MAX_CONTRACT_BYTES=${FM_SHIP_PREFLIGHT_MAX_CONTRACT_BYTES:-32768}
MAX_EVIDENCE_BYTES=${FM_SHIP_PREFLIGHT_MAX_EVIDENCE_BYTES:-4096}

usage() { sed -n '2,18p' "$0" | sed 's/^# //'; }
die() { echo "fm-ship-end-to-end: $*" >&2; exit 1; }
sha256_text() { if command -v sha256sum >/dev/null 2>&1; then printf '%s' "$1" | sha256sum | awk '{print $1}'; else printf '%s' "$1" | shasum -a 256 | awk '{print $1}'; fi; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
valid_private() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ]; }
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }
valid_fingerprint() { case "$1" in ????????*) [ "${#1}" -eq 64 ] && ! printf '%s' "$1" | grep -q '[^0-9a-f]' ;; *) return 1;; esac; }
valid_authority() { case "$1" in direct-captain|trusted-slack-owner) return 0;; *) return 1;; esac; }

COMMAND=${1:-}
case "$COMMAND" in preflight|approve|correct|verify) shift;; -h|--help) usage; exit 0;; *) usage >&2; exit 2;; esac
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
while [ "$#" -gt 0 ]; do
  case "$1" in
    --origin|--contract|--fingerprint|--authority|--evidence|--approved-authority|--approval-evidence)
      key=${1#--}; shift; [ "$#" -gt 0 ] || die "--$key needs a value"
      case "$key" in origin) ORIGIN=$1;; contract) CONTRACT=$1;; fingerprint) FINGERPRINT=$1;; authority|approved-authority) AUTHORITY=$1;; evidence|approval-evidence) EVIDENCE=$1;; esac
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
canonical_contract() {
  jq -cS . "$CONTRACT"
}
validate_approval() { # <origin> <authority> <evidence>
  local origin=$1 authority=$2 evidence=$3
  valid_authority "$authority" || die "approval authority is not trusted"
  [ -n "$evidence" ] || die "approval evidence is required"
  [ "$(printf '%s' "$evidence" | wc -c | tr -d ' ')" -le "$MAX_EVIDENCE_BYTES" ] || die "approval evidence exceeds the bounded size"
  case "$origin:$authority" in
    direct:direct-captain|slack:trusted-slack-owner) ;;
    slack:*) die "untrusted Slack content cannot self-approve" ;;
    *) die "direct preflight requires direct captain approval" ;;
  esac
}
read_record() {
  local record_contract
  valid_private "$RECORD" || die "no valid private preflight record"
  jq -e '
    .schema_version == 1 and
    (.fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
    (.origin == "direct" or .origin == "slack") and
    (.state == "awaiting_approval" or .state == "approved") and
    (.contract | type == "object")
  ' "$RECORD" >/dev/null \
    || die "malformed preflight record"
  record_contract=$(jq -cS '.contract' "$RECORD") || die "malformed preflight contract"
  [ "$(sha256_text "$record_contract")" = "$(jq -r '.fingerprint' "$RECORD")" ] \
    || die "preflight record fingerprint does not match its contract"
}
publish() { # stdin -> record
  local tmp
  tmp=$(umask 077; mktemp "$REC_DIR/.ship-preflight.XXXXXX") || die "could not create record"
  if ! cat > "$tmp" || ! chmod 600 "$tmp" || ! valid_private "$tmp"; then rm -f -- "$tmp"; die "could not prepare private record"; fi
  mv -f -- "$tmp" "$RECORD"
  valid_private "$RECORD" || die "record publication failed validation"
}

case "$COMMAND" in
  preflight)
    case "$ORIGIN" in direct|slack) ;; *) die "--origin must be direct or slack";; esac
    validate_contract
    prepare_dir
    [ ! -e "$RECORD" ] && [ ! -L "$RECORD" ] || die "preflight already exists; use correct to replace an unapproved contract"
    CANONICAL_CONTRACT=$(canonical_contract) || die "could not canonicalize contract"
    FP=$(sha256_text "$CANONICAL_CONTRACT")
    if [ -n "$AUTHORITY" ] || [ -n "$EVIDENCE" ]; then
      validate_approval "$ORIGIN" "$AUTHORITY" "$EVIDENCE"
      jq -e '.complete_plan_approved == true' "$CONTRACT" >/dev/null || die "approved-complete-plan bypass requires complete_plan_approved=true"
      jq -n --argjson contract "$CANONICAL_CONTRACT" --arg fp "$FP" --arg origin "$ORIGIN" --arg authority "$AUTHORITY" --arg evidence "$EVIDENCE" --argjson now "$NOW" \
        '{schema_version:1,fingerprint:$fp,origin:$origin,state:"approved",contract:$contract,approval:{authority:$authority,evidence:$evidence,approved_at:$now,complete_plan_bypass:true}}' | publish
    else
      jq -n --argjson contract "$CANONICAL_CONTRACT" --arg fp "$FP" --arg origin "$ORIGIN" --argjson now "$NOW" \
        '{schema_version:1,fingerprint:$fp,origin:$origin,state:"awaiting_approval",contract:$contract,created_at:$now}' | publish
    fi
    printf 'fingerprint=%s\n' "$FP"
    ;;
  approve)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ] || die "preflight is not awaiting approval"
    [ "$(jq -r '.fingerprint' "$RECORD")" = "$FINGERPRINT" ] || die "approval fingerprint does not match the current contract"
    origin=$(jq -r '.origin' "$RECORD")
    validate_approval "$origin" "$AUTHORITY" "$EVIDENCE"
    jq --arg authority "$AUTHORITY" --arg evidence "$EVIDENCE" --argjson now "$NOW" \
      '.state="approved" | .approval={authority:$authority,evidence:$evidence,approved_at:$now,complete_plan_bypass:false}' "$RECORD" | publish
    ;;
  correct)
    validate_contract
    read_record
    [ "$(jq -r '.state' "$RECORD")" = awaiting_approval ] || die "an approved preflight cannot be corrected; create a new task contract"
    CANONICAL_CONTRACT=$(canonical_contract) || die "could not canonicalize contract"
    FP=$(sha256_text "$CANONICAL_CONTRACT")
    origin=$(jq -r '.origin' "$RECORD")
    jq -n --argjson contract "$CANONICAL_CONTRACT" --arg fp "$FP" --arg origin "$origin" --argjson now "$NOW" \
      '{schema_version:1,fingerprint:$fp,origin:$origin,state:"awaiting_approval",contract:$contract,created_at:$now,corrected_at:$now}' | publish
    printf 'fingerprint=%s\n' "$FP"
    ;;
  verify)
    valid_fingerprint "$FINGERPRINT" || die "--fingerprint must be a SHA-256 fingerprint"
    read_record
    [ "$(jq -r '.state' "$RECORD")" = approved ] || die "preflight approval is missing"
    [ "$(jq -r '.fingerprint' "$RECORD")" = "$FINGERPRINT" ] || die "preflight fingerprint does not match the approved contract"
    origin=$(jq -r '.origin' "$RECORD")
    approval_authority=$(jq -r '.approval.authority // ""' "$RECORD")
    approval_evidence=$(jq -r '.approval.evidence // ""' "$RECORD")
    validate_approval "$origin" "$approval_authority" "$approval_evidence"
    complete_plan_bypass=$(jq -r 'if (.approval | has("complete_plan_bypass")) then .approval.complete_plan_bypass else "" end' "$RECORD")
    case "$complete_plan_bypass" in
      true)
        jq -e '.contract.complete_plan_approved == true' "$RECORD" >/dev/null \
          || die "approved-complete-plan record lacks its approved plan marker"
        ;;
      false) ;;
      *) die "approval bypass state is malformed" ;;
    esac
    approved_at=$(jq -r '.approval.approved_at // 0' "$RECORD")
    case "$approved_at" in ''|*[!0-9]*) die "approval timestamp is malformed";; esac
    [ "$approved_at" -le "$NOW" ] || die "preflight approval timestamp is in the future"
    [ $((NOW - approved_at)) -le "$MAX_AGE" ] || die "preflight approval is stale"
    printf 'approved\n'
    ;;
esac
