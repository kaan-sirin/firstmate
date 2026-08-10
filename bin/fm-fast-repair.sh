#!/usr/bin/env bash
# Manage the strict opt-in Fast Repair delivery path.
# Usage:
#   fm-fast-repair.sh is-request <request>
#   fm-fast-repair.sh intake <task-id> --request 'fast-repair: <task>' \
#     --reproduction <evidence> --root-cause <evidence> --isolation <evidence> \
#     --schema none --authentication none --authorization none --secrets none \
#     --financial none --legal none --side-effects none
#   fm-fast-repair.sh eligible <task-id>
#   fm-fast-repair.sh evidence <task-id> --regression-command <command> --focused-command <command>
#   fm-fast-repair.sh publish-pr <task-id> --title <text> --body-file <path> [--base <branch>] [--head <branch>]
#   fm-fast-repair.sh broader <task-id> --command <command>
#   fm-fast-repair.sh progress <task-id>
#   fm-fast-repair.sh ready <task-id>
#
# `fast-repair:` is the only accepted request prefix, and it must be followed by
# one space and a non-empty request. `intake` records a typed, private evidence
# record only when all three positive facts are non-empty and all seven risk
# exclusions equal `none`. Any missing, unknown, ambiguous, or different value
# refuses Fast Repair before a task can use this delivery mode; firstmate then
# uses normal intake for that request.
#
# A Fast Repair spawn must use mode=fast-repair, yolo=off, and the built-in
# Codex gpt-5.6-luna medium profile. `evidence` executes a regression command
# and a focused-module command and records their result. `publish-pr` refuses
# until both passed, then opens and registers a direct PR. `broader` is run
# after publication while PR checks run concurrently. `ready` refuses until the
# broader command and all PR checks are green. `progress` prints only a changed
# actionable state for the watcher's Fast-Repair-only cadence.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fast-repair refused: %s\n' "$*" >&2
  exit 2
}

task_id_valid() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

field_get() { # <file> <field>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

request_valid() {
  case "$1" in
    fast-repair:\ ?*) return 0 ;;
    *) return 1 ;;
  esac
}

eligibility_file() { printf '%s/%s/fast-repair-eligibility\n' "$DATA" "$1"; }
tests_file() { printf '%s/%s.fast-repair-tests\n' "$STATE" "$1"; }

require_fast_repair_meta() {
  local id meta
  id=$1
  meta="$STATE/$id.meta"
  regular_file "$meta" || fail "task $id has no safe metadata record"
  [ "$(field_get "$meta" mode)" = fast-repair ] || fail "task $id is not a Fast Repair task"
  [ "$(field_get "$meta" fast_repair)" = eligible ] || fail "task $id has no eligible Fast Repair result"
}

eligibility_valid() {
  local id=$1 f request positive risk
  f=$(eligibility_file "$id")
  regular_file "$f" || return 1
  request=$(field_get "$f" request)
  request_valid "$request" || return 1
  for positive in reproduction root_cause isolation; do
    case "$(field_get "$f" "$positive")" in ''|unknown|ambiguous) return 1 ;; esac
  done
  for risk in schema authentication authorization secrets financial legal side_effects; do
    [ "$(field_get "$f" "$risk")" = none ] || return 1
  done
}

tests_passed() {
  local id=$1 f
  f=$(tests_file "$id")
  regular_file "$f" || return 1
  [ "$(field_get "$f" regression)" = passed ] && [ "$(field_get "$f" focused)" = passed ]
}

parse_url_number() {
  case "$1" in
    https://github.com/*/pull/[0-9]*) printf '%s\n' "${1##*/}" ;;
    *) return 1 ;;
  esac
}

pr_url_for() {
  local id meta url
  id=$1
  meta="$STATE/$id.meta"
  url=$(field_get "$meta" pr)
  parse_url_number "$url" >/dev/null || return 1
  printf '%s\n' "$url"
}

