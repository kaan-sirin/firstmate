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
fm_meta_get() { sed -n "s/^$2=//p" "$1" | tail -1; }
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
# shellcheck source=bin/fm-config-inherit-lib.sh
. "$ROOT/bin/fm-config-inherit-lib.sh"

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
  printf '2' > "$dir/config/max-active-workers"
  fm_worker_capacity_limit "$dir/config" >/dev/null && fail "unterminated worker limit was accepted"
  printf '2\n\n' > "$dir/config/max-active-workers"
  fm_worker_capacity_limit "$dir/config" >/dev/null && fail "blank extra line in worker limit was accepted"
  printf '2\n3\n' > "$dir/config/max-active-workers"
  fm_worker_capacity_limit "$dir/config" >/dev/null && fail "multi-line worker limit was accepted"
  pass "worker limit accepts one newline-terminated positive integer only"
}

test_unsafe_config_directory_refuses_limit_lookup() {
  local dir="$TMP_ROOT/config-directory"
  mkdir -p "$dir/real-config"
  printf '1\n' > "$dir/real-config/max-active-workers"
  ln -s "$dir/real-config" "$dir/linked-config"
  fm_worker_capacity_limit "$dir/linked-config" >/dev/null \
    && fail "symlinked config directory was accepted"
  printf 'not a directory\n' > "$dir/config-file"
  fm_worker_capacity_limit "$dir/config-file" >/dev/null \
    && fail "non-directory config path was accepted"
  [ "$(fm_worker_capacity_limit "$dir/absent-config")" = 0 ] \
    || fail "absent config directory did not preserve unlimited behavior"
  pass "worker limit refuses unsafe config directories"
}

test_inherited_limit_rejects_unsafe_endpoints() {
  local dir="$TMP_ROOT/inherit" source destination source_link destination_link
  dir="$TMP_ROOT/inherit"
  source="$dir/source"
  destination="$dir/destination"
  mkdir -p "$source" "$destination"
  printf '1\n' > "$source/max-active-workers"
  FM_INHERITABLE_CONFIG=max-active-workers \
    propagate_inheritable_config "$source" "$destination" \
    || fail "valid worker limit did not inherit"
  [ "$(fm_worker_capacity_limit "$destination")" = 1 ] \
    || fail "inherited worker limit was not usable"

  source_link="$dir/source-link"
  printf '2\n' > "$source_link"
  rm -f "$source/max-active-workers"
  ln "$source_link" "$source/max-active-workers"
  FM_INHERITABLE_CONFIG=max-active-workers \
    propagate_inheritable_config "$source" "$destination" \
    && fail "hard-linked source worker limit was inherited"
  [ "$(fm_worker_capacity_limit "$destination")" = 1 ] \
    || fail "unsafe source changed the inherited worker limit"

  rm -f "$source/max-active-workers"
  printf '2\n' > "$source/max-active-workers"
  destination_link="$dir/destination-link"
  ln "$destination/max-active-workers" "$destination_link"
  FM_INHERITABLE_CONFIG=max-active-workers \
    propagate_inheritable_config "$source" "$destination" \
    && fail "hard-linked destination worker limit was overwritten"
  [ "$(<"$destination/max-active-workers")" = 1 ] \
    || fail "unsafe destination changed the worker limit"
  pass "worker limit inheritance rejects unsafe source and destination"
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

test_local_secondmate_uses_primary_host_capacity() {
  local dir="$TMP_ROOT/host-capacity" primary child fakebin out status
  dir="$TMP_ROOT/host-capacity"
  primary="$dir/primary"
  child="$dir/child"
  fakebin="$dir/fakebin"
  mkdir -p "$primary/state" "$primary/config" "$child/state" "$child/config" "$fakebin"
  printf 'secondmate\n' > "$child/.fm-secondmate-home"
  printf '%s\n' \
    'schema=fm-secondmate-parent.v1' \
    'route=local' \
    "parent_home=$primary" > "$child/.fm-secondmate-parent"
  printf '1\n' > "$primary/config/max-active-workers"
  printf '1\n' > "$child/config/max-active-workers"
  cat > "$primary/state/secondmate.meta" <<EOF
window=firstmate:secondmate
endpoint_task_id=secondmate
home=$child
kind=secondmate
EOF
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *list-windows*) printf "%s\\n" secondmate ;;' \
    '  *pane_current_command*) printf "%s\\n" codex ;;' \
    '  *) : ;;' \
    'esac' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$child" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" candidate /unused codex --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "secondmate started despite a full primary host limit"
  assert_contains "$out" "worker capacity reached (1/1 active)" "secondmate did not use the primary host capacity"
  pass "local secondmates share the primary host worker capacity"
}

