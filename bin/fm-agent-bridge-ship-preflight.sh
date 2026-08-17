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
owner_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %u "$1"; else stat -c %u "$1"; fi; }
valid_private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ] && [ "$(links_of "$1" 2>/dev/null || true)" = 1 ]; }
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
recover_claim() {
  local claim
  local -a claims
  shopt -s nullglob
  claims=("$HANDOFF_DIR/.${ID}.claim."*)
  shopt -u nullglob
  [ "${#claims[@]}" -le 1 ] || die "multiple private bridge handoff claims"
  [ "${#claims[@]}" -eq 1 ] || return 0
  claim=${claims[0]}
  valid_private_file "$claim" || die "invalid private bridge handoff claim"
  if [ -e "$HANDOFF" ] || [ -L "$HANDOFF" ]; then
    valid_private_file "$HANDOFF" || die "no valid private bridge handoff"
  elif ! ln "$claim" "$HANDOFF"; then
    valid_private_file "$HANDOFF" || die "could not recover private bridge handoff"
  fi
  rm -f -- "$claim" || die "could not recover private bridge handoff"
}

[ "${1:-}" = publish ] && [ "$#" = 2 ] || { usage >&2; exit 2; }
ID=$2
valid_id "$ID" || die "unsafe task id"

BRIDGE_ROOT="$STATE/agent-bridge"
HANDOFF_DIR="$BRIDGE_ROOT/ship-preflight"
if ! valid_private_dir "$BRIDGE_ROOT" || ! valid_private_dir "$HANDOFF_DIR"; then
  die "unsafe bridge handoff directory"
fi
HANDOFF="$HANDOFF_DIR/$ID.json"
recover_claim
valid_private_file "$HANDOFF" || die "no valid private bridge handoff"

valid_private_dir "$DATA" || die "unsafe task record directory"
REC_DIR="$DATA/$ID"
if [ -e "$REC_DIR" ] || [ -L "$REC_DIR" ]; then
  valid_private_dir "$REC_DIR" || die "unsafe task record directory"
else
  (umask 077; mkdir "$REC_DIR") || die "could not create task record directory"
  valid_private_dir "$REC_DIR" || die "unsafe task record directory"
fi

# shellcheck source=bin/fm-wake-lib.sh
STATE="$REC_DIR" FM_STATE_OVERRIDE="$REC_DIR" . "$SCRIPT_DIR/fm-wake-lib.sh"
LOCK="$REC_DIR/.ship-preflight.lock"
fm_lock_acquire_wait "$LOCK" || die "could not lock preflight record"
CLAIM=
restore_claim() {
  [ -n "$CLAIM" ] && [ -f "$CLAIM" ] || return 0
  if [ ! -e "$HANDOFF" ] && [ ! -L "$HANDOFF" ]; then
    ln "$CLAIM" "$HANDOFF" 2>/dev/null && rm -f -- "$CLAIM" || true
  fi
  [ ! -e "$HANDOFF" ] && [ ! -L "$HANDOFF" ] || rm -f -- "$CLAIM" || true
}
cleanup() {
  local status=$?
  trap - EXIT
  [ "$status" -eq 0 ] || restore_claim
  fm_lock_release "$LOCK" || true
  exit "$status"
}
trap cleanup EXIT

CLAIM=$(umask 077; mktemp "$HANDOFF_DIR/.${ID}.claim.XXXXXX") || die "could not claim private bridge handoff"
mv -f -- "$HANDOFF" "$CLAIM" || die "could not claim private bridge handoff"
valid_private_file "$CLAIM" || die "invalid private bridge handoff"

TMP=$(umask 077; mktemp "$REC_DIR/.ship-preflight.XXXXXX") || die "could not prepare preflight record"
if ! cat "$CLAIM" > "$TMP" || ! chmod 600 "$TMP" || ! valid_private_file "$TMP"; then
  rm -f -- "$TMP"
  die "could not prepare private preflight record"
fi
mv -f -- "$TMP" "$REC_DIR/ship-preflight.json"
valid_private_file "$REC_DIR/ship-preflight.json" || die "preflight publication failed validation"
rm -f -- "$CLAIM"
CLAIM=
printf 'published\n'
