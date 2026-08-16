#!/usr/bin/env bash
# Atomically publish one private Agent bridge ship preflight handoff.
#
# Usage:
#   fm-agent-bridge-ship-preflight.sh publish <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,5p' "$0" | sed 's/^# //'; }
die() { echo "fm-agent-bridge-ship-preflight: $*" >&2; exit 1; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
links_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi; }
valid_private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ] && [ "$(links_of "$1" 2>/dev/null || true)" = 1 ]; }
valid_private_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 700 ]; }
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }

[ "${1:-}" = publish ] && [ "$#" = 2 ] || { usage >&2; exit 2; }
ID=$2
valid_id "$ID" || die "unsafe task id"

BRIDGE_ROOT="$STATE/agent-bridge"
HANDOFF_DIR="$BRIDGE_ROOT/ship-preflight"
valid_private_dir "$BRIDGE_ROOT" && valid_private_dir "$HANDOFF_DIR" || die "unsafe bridge handoff directory"
HANDOFF="$HANDOFF_DIR/$ID.json"
valid_private_file "$HANDOFF" || die "no valid private bridge handoff"

REC_DIR="$DATA/$ID"
if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
  [ -d "$REC_DIR" ] && [ ! -L "$REC_DIR" ] || die "unsafe task record directory"
else
  (umask 077; mkdir -p "$REC_DIR") || die "could not create task record directory"
fi

STATE="$REC_DIR" FM_STATE_OVERRIDE="$REC_DIR" . "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK="$REC_DIR/.ship-preflight.lock"
fm_lock_acquire_wait "$LOCK" || die "could not lock preflight record"
trap 'fm_lock_release "$LOCK" || true' EXIT

TMP=$(umask 077; mktemp "$REC_DIR/.ship-preflight.XXXXXX") || die "could not prepare preflight record"
if ! cat "$HANDOFF" > "$TMP" || ! chmod 600 "$TMP" || ! valid_private_file "$TMP"; then
  rm -f -- "$TMP"
  die "could not prepare private preflight record"
fi
mv -f -- "$TMP" "$REC_DIR/ship-preflight.json"
valid_private_file "$REC_DIR/ship-preflight.json" || die "preflight publication failed validation"
rm -f -- "$HANDOFF"
printf 'published\n'
