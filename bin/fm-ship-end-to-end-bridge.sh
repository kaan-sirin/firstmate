#!/usr/bin/env bash
# Publish one Agent bridge-owned ship preflight submission.
#
# Usage:
#   fm-ship-end-to-end-bridge.sh publish <task-id>
#
# The Agent bridge atomically writes its complete typed record to
# state/ship-preflight-submissions/<task-id>.json, mode 0600, then invokes this
# private handoff. This script does not parse the record or Slack authority.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() { sed -n '2,9p' "$0" | sed 's/^# //'; }
die() { echo "fm-ship-end-to-end-bridge: $*" >&2; exit 1; }
mode_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }
links_of() { if [ "$(uname -s)" = Darwin ]; then stat -f %l "$1"; else stat -c %h "$1"; fi; }
valid_private() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(mode_of "$1" 2>/dev/null || true)" = 600 ] && [ "$(links_of "$1" 2>/dev/null || true)" = 1 ]; }
valid_id() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1;; *) return 0;; esac; }

[ "${1:-}" = publish ] || { usage >&2; exit 2; }
ID=${2:-}
[ "$#" = 2 ] || { usage >&2; exit 2; }
valid_id "$ID" || die "unsafe task id"

SUBMISSIONS="$STATE/ship-preflight-submissions"
if [ -e "$SUBMISSIONS" ] || [ -L "$SUBMISSIONS" ]; then
  [ -d "$SUBMISSIONS" ] && [ ! -L "$SUBMISSIONS" ] && [ "$(mode_of "$SUBMISSIONS" 2>/dev/null || true)" = 700 ] || die "unsafe bridge submission directory"
else
  (umask 077; mkdir -p "$SUBMISSIONS"; chmod 700 "$SUBMISSIONS") || die "could not create bridge submission directory"
fi
SUBMISSION="$SUBMISSIONS/$ID.json"
valid_private "$SUBMISSION" || die "no valid private bridge submission"

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
if ! cat "$SUBMISSION" > "$TMP" || ! chmod 600 "$TMP" || ! valid_private "$TMP"; then
  rm -f -- "$TMP"
  die "could not prepare private preflight record"
fi
mv -f -- "$TMP" "$REC_DIR/ship-preflight.json"
valid_private "$REC_DIR/ship-preflight.json" || die "preflight publication failed validation"
rm -f -- "$SUBMISSION"
printf 'published\n'
