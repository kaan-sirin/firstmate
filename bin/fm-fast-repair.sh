#!/usr/bin/env bash
# Manage the strict opt-in Fast Repair delivery path.
# Usage:
#   fm-fast-repair.sh is-request <request>
#   fm-fast-repair.sh intake <task-id> --request 'fast-repair: <task>' \
#     --reproduction reproduced --root-cause confirmed --isolation isolated \
#     --schema none --authentication none --authorization none --secrets none \
#     --financial none --legal none --side-effects none
#   fm-fast-repair.sh eligible <task-id>
#   fm-fast-repair.sh evidence <task-id> --regression-test <relative-executable-test> --focused-test <relative-executable-test>
#   fm-fast-repair.sh publish-pr <task-id> --title <text> --body-file <path> [--base <branch>] [--head <branch>]
#   fm-fast-repair.sh broader <task-id> --command <command>
#   fm-fast-repair.sh progress <task-id>
#   fm-fast-repair.sh ready <task-id>
#
# `fast-repair:` is the only accepted request prefix, and it must be followed by
# one space and a non-empty request. `intake` records a typed, private evidence
# record only when all three positive facts use their exact proof values and all
# seven risk exclusions equal `none`. Any missing or different value
# refuses Fast Repair before a task can use this delivery mode; firstmate then
# uses normal intake for that request.
#
# A Fast Repair spawn must use mode=fast-repair, yolo=off, and the built-in
# Codex gpt-5.6-luna medium profile. `evidence` executes named regression and
# focused-module tests directly and records their result. `publish-pr` refuses
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
TASK_WORKTREE=
TASK_BRANCH=
TASK_HEAD=

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

fail() {
  printf 'fast-repair refused: %s\n' "$*" >&2
  exit 2
}

task_id_valid() {
  fm_task_id_creation_valid "$1"
}

regular_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

task_worktree_for() {
  local meta worktree root
  meta="$STATE/$1.meta"
  regular_file "$meta" || return 1
  worktree=$(field_get "$meta" worktree)
  [ -n "$worktree" ] && [ -d "$worktree" ] || return 1
  root=$(git -C "$worktree" rev-parse --show-toplevel 2>/dev/null) || return 1
  root=$(cd "$root" && pwd -P) || return 1
  [ "$root" = "$(cd "$worktree" && pwd -P)" ] || return 1
  TASK_WORKTREE=$root
}

task_revision_for() {
  task_worktree_for "$1" || return 1
  TASK_BRANCH=$(git -C "$TASK_WORKTREE" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  TASK_HEAD=$(git -C "$TASK_WORKTREE" rev-parse --verify HEAD 2>/dev/null) || return 1
}

# Evidence logs and records are private to this home. The umask is scoped to the
# creation itself so it never reaches the caller-supplied test commands, whose
# own output files must keep the permissions their build or suite intends.
private_truncate() { # <path>
  ( umask 077; : > "$1" ) && chmod 600 "$1"
}

private_write() { # <path>, content on stdin
  ( umask 077; cat > "$1" ) && chmod 600 "$1"
}

field_get() { # <file> <field>
  sed -n "s/^$2=//p" "$1" | head -n 1
}

request_valid() {
  case "$1" in
    fast-repair:\ ?*) ;;
    *) return 1 ;;
  esac
  case "$1" in *$'\n'*|*$'\r'*) return 1 ;; esac
}

# The one rule for a proven positive fact and for an excluded risk. intake
# writes a record only when these hold, and every later gate re-checks the
# stored record against these same predicates, so a record can never satisfy a
# consumer that intake itself would have refused.
positive_fact_valid() { # <field> <value>
  case "$1:$2" in
    reproduction:reproduced|root_cause:confirmed|isolation:isolated) return 0 ;;
    *) return 1 ;;
  esac
}

risk_excluded() { [ "$1" = none ]; }

