#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ "${1:-}" = reconcile ] || { echo "usage: fm-dashboard-run-state.sh reconcile <task-id>" >&2; exit 2; }
ID=${2:-}
case "$ID" in ''|*[!A-Za-z0-9._-]*) exit 2 ;; esac

STATE_BIN=${FM_DASHBOARD_RUN_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}
line=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$STATE_BIN" "$ID" 2>/dev/null || true)
case "$line" in state:\ *) ;; *) exit 0 ;; esac
state=${line#state: }
state=${state%% *}
case "$line" in *' · source: run-step · '*) ;; *) exit 0 ;; esac
at=$(printf '%s\n' "$line" | sed -n 's/.*transition_at: \([0-9][0-9]*\).*/\1/p' | head -1)
case "$state:$at" in
  working:[0-9]*|parked:[0-9]*|paused:[0-9]*|blocked:[0-9]*|failed:[0-9]*|done:[0-9]*|unknown:[0-9]*) ;;
  *) exit 0 ;;
esac
"$SCRIPT_DIR/fm-dashboard-transition.sh" record "$STATE" "$ID" "$state" "$at"
