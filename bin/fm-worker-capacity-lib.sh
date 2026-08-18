#!/usr/bin/env bash
# fm-worker-capacity-lib.sh - fail-closed local worker-capacity guard.
#
# A FirstMate home can set config/max-active-workers to one positive base-10
# integer. fm-spawn consults this guard while holding the home task-set lock,
# before it creates a new endpoint. The guard counts each recorded direct
# report whose endpoint is alive, ambiguous, unreadable, or not yet verifiable.
# It excludes only endpoints proven dead or missing. This protects a small host
# from an otherwise independent batch of agent launches exhausting memory.
#
# An absent file keeps the historical unlimited behaviour. A malformed or
# unsafe file is an error, never an implicit unlimited value. The config is
# inherited by secondmate homes through fm-config-inherit-lib.sh.
#
# Source after fm-backend.sh. Public functions:
#   fm_worker_capacity_limit <config-dir>       -> positive integer or 0 absent
#   fm_worker_capacity_active <state-dir>       -> active count

fm_worker_capacity_limit() {  # <config-dir>
  local config=$1 file value links bytes
  if [ -e "$config" ] || [ -L "$config" ]; then
    [ -d "$config" ] && [ ! -L "$config" ] || return 1
  fi
  file="$config/max-active-workers"
  [ -e "$file" ] || [ -L "$file" ] || { printf '0'; return 0; }
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    links=$(stat -f %l "$file" 2>/dev/null) || return 1
  else
    links=$(stat -c %h "$file" 2>/dev/null) || return 1
  fi
  [ "$links" = 1 ] || return 1
  value=$(<"$file")
  case "$value" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;;
    *) return 1 ;;
  esac
  bytes=$(LC_ALL=C wc -c < "$file") || return 1
  bytes=${bytes//[[:space:]]/}
  [ "$bytes" = "$(( ${#value} + 1 ))" ] || return 1
  printf '%s' "$value"
}

fm_worker_capacity_active() {  # <state-dir>
  local state=$1 meta backend target verdict count=0
  [ -d "$state" ] || { printf '0'; return 0; }
  shopt -s nullglob
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    backend=$(fm_backend_of_meta "$meta") || return 1
    target=$(fm_backend_target_of_meta "$meta") || return 1
    [ -n "$target" ] || return 1
    verdict=$(fm_backend_agent_state "$backend" "$target") || return 1
    case "$verdict" in
      dead|missing) ;;
      alive|ambiguous|unreadable|unverified) count=$((count + 1)) ;;
      *) return 1 ;;
    esac
  done
  shopt -u nullglob
  printf '%s' "$count"
}