test_path_valid() {
  local path=$1 parent resolved
  case "$path" in
    ''|/*|.|..|../*|*/../*|*'/..'|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$TASK_WORKTREE" ] || return 1
  parent=$(dirname "$TASK_WORKTREE/$path")
  resolved=$(cd "$parent" 2>/dev/null && pwd -P) || return 1
  resolved="$resolved/$(basename "$path")"
  case "$resolved" in "$TASK_WORKTREE"/*) ;; *) return 1 ;; esac
  regular_file "$resolved" && [ -x "$resolved" ]
}

regression_test_valid() { test_path_valid "$1"; }
focused_test_valid() { test_path_valid "$1"; }

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
  [ "$(wc -l < "$f" | tr -d '[:space:]')" = 11 ] || return 1
  request=$(field_get "$f" request)
  request_valid "$request" || return 1
  [ "$(grep -c '^request=' "$f")" = 1 ] || return 1
  for positive in reproduction root_cause isolation; do
    positive_fact_valid "$positive" "$(field_get "$f" "$positive")" || return 1
    [ "$(grep -c "^$positive=" "$f")" = 1 ] || return 1
  done
  for risk in schema authentication authorization secrets financial legal side_effects; do
    risk_excluded "$(field_get "$f" "$risk")" || return 1
    [ "$(grep -c "^$risk=" "$f")" = 1 ] || return 1
  done
}

tests_passed() {
  local id=$1 f regression_test focused_test worktree branch head
  f=$(tests_file "$id")
  regular_file "$f" || return 1
  task_revision_for "$id" || return 1
  regression_test=$(field_get "$f" regression_test)
  focused_test=$(field_get "$f" focused_test)
  worktree=$(field_get "$f" worktree)
  branch=$(field_get "$f" branch)
  head=$(field_get "$f" head)
  regression_test_valid "$regression_test" || return 1
  focused_test_valid "$focused_test" || return 1
  [ "$worktree" = "$TASK_WORKTREE" ] || return 1
  [ "$branch" = "$TASK_BRANCH" ] || return 1
  [ "$head" = "$TASK_HEAD" ] || return 1
  [ "$(wc -l < "$f" | tr -d '[:space:]')" = 7 ] || return 1
  [ "$(grep -c '^regression=passed$' "$f")" = 1 ] || return 1
  [ "$(grep -c '^focused=passed$' "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "regression_test=$regression_test" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "focused_test=$focused_test" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "worktree=$worktree" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "branch=$branch" "$f")" = 1 ] || return 1
  [ "$(grep -Fxc "head=$head" "$f")" = 1 ]
}

broader_passed() {
  local f="$STATE/$1.fast-repair-broader"
  regular_file "$f" || return 1
  [ "$(field_get "$f" broader)" = passed ]
}

# The recorded pr= URL is re-parsed with the shared strict forge validator, so
# the repository and number always come from that one canonical record instead
# of from the caller's working directory. Fast Repair publishes through
# gh-axi, so only a GitHub pull request can be read here. On success the
# FM_PR_* identity of the shared parser is set for the caller.
pr_identity_for() {
  local meta url
  meta="$STATE/$1.meta"
  regular_file "$meta" || return 1
  url=$(field_get "$meta" pr)
  fm_pr_url_parse "$url" || return 1
  [ "$FM_PR_PROVIDER" = github ]
}

checks_summary() { # <number> <owner/repo>
  local raw
  command -v gh-axi >/dev/null 2>&1 || return 1
  raw=$(gh-axi pr checks "$1" --repo "$2" 2>/dev/null | sed -n 's/^summary: *//p' | head -n 1)
  # gh-axi renders its fields as TOON, which double-quotes every value holding a
  # comma, so the rollup summary always arrives quoted.
  case "$raw" in
    '"'*'"') raw=${raw#\"}; raw=${raw%\"} ;;
  esac
  printf '%s\n' "$raw"
}

