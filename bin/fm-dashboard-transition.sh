#!/usr/bin/env bash
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "usage: fm-dashboard-transition.sh record <state-dir> <task-id> <working|parked|paused|blocked|failed|done|unknown> <epoch>" >&2
  exit 2
}

[ "${1:-}" = record ] || usage
STATE=${2:-}
ID=${3:-}
CURRENT=${4:-}
AT=${5:-}
[ -n "$STATE" ] && [ -n "$ID" ] || usage
case "$ID" in ''|*[!A-Za-z0-9._-]*) usage ;; esac
case "$CURRENT" in working|parked|paused|blocked|failed|done|unknown) ;; *) usage ;; esac
case "$AT" in ''|*[!0-9]*) usage ;; esac

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || exit 0
if [ "$(uname -s)" = Darwin ]; then meta_mtime=$(stat -f %m "$META" 2>/dev/null || true); else meta_mtime=$(stat -c %Y "$META" 2>/dev/null || true); fi
case "$meta_mtime" in ''|*[!0-9]*) exit 0 ;; esac

DIR="$STATE/dashboard-transitions"
if [ -e "$DIR" ] || [ -L "$DIR" ]; then
  [ -d "$DIR" ] && [ ! -L "$DIR" ] || exit 1
else
  (umask 077; mkdir -p "$DIR")
  chmod 700 "$DIR"
fi

LOCK="$DIR/$ID.lock"
tries=0
while ! mkdir "$LOCK" 2>/dev/null; do
  tries=$((tries + 1))
  [ "$tries" -lt 100 ] || exit 1
  sleep 0.05
done
cleanup() { rmdir "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT HUP INT TERM

RECORD="$DIR/$ID.json"
prior_state=
prior_meta=
prior_at=
prior_active=0
if [ -f "$RECORD" ] && [ ! -L "$RECORD" ]; then
  IFS=$'\t' read -r prior_state prior_meta prior_at prior_active < <(
    jq -r '[.state // "",(.meta_mtime // "" | tostring),(.transition_at // "" | tostring),(.active_seconds // 0 | tostring)] | @tsv' "$RECORD" 2>/dev/null || true
  )
  if [ "$prior_meta" != "$meta_mtime" ]; then
    prior_state=
    prior_at=
    prior_active=0
  fi
fi
case "$prior_at:$prior_active" in *[!0-9:]*|:*) prior_at=; prior_active=0 ;; esac
[ "$prior_state" != "$CURRENT" ] || exit 0
if [ -n "$prior_at" ] && [ "$AT" -lt "$prior_at" ]; then exit 1; fi
tmp=$(umask 077; mktemp "$DIR/.${ID}.XXXXXX")
if ! jq -n --arg id "$ID" --arg state "$CURRENT" --argjson transition_at "$AT" --argjson meta_mtime "$meta_mtime" --arg prior_state "$prior_state" --argjson prior_at "${prior_at:-$AT}" --argjson active_seconds "$prior_active" '
  ($active_seconds + (if $prior_state == "working" then ($transition_at - $prior_at) else 0 end)) as $active_seconds
  | {schema_version:1,id:$id,state:$state,transition_at:$transition_at,meta_mtime:$meta_mtime,active_seconds:$active_seconds}' > "$tmp" \
  || ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
  rm -f -- "$tmp"
  exit 1
fi
