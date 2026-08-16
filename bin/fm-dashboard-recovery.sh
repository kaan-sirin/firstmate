#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
MAX_ATTEMPTS=${FM_DASHBOARD_RECOVERY_MAX_ATTEMPTS:-2}

case "${1:-}" in observe) ;; *) echo "usage: fm-dashboard-recovery.sh observe <task-id>" >&2; exit 2 ;; esac
ID=${2:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) echo "fm-dashboard-recovery: invalid task id" >&2; exit 2 ;; esac
case "$MAX_ATTEMPTS" in ''|*[!0-9]*|0) echo "fm-dashboard-recovery: invalid maximum attempts" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
kind=$(fm_meta_get "$META" kind)
case "$kind" in ship|scout|'') ;; *) exit 0 ;; esac
STATE_BIN=${FM_DASHBOARD_RECOVERY_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$STATE_BIN" "$ID" 2>/dev/null || true)
case "$line" in state:\ unknown\ *) ;; *) exit 0 ;; esac
backend=$(fm_backend_of_meta "$META")
target=$(fm_backend_target_of_meta "$META")
[ -n "$target" ] || exit 0
AGENT_STATE_BIN=${FM_DASHBOARD_RECOVERY_AGENT_STATE_BIN:-}
if [ -n "$AGENT_STATE_BIN" ]; then
  agent_state=$("$AGENT_STATE_BIN" "$backend" "$target" 2>/dev/null || true)
else
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)
fi
case "$agent_state" in dead|missing) ;; *) exit 0 ;; esac
recovery_at=$(date +%s)
case "$recovery_at" in ''|*[!0-9]*) exit 1 ;; esac
"$SCRIPT_DIR/fm-dashboard-transition.sh" record "$STATE" "$ID" unknown "$recovery_at"

DIR="$STATE/dashboard-recovery"
if [ -e "$DIR" ] || [ -L "$DIR" ]; then
  [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
else
  (umask 077; mkdir -p "$DIR")
  chmod 700 "$DIR"
fi
LOCK="$DIR/$ID.lock"
fm_lock_acquire_wait "$LOCK"
cleanup() { fm_lock_release "$LOCK" || true; }
trap cleanup EXIT HUP INT TERM
RECORD="$DIR/$ID.json"
attempts=0
if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
  IFS=$'\t' read -r prior_state attempts < <(jq -r '[.state // "",(.attempts // 0 | tostring)] | @tsv' "$RECORD" 2>/dev/null || true)
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  [ "$prior_state" != unrecoverable ] || exit 0
fi
RECOVERY_BIN=${FM_DASHBOARD_RECOVERY_SPAWN_BIN:-$SCRIPT_DIR/fm-spawn.sh}
out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$RECOVERY_BIN" "$ID" --recover-missing 2>&1) || recovery_status=$?
recovery_status=${recovery_status:-0}
if [ "$recovery_status" -eq 0 ]; then
  rm -f -- "$RECORD"
  exit 0
fi
if [ "$recovery_status" -eq 4 ]; then
  exit 0
fi
if [ "$recovery_status" -eq 3 ]; then
  state=unrecoverable
  attempts=0
  reason=$(printf '%s\n' "$out" | head -1 | tr '\r\n' ' ' | sed 's/[[:space:]]*$//' | cut -c1-240)
  tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
  if ! jq -n --arg id "$ID" --arg state "$state" --arg reason "$reason" --argjson attempts "$attempts" --argjson confirmed_at "$(date +%s)" \
    '{schema_version:1,id:$id,state:$state,attempts:$attempts,confirmed_at:$confirmed_at,reason:$reason}' > "$tmp" \
    || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    exit 1
  fi
  exit 0
fi
attempts=$((attempts + 1))
state=pending
[ "$attempts" -lt "$MAX_ATTEMPTS" ] || state=unrecoverable
reason=$(printf '%s\n' "$out" | head -1 | tr '\r\n' ' ' | sed 's/[[:space:]]*$//' | cut -c1-240)
tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
if ! jq -n --arg id "$ID" --arg state "$state" --arg reason "$reason" --argjson attempts "$attempts" --argjson confirmed_at "$(date +%s)" \
  '{schema_version:1,id:$id,state:$state,attempts:$attempts,confirmed_at:$confirmed_at,reason:$reason}' > "$tmp" \
  || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
  rm -f -- "$tmp"
  exit 1
fi