# gh-axi renders the rollup as ["<n> passed","<n> failed", "<n> skipped" when
# non-zero, "<n> pending" when non-zero, "<n> total"], so a green PR omits the
# pending segment entirely and a substring test on the rendered string both
# misses green and reads "10 failed, 0 pending" as green. The counts are
# therefore extracted and compared numerically, and any segment, label, or
# total this does not recognize stays unknown rather than becoming green.
#
# gh-axi's own classifier folds SKIPPED, CANCELLED, EXPECTED and NEUTRAL-state
# runs into one "skipped" count, so a cancelled workflow is indistinguishable
# from a deliberately skipped job. A partial skip alongside real passes is
# ordinary CI and stays green, but a rollup where nothing passed at all has
# proven nothing and is never green.
checks_state() { # <summary> -> green|failed|pending|unknown
  local rest=${1-} part count label
  local passed='' failed='' total='' skipped=0 pending=0
  [ -n "$rest" ] || { printf 'unknown\n'; return 0; }
  while [ -n "$rest" ]; do
    case "$rest" in
      *', '*) part=${rest%%, *}; rest=${rest#*, } ;;
      *) part=$rest; rest= ;;
    esac
    case "$part" in *' '*) ;; *) printf 'unknown\n'; return 0 ;; esac
    count=${part%% *}
    label=${part#* }
    case "$count" in ''|*[!0-9]*) printf 'unknown\n'; return 0 ;; esac
    case "$label" in
      passed) passed=$count ;;
      failed) failed=$count ;;
      skipped) skipped=$count ;;
      pending) pending=$count ;;
      total) total=$count ;;
      *) printf 'unknown\n'; return 0 ;;
    esac
  done
  [ -n "$passed" ] && [ -n "$failed" ] && [ -n "$total" ] || { printf 'unknown\n'; return 0; }
  [ "$total" -gt 0 ] || { printf 'unknown\n'; return 0; }
  [ "$((passed + failed + skipped + pending))" -eq "$total" ] || { printf 'unknown\n'; return 0; }
  if [ "$failed" -gt 0 ]; then
    printf 'failed\n'
  elif [ "$pending" -gt 0 ]; then
    printf 'pending\n'
  elif [ "$passed" -eq 0 ]; then
    printf 'unknown\n'
  else
    printf 'green\n'
  fi
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
      positive_fact_valid "$field" "$value" \
        || fail "$field must equal its exact typed proof value"
    done
    for field in schema authentication authorization secrets financial legal side_effects; do
      eval "value=\${$field}"
      risk_excluded "$value" || fail "$field is not explicitly proven none"
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
    regression_test=
    focused_test=
    while [ "$#" -gt 0 ]; do
      key=$1
      shift
      [ "$#" -gt 0 ] || fail "$key needs a value"
      value=$1
      shift
      case "$key" in
        --regression-test) regression_test=$value ;;
        --focused-test) focused_test=$value ;;
        *) fail "unknown test evidence flag $key" ;;
      esac
    done
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    task_revision_for "$id" || fail "task $id has no safe git worktree at its metadata path"
    regression_test_valid "$regression_test" \
      || fail "regression-test must name an executable regular test file below the current worktree"
    focused_test_valid "$focused_test" \
      || fail "focused-test must name an executable regular test file below the current worktree"
    mkdir -p "$STATE"
    log="$STATE/$id.fast-repair-tests.log"
    record="$STATE/.$id.fast-repair-tests.$$"
    private_truncate "$log" || fail "the evidence log could not be created"
    if ( cd "$TASK_WORKTREE" && "./$regression_test" ) >>"$log" 2>&1; then regression_result=passed; else regression_result=failed; fi
    if [ "$regression_result" = passed ] && ( cd "$TASK_WORKTREE" && "./$focused_test" ) >>"$log" 2>&1; then focused_result=passed; else focused_result=failed; fi
    {
      printf 'regression=%s\n' "$regression_result"
      printf 'regression_test=%s\n' "$regression_test"
      printf 'focused=%s\n' "$focused_result"
      printf 'focused_test=%s\n' "$focused_test"
      printf 'worktree=%s\n' "$TASK_WORKTREE"
      printf 'branch=%s\n' "$TASK_BRANCH"
      printf 'head=%s\n' "$TASK_HEAD"
    } | private_write "$record" || fail "the evidence record could not be written"
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
    [ -z "$head" ] || [ "$head" = "$TASK_BRANCH" ] \
      || fail "--head must equal the tested task branch $TASK_BRANCH"
    if [ -z "$title" ] || ! regular_file "$body_file"; then
      fail "a title and safe body file are required"
    fi
    args=(pr create --title "$title" --body-file "$body_file")
    [ -z "$base" ] || args+=(--base "$base")
    args+=(--head "$TASK_BRANCH")
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
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    pr_identity_for "$id" || fail "broader tests start only after the direct PR is registered"
    [ -n "$broader_command" ] || fail "broader command is empty"
    log="$STATE/$id.fast-repair-broader.log"
    record="$STATE/.$id.fast-repair-broader.$$"
    private_truncate "$log" || fail "the broader-test log could not be created"
    if bash -c "$broader_command" >>"$log" 2>&1; then result=passed; else result=failed; fi
    printf 'broader=%s\n' "$result" | private_write "$record" \
      || fail "the broader-test record could not be written"
    mv -f "$record" "$STATE/$id.fast-repair-broader"
    [ "$result" = passed ] || fail "broader tests failed after PR publication; inspect $log and report the open PR as not green"
    printf 'fast-repair broader tests passed: %s\n' "$id"
    ;;
  progress)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$1
    task_id_valid "$id" || fail "task id is missing or invalid"
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    if regular_file "$STATE/$id.fast-repair-broader" && [ "$(field_get "$STATE/$id.fast-repair-broader" broader)" = failed ]; then
      printf 'fast-repair %s broader-tests-failed\n' "$id"
      exit 0
    fi
    pr_identity_for "$id" 2>/dev/null || exit 0
    summary=$(checks_summary "$FM_PR_NUMBER" "$FM_PR_OWNER/$FM_PR_REPO" 2>/dev/null || true)
    state=$(checks_state "$summary")
    case "$state" in
      failed) printf 'fast-repair %s pr-checks-failed: %s\n' "$id" "$summary" ;;
      green) printf 'fast-repair %s pr-checks-green: %s\n' "$id" "$summary" ;;
    esac
    ;;
  ready)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    id=$1
    task_id_valid "$id" || fail "task id is missing or invalid"
    require_fast_repair_meta "$id"
    eligibility_valid "$id" || fail "eligibility evidence is absent or invalid"
    tests_passed "$id" || fail "focused evidence is absent or failed"
    broader_passed "$id" || fail "broader tests are not passed"
    pr_identity_for "$id" || fail "no registered Fast Repair PR"
    summary=$(checks_summary "$FM_PR_NUMBER" "$FM_PR_OWNER/$FM_PR_REPO") || fail "PR checks could not be read"
    [ -n "$summary" ] || fail "PR checks could not be read"
    [ "$(checks_state "$summary")" = green ] || fail "PR checks are not green: $summary"
    printf 'fast-repair ready: %s (%s)\n' "$FM_PR_URL" "$summary"
    ;;
  *) usage >&2; exit 2 ;;
esac