checks_summary() {
  local url=$1 number
  number=$(parse_url_number "$url") || return 1
  command -v gh-axi >/dev/null 2>&1 || return 1
  gh-axi pr checks "$number" 2>/dev/null | sed -n 's/^summary: *//p' | head -n 1
}

checks_state() { # <summary> -> green|failed|pending|unknown
  case "$1" in
    *'0 failed, 0 pending,'*) printf 'green\n' ;;
    *'0 failed,'*) printf 'pending\n' ;;
    *' failed,'*) printf 'failed\n' ;;
    *) printf 'unknown\n' ;;
  esac
}

command=${1:-}
[ -n "$command" ] || { usage >&2; exit 2; }
shift || true

case "$command" in
  -h|--help|help) usage; exit 0 ;;
  is-request)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    request_valid "$1"
    ;;
  intake)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    request=
    reproduction=
    root_cause=
    isolation=
    schema=
    authentication=
    authorization=
    secrets=
    financial=
    legal=
    side_effects=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs an explicit value"
      value=$1
      shift
      case "$key" in
        --request) request=$value ;;
        --reproduction) reproduction=$value ;;
        --root-cause) root_cause=$value ;;
        --isolation) isolation=$value ;;
        --schema) schema=$value ;;
        --authentication) authentication=$value ;;
        --authorization) authorization=$value ;;
        --secrets) secrets=$value ;;
        --financial) financial=$value ;;
        --legal) legal=$value ;;
        --side-effects) side_effects=$value ;;
        *) fail "unknown intake evidence flag $key" ;;
      esac
    done
    request_valid "$request" || fail "request does not use the exact 'fast-repair: ' prefix"
    for field in reproduction root_cause isolation; do
      eval "value=\${$field}"
      case "$value" in ''|unknown|ambiguous|false|no) fail "$field is absent, unknown, ambiguous, or not proven" ;; esac
      case "$value" in *$'\n'*|*$'\r'*) fail "$field must be one typed evidence value" ;; esac
    done
    for field in schema authentication authorization secrets financial legal side_effects; do
      eval "value=\${$field}"
      [ "$value" = none ] || fail "$field is not explicitly proven none"
    done
    dir="$DATA/$id"
    mkdir -p "$dir"
    tmp="$dir/.fast-repair-eligibility.$$"
    umask 077
    {
      printf 'request=%s\n' "$request"
      printf 'reproduction=%s\n' "$reproduction"
      printf 'root_cause=%s\n' "$root_cause"
      printf 'isolation=%s\n' "$isolation"
      printf 'schema=%s\n' "$schema"
      printf 'authentication=%s\n' "$authentication"
      printf 'authorization=%s\n' "$authorization"
      printf 'secrets=%s\n' "$secrets"
      printf 'financial=%s\n' "$financial"
      printf 'legal=%s\n' "$legal"
      printf 'side_effects=%s\n' "$side_effects"
    } > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$(eligibility_file "$id")"
    printf 'fast-repair eligible: %s\n' "$id"
    ;;
  eligible)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    if ! task_id_valid "$1" || ! eligibility_valid "$1"; then
      fail "eligibility evidence is absent, incomplete, or no longer valid for $1"
    fi
    printf 'fast-repair eligible: %s\n' "$1"
    ;;
  evidence)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    regression=
    focused=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs a command"
      value=$1
      shift
      case "$key" in
        --regression-command) regression=$value ;;
        --focused-command) focused=$value ;;
        *) fail "unknown test evidence flag $key" ;;
      esac
    done
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    [ -n "$regression" ] && [ -n "$focused" ] || fail "regression and focused commands are both required"
    mkdir -p "$STATE"
    log="$STATE/$id.fast-repair-tests.log"
    record="$STATE/.$id.fast-repair-tests.$$"
    umask 077
    if bash -lc "$regression" >"$log" 2>&1; then regression_result=passed; else regression_result=failed; fi
    if [ "$regression_result" = passed ] && bash -lc "$focused" >>"$log" 2>&1; then focused_result=passed; else focused_result=failed; fi
    {
      printf 'regression=%s\n' "$regression_result"
      printf 'focused=%s\n' "$focused_result"
    } > "$record"
    chmod 600 "$record"
    mv -f "$record" "$(tests_file "$id")"
    tests_passed "$id" || fail "regression or focused-module evidence failed; PR publication remains blocked"
    printf 'fast-repair focused evidence passed: %s\n' "$id"
    ;;
  publish-pr)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    title=
    body_file=
    base=
    head=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs a value"
      value=$1
      shift
      case "$key" in
        --title) title=$value ;;
        --body-file) body_file=$value ;;
        --base) base=$value ;;
        --head) head=$value ;;
        *) fail "unknown PR flag $key" ;;
      esac
    done
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    tests_passed "$id" || fail "focused evidence is absent or failed; direct PR publication is blocked"
    if [ -z "$title" ] || ! regular_file "$body_file"; then
      fail "a title and safe body file are required"
    fi
    args=(pr create --title "$title" --body-file "$body_file")
    [ -z "$base" ] || args+=(--base "$base")
    [ -z "$head" ] || args+=(--head "$head")
    out=$(gh-axi "${args[@]}") || exit $?
    printf '%s\n' "$out"
    url=$(printf '%s\n' "$out" | grep -Eo 'https://github\.com/[^[:space:]]+/pull/[0-9]+' | head -n 1 || true)
    [ -n "$url" ] || fail "PR creation returned no GitHub pull-request URL"
    "$SCRIPT_DIR/fm-pr-check.sh" "$id" "$url" >/dev/null
    printf 'fast-repair PR opened: %s\n' "$url"
    ;;
  broader)
    id=${1:-}
    shift || true
    task_id_valid "$id" || fail "task id is missing or invalid"
    [ "${1:-}" = --command ] && [ "$#" -eq 2 ] || fail "broader requires exactly --command <command>"
    broader_command=$2
    require_fast_repair_meta "$id"
    pr_url_for "$id" >/dev/null || fail "broader tests start only after the direct PR is registered"
    [ -n "$broader_command" ] || fail "broader command is empty"
    log="$STATE/$id.fast-repair-broader.log"
    record="$STATE/.$id.fast-repair-broader.$$"
    umask 077
    if bash -lc "$broader_command" >"$log" 2>&1; then result=passed; else result=failed; fi
    printf 'broader=%s\n' "$result" > "$record"
    chmod 600 "$record"
    mv -f "$record" "$STATE/$id.fast-repair-broader"
    [ "$result" = passed ] || fail "broader tests failed after PR publication; inspect $log and report the open PR as not green"
    printf 'fast-repair broader tests passed: %s\n' "$id"
    ;;
  progress)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$1
    require_fast_repair_meta "$id"
    if regular_file "$STATE/$id.fast-repair-broader" && [ "$(field_get "$STATE/$id.fast-repair-broader" broader)" = failed ]; then
      printf 'fast-repair %s broader-tests-failed\n' "$id"
      exit 0
    fi
    url=$(pr_url_for "$id" 2>/dev/null || true)
    [ -n "$url" ] || exit 0
    summary=$(checks_summary "$url" 2>/dev/null || true)
    state=$(checks_state "$summary")
    case "$state" in
      failed) printf 'fast-repair %s pr-checks-failed: %s\n' "$id" "$summary" ;;
      green) printf 'fast-repair %s pr-checks-green: %s\n' "$id" "$summary" ;;
    esac
    ;;
  ready)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$1
    require_fast_repair_meta "$id"
    tests_passed "$id" || fail "focused evidence is absent or failed"
    [ "$(field_get "$STATE/$id.fast-repair-broader" broader)" = passed ] || fail "broader tests are not passed"
    url=$(pr_url_for "$id") || fail "no registered Fast Repair PR"
    summary=$(checks_summary "$url") || fail "PR checks could not be read"
    [ "$(checks_state "$summary")" = green ] || fail "PR checks are not green: $summary"
    printf 'fast-repair ready: %s\n' "$url"
    ;;
  *) usage >&2; exit 2 ;;
esac
