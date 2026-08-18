#!/usr/bin/env bash
# fm-worker-capacity-lib.sh - fail-closed local worker-capacity guard.
#
# A FirstMate home can set config/max-active-workers to one positive base-10
# integer. fm-spawn consults this guard while holding the host admission lock,
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
#   fm_worker_capacity_active_host <state-dir>  -> active local-host count
#   fm_worker_capacity_pending_reserve <state-dir> <task-id>
#   fm_worker_capacity_pending_release <state-dir> <task-id>
#   fm_worker_capacity_pending_until_started <state-dir> <task-id>

fm_worker_capacity_file_valid() {  # <file>
  local file=$1 value links bytes
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
  [ "$bytes" = "$(( ${#value} + 1 ))" ]
}

fm_worker_capacity_limit() {  # <config-dir>
  local config=$1 file value
  if [ -e "$config" ] || [ -L "$config" ]; then
    [ -d "$config" ] && [ ! -L "$config" ] || return 1
  fi
  file="$config/max-active-workers"
  [ -e "$file" ] || [ -L "$file" ] || { printf '0'; return 0; }
  fm_worker_capacity_file_valid "$file" || return 1
  value=$(<"$file")
  printf '%s' "$value"
}

fm_worker_capacity_pending_path() {  # <state-dir> <task-id>
  local state=$1 id=$2
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s/.worker-capacity-%s.pending\n' "$state" "$id"
}

fm_worker_capacity_pending_reserve() {  # <state-dir> <task-id>
  local state=$1 id=$2 pending
  pending=$(fm_worker_capacity_pending_path "$state" "$id") || return 1
  [ ! -e "$pending" ] && [ ! -L "$pending" ] || return 1
  (umask 077; printf '%s\n' "$id" > "$pending") || return 1
  [ -f "$pending" ] && [ ! -L "$pending" ]
}

fm_worker_capacity_pending_release() {  # <state-dir> <task-id>
  local state=$1 id=$2 pending
  pending=$(fm_worker_capacity_pending_path "$state" "$id") || return 1
  [ ! -e "$pending" ] && [ ! -L "$pending" ] && return 0
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
  rm -f -- "$pending"
}

fm_worker_capacity_pending_until_started() {  # <state-dir> <task-id>
  local state=$1 id=$2 meta backend target verdict i=0 limit=${FM_WORKER_CAPACITY_START_POLLS:-100}
  case "$limit" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]) ;; *) return 1 ;; esac
  meta="$state/$id.meta"
  while [ "$i" -lt "$limit" ]; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    backend=$(fm_backend_of_meta "$meta") || return 1
    target=$(fm_backend_target_of_meta "$meta") || return 1
    [ -n "$target" ] || return 1
    verdict=$(fm_backend_agent_state "$backend" "$target") || return 1
    case "$verdict" in
      alive|ambiguous|unreadable|unverified) return 0 ;;
      dead|missing) sleep 0.1 ;;
      *) return 1 ;;
    esac
    i=$((i + 1))
  done
  return 1
}

fm_worker_capacity_active() {  # <state-dir>
  fm_worker_capacity_active_in_state "$1" 0
}

fm_worker_capacity_active_in_state() {  # <state-dir> <skip-remote-secondmates>
  local state=$1 skip_remote=$2 meta pending backend target verdict kind remote_host count=0
  [ -d "$state" ] || { printf '0'; return 0; }
  shopt -s nullglob
  for pending in "$state"/.worker-capacity-*.pending; do
    [ -f "$pending" ] && [ ! -L "$pending" ] || return 1
    count=$((count + 1))
  done
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
    if [ "$skip_remote" = 1 ]; then
      kind=$(fm_meta_get "$meta" kind)
      remote_host=$(fm_meta_get "$meta" remote_host)
      [ "$kind" = secondmate ] && [ -n "$remote_host" ] && continue
    fi
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

fm_worker_capacity_active_host() {  # <primary-state-dir>
  local state=$1 meta kind home remote_host active count=0
  [ -d "$state" ] || { printf '0'; return 0; }
  active=$(fm_worker_capacity_active_in_state "$state" 1) || return 1
  count=$active
  shopt -s nullglob
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || { shopt -u nullglob; return 1; }
    kind=$(fm_meta_get "$meta" kind)
    remote_host=$(fm_meta_get "$meta" remote_host)
    [ "$kind" = secondmate ] && [ -z "$remote_host" ] || continue
    home=$(fm_meta_get "$meta" home)
    case "$home" in /*) ;; *) shopt -u nullglob; return 1 ;; esac
    [ -d "$home" ] && [ ! -L "$home" ] \
      && [ -f "$home/.fm-secondmate-home" ] && [ ! -L "$home/.fm-secondmate-home" ] \
      && [ -d "$home/state" ] || { shopt -u nullglob; return 1; }
    active=$(fm_worker_capacity_active_in_state "$home/state" 1) || { shopt -u nullglob; return 1; }
    count=$((count + active))
  done
  shopt -u nullglob
  printf '%s' "$count"
}