test_remote_secondmate_uses_parent_route_capacity() {
  local dir="$TMP_ROOT/remote-host-capacity" home route fakebin out status
  dir="$TMP_ROOT/remote-host-capacity"
  home="$dir/home"
  route="$home/state/parent-route"
  fakebin="$dir/fakebin"
  mkdir -p "$route" "$home/config" "$fakebin"
  printf 'remote-secondmate\n' > "$home/.fm-secondmate-home"
  printf '%s\n' \
    'schema=fm-secondmate-parent.v1' \
    'route=remote' > "$home/.fm-secondmate-parent"
  printf '1\n' > "$home/config/max-active-workers"
  cat > "$route/remote-secondmate.meta" <<EOF
window=firstmate:remote-secondmate
endpoint_task_id=remote-secondmate
home=$home
kind=secondmate
EOF
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '  *list-windows*) printf "%s\\n" remote-secondmate ;;' \
    '  *pane_current_command*) printf "%s\\n" codex ;;' \
    '  *) : ;;' \
    'esac' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" candidate /unused codex --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "remote secondmate started despite a full parent-route limit"
  assert_contains "$out" "worker capacity reached (1/1 active)" "remote secondmate did not use parent-route capacity"
  pass "remote secondmates share their parent-route worker capacity"
}

