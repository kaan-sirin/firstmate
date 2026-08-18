#!/usr/bin/env bash
# Behavior tests for the local worker-capacity admission guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-capacity)

# Source the guard with small deterministic backend probes. The guard's public
# interface consumes these same two backend functions from fm-backend.sh.
fm_backend_of_meta() { printf 'tmux'; }
fm_backend_target_of_meta() { sed -n 's/^window=//p' "$1" | tail -1; }
fm_backend_agent_state() {
  case "$2" in
    alive) printf alive ;;
    dead) printf dead ;;
    missing) printf missing ;;
    ambiguous) printf ambiguous ;;
    unreadable) printf unreadable ;;
    *) printf unverified ;;
  esac
}
. "$ROOT/bin/fm-worker-capacity-lib.sh"

make_meta() {
  local state=$1 id=$2 verdict=$3
  printf 'window=%s\n' "$verdict" > "$state/$id.meta"
}

test_absent_limit_is_unlimited() {
  local dir="$TMP_ROOT/absent"
  mkdir -p "$dir/config"
  [ "$(fm_worker_capacity_limit "$dir/config")" = 0 ] || fail "absent limit was not unlimited"
  pass "absent worker limit preserves compatibility"
}

test_valid_limit_and_malformed_values() {
  local dir="$TMP_ROOT/limit"
  mkdir -p "$dir/config"
  printf '2\n' > "$dir/config/max-active-workers"
  [ "$(fm_worker_capacity_limit "$dir/config")" = 2 ] || fail "valid worker limit was not read"
  printf '0\n' > "$dir/config/max-active-workers"
  fm_worker_capacity_limit "$dir/config" >/dev/null && fail "zero worker limit was accepted"
  printf '2\n3\n' > "$dir/config/max-active-workers"
  fm_worker_capacity_limit "$dir/config" >/dev/null && fail "multi-line worker limit was accepted"
  pass "worker limit accepts one bounded positive integer only"
}

test_only_proven_dead_workers_free_slots() {
  local state="$TMP_ROOT/state"
  mkdir -p "$state"
  make_meta "$state" alive-a alive
  make_meta "$state" dead-a dead
  make_meta "$state" missing-a missing
  make_meta "$state" ambiguous-a ambiguous
  make_meta "$state" unreadable-a unreadable
  make_meta "$state" unverified-a unverified
  [ "$(fm_worker_capacity_active "$state")" = 4 ] || fail "active count did not fail closed for uncertain endpoints"
  pass "only proven dead or missing workers free capacity"
}

test_spawn_refuses_when_capacity_is_full() {
  local dir="$TMP_ROOT/spawn" home fakebin out status
  dir="$TMP_ROOT/spawn"
  home="$dir/home"
  fakebin="$dir/fakebin"
  mkdir -p "$home/state" "$home/config" "$fakebin"
  printf '1\n' > "$home/config/max-active-workers"
  cat > "$home/state/worker.meta" <<'EOF'
window=firstmate:worker
endpoint_task_id=worker
worktree=/tmp
harness=codex
kind=ship
EOF
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *list-windows*) printf "%s\\n" worker ;;' \
    '  *pane_current_command*) printf "%s\\n" codex ;;' \
    '  *) : ;;' \
    'esac' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" candidate /unused codex --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn started despite a full worker limit"
  assert_contains "$out" "worker capacity reached (1/1 active)" "spawn refusal did not report the capacity state"
  pass "fm-spawn refuses a new worker when the configured limit is full"
}

test_absent_limit_is_unlimited
test_valid_limit_and_malformed_values
test_only_proven_dead_workers_free_slots
test_spawn_refuses_when_capacity_is_full