make_pending_launch_fakebin() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *'#{pane_current_command}'*)
    if [ -e "$FM_AGENT_READY" ]; then printf 'codex\n'; else printf 'bash\n'; fi
    exit 0
    ;;
  *'#{pane_id}'*) printf '@fake\n'; exit 0 ;;
  *'#S'*) printf 'firstmate\n'; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    for meta in "$FM_FAKE_STATE"/*.meta; do
      [ -f "$meta" ] || continue
      printf 'fm-%s\n' "$(basename "$meta" .meta)"
    done
    ;;
  new-window) printf '@fake\n' ;;
  send-keys)
    case "$*" in
      *'fm-first'*)
        if [ "$#" -eq 4 ] && [ "${4:-}" = Enter ]; then
          : > "$FM_ENTER_SENT"
          [ "${FM_TERMINATE_AFTER_ENTER:-0}" != 1 ] || kill -TERM "$PPID"
        fi
        ;;
    esac
    ;;
esac
EOF
  chmod +x "$fakebin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/treehouse"
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_pending_launch_spawn() {
  local home=$1 project=$2 worktree=$3 fakebin=$4 id=$5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_STATE="$home/state" \
    FM_FAKE_PANE_PATH="$worktree" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$project" codex --mode no-mistakes --yolo off
}

run_capacity_relaunch() {
  local home=$1 worktree=$2 fakebin=$3 id=$4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_STATE="$home/state" \
    FM_FAKE_PANE_PATH="$worktree" TMUX='fake,1,0' PATH="$fakebin:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" --relaunch
}

test_relaunch_respects_worker_capacity() {
  local dir="$TMP_ROOT/relaunch" home project worktree fakebin out status
  dir="$TMP_ROOT/relaunch"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  mkdir -p "$home/state" "$home/config" "$home/data/old" "$home/projects"
  printf '1\n' > "$home/config/max-active-workers"
  printf 'old brief\n' > "$home/data/old/brief.md"
  git init -q -b main "$project"
  git -C "$project" -c user.name=tests -c user.email=tests@example.invalid commit -q --allow-empty -m init
  git clone -q --bare "$project" "$dir/origin.git"
  git -C "$project" remote add origin "file://$dir/origin.git"
  git -C "$project" worktree add -q --detach "$worktree"
  cat > "$home/state/old.meta" <<EOF
window=firstmate:fm-old
endpoint_task_id=old
worktree=$worktree
project=$project
harness=codex
kind=ship
mode=no-mistakes
yolo=off
EOF
  cat > "$home/state/live.meta" <<EOF
window=firstmate:fm-live
endpoint_task_id=live
worktree=$worktree
project=$project
harness=codex
kind=ship
mode=no-mistakes
yolo=off
EOF
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
  *'#{pane_current_path}'*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *'#{pane_current_command}'*)
    case "$*" in *firstmate:fm-old*) printf 'bash\n' ;; *) printf 'codex\n' ;; esac
    exit 0
    ;;
  *'#{pane_id}'*) printf '@fake\n'; exit 0 ;;
  *'#S'*) printf 'firstmate\n'; exit 0 ;;
esac
case "${1:-}" in
  list-windows)
    for meta in "$FM_FAKE_STATE"/*.meta; do
      [ -f "$meta" ] || continue
      printf 'fm-%s\n' "$(basename "$meta" .meta)"
    done
    ;;
  new-window) printf '@fake\n' ;;
esac
EOF
  chmod +x "$fakebin/tmux"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fakebin/treehouse"
  chmod +x "$fakebin/treehouse"

  out=$(run_capacity_relaunch "$home" "$worktree" "$fakebin" old 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "relaunch started despite a full worker limit"
  assert_contains "$out" "worker capacity reached (1/1 active)" "relaunch refusal did not report the capacity state"
  pass "fm-spawn applies worker capacity to relaunches"
}

test_post_enter_launch_keeps_capacity_reserved() {
  local dir="$TMP_ROOT/pending" home project worktree fakebin first_pid out status i
  dir="$TMP_ROOT/pending"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  mkdir -p "$home/state" "$home/config" "$home/data/first" "$home/data/second" "$home/projects"
  printf '1\n' > "$home/config/max-active-workers"
  printf 'first brief\n' > "$home/data/first/brief.md"
  printf 'second brief\n' > "$home/data/second/brief.md"
  git init -q -b main "$project"
  git -C "$project" -c user.name=tests -c user.email=tests@example.invalid commit -q --allow-empty -m init
  git clone -q --bare "$project" "$dir/origin.git"
  git -C "$project" remote add origin "file://$dir/origin.git"
  git -C "$project" worktree add -q --detach "$worktree"
  fakebin=$(make_pending_launch_fakebin "$dir")

  FM_ENTER_SENT="$dir/enter-sent" FM_AGENT_READY="$dir/agent-ready" \
    run_pending_launch_spawn "$home" "$project" "$worktree" "$fakebin" first > "$dir/first.out" 2>&1 &
  first_pid=$!
  for i in $(seq 1 100); do
    [ -e "$dir/enter-sent" ] && break
    sleep 0.05
  done
  [ -e "$dir/enter-sent" ] || fail "first spawn did not submit the launch command"

  out=$(FM_ENTER_SENT="$dir/enter-sent" FM_AGENT_READY="$dir/agent-ready" \
    run_pending_launch_spawn "$home" "$project" "$worktree" "$fakebin" second 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "second spawn started while first launch was pending"
  assert_absent "$home/state/second.meta" "pending launch admitted a second worker"

  : > "$dir/agent-ready"
  wait "$first_pid"
  status=$?
  [ "$status" -eq 0 ] || fail "first spawn did not finish after launch was allowed"
  pass "post-Enter launch keeps its worker capacity reservation"
}

test_interrupted_submit_keeps_capacity_reserved() {
  local dir="$TMP_ROOT/interrupted" home project worktree fakebin first_pid out status i
  dir="$TMP_ROOT/interrupted"
  home="$dir/home"
  project="$dir/project"
  worktree="$dir/worktree"
  mkdir -p "$home/state" "$home/config" "$home/data/first" "$home/data/second" "$home/projects"
  printf '1\n' > "$home/config/max-active-workers"
  printf 'first brief\n' > "$home/data/first/brief.md"
  printf 'second brief\n' > "$home/data/second/brief.md"
  git init -q -b main "$project"
  git -C "$project" -c user.name=tests -c user.email=tests@example.invalid commit -q --allow-empty -m init
  git clone -q --bare "$project" "$dir/origin.git"
  git -C "$project" remote add origin "file://$dir/origin.git"
  git -C "$project" worktree add -q --detach "$worktree"
  fakebin=$(make_pending_launch_fakebin "$dir")

  FM_ENTER_SENT="$dir/enter-sent" FM_AGENT_READY="$dir/agent-ready" FM_TERMINATE_AFTER_ENTER=1 \
    run_pending_launch_spawn "$home" "$project" "$worktree" "$fakebin" first > "$dir/first.out" 2>&1 &
  first_pid=$!
  for i in $(seq 1 100); do
    [ -e "$dir/enter-sent" ] && break
    sleep 0.05
  done
  [ -e "$dir/enter-sent" ] || fail "first spawn did not submit before interruption"
  wait "$first_pid" || true

  out=$(FM_ENTER_SENT="$dir/enter-sent" FM_AGENT_READY="$dir/agent-ready" \
    run_pending_launch_spawn "$home" "$project" "$worktree" "$fakebin" second 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "second spawn started after submit interruption"
  assert_absent "$home/state/second.meta" "submit interruption admitted a second worker"
  pass "interrupted submit keeps its worker capacity reservation"
}

test_absent_limit_is_unlimited
test_valid_limit_and_malformed_values
test_unsafe_config_directory_refuses_limit_lookup
test_inherited_limit_rejects_unsafe_endpoints
test_only_proven_dead_workers_free_slots
test_spawn_refuses_when_capacity_is_full
test_local_secondmate_uses_primary_host_capacity
test_remote_secondmate_uses_parent_route_capacity
test_relaunch_respects_worker_capacity
test_post_enter_launch_keeps_capacity_reserved
test_interrupted_submit_keeps_capacity_reserved
