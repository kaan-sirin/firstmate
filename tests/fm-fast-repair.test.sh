#!/usr/bin/env bash
# Behavior tests for the strict opt-in Fast Repair intake, evidence, and
# post-publication readiness gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FAST="$ROOT/bin/fm-fast-repair.sh"
TMP_ROOT=$(fm_test_tmproot fm-fast-repair)

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/data" "$home/state" "$home/config"
  printf '%s\n' "$home"
}

run_fast() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" "$FAST" "$@" 2>&1
}

intake() {
  local home=$1 id=$2 reproduction=${3-known-reproduction} root_cause=${4-confirmed-root-cause} isolation=${5-isolated-change}
  local schema=${6-none} authentication=${7-none} authorization=${8-none} secrets=${9-none} financial=${10-none} legal=${11-none} side_effects=${12-none}
  run_fast "$home" intake "$id" --request 'fast-repair: repair fixture' \
    --reproduction "$reproduction" --root-cause "$root_cause" --isolation "$isolation" \
    --schema "$schema" --authentication "$authentication" --authorization "$authorization" \
    --secrets "$secrets" --financial "$financial" --legal "$legal" --side-effects "$side_effects"
}

write_fast_meta() {
  local home=$1 id=$2 pr=${3:-}
  {
    printf 'window=firstmate:fm-%s\n' "$id"
    printf 'kind=ship\nmode=fast-repair\nyolo=off\nfast_repair=eligible\n'
    [ -z "$pr" ] || printf 'pr=%s\n' "$pr"
  } > "$home/state/$id.meta"
}

test_exact_prefix_only() {
  local request
  for request in 'fast-repair: fix fixture' 'fast-repair: a'; do
    "$FAST" is-request "$request" || fail "exact Fast Repair prefix was not recognized: $request"
  done
  for request in 'fast-repair:' 'Fast-repair: fix' 'fast repair: fix' 'fast-repair : fix' 'xfast-repair: fix'; do
    "$FAST" is-request "$request" && fail "near-match activated Fast Repair: $request"
  done
  pass "Fast Repair recognizes only the exact fast-repair: prefix"
}

test_eligibility_requires_every_typed_fact() {
  local home out status field id=eligible-all
  home=$(make_home eligibility)
  out=$(intake "$home" "$id")
  assert_contains "$out" "fast-repair eligible: $id" "complete typed eligibility did not pass"
  run_fast "$home" eligible "$id" >/dev/null || fail "stored complete eligibility did not validate"

  for field in reproduction root_cause isolation; do
    id="missing-$field"
    case "$field" in
      reproduction) out=$(intake "$home" "$id" '' confirmed-root-cause isolated-change) ;;
      root_cause) out=$(intake "$home" "$id" known-reproduction '' isolated-change) ;;
      isolation) out=$(intake "$home" "$id" known-reproduction confirmed-root-cause '') ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "missing $field was accepted"
    assert_contains "$out" "$field" "missing $field did not name its refusal"

    id="unknown-$field"
    case "$field" in
      reproduction) out=$(intake "$home" "$id" unknown confirmed-root-cause isolated-change) ;;
      root_cause) out=$(intake "$home" "$id" known-reproduction unknown isolated-change) ;;
      isolation) out=$(intake "$home" "$id" known-reproduction confirmed-root-cause ambiguous) ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "unknown or ambiguous $field was accepted"
    assert_contains "$out" "$field" "unknown $field did not name its refusal"
  done

  for field in schema authentication authorization secrets financial legal side_effects; do
    id="risk-$field"
    case "$field" in
      schema) out=$(intake "$home" "$id" a b c changed) ;;
      authentication) out=$(intake "$home" "$id" a b c none changed) ;;
      authorization) out=$(intake "$home" "$id" a b c none none changed) ;;
      secrets) out=$(intake "$home" "$id" a b c none none none changed) ;;
      financial) out=$(intake "$home" "$id" a b c none none none none changed) ;;
      legal) out=$(intake "$home" "$id" a b c none none none none none changed) ;;
      side_effects) out=$(intake "$home" "$id" a b c none none none none none none changed) ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "forbidden $field change was accepted"
    assert_contains "$out" "$field" "forbidden $field did not name its refusal"
  done
  pass "Fast Repair accepts only complete positive evidence and explicit no-risk exclusions"
}

test_evidence_and_ready_gates() {
  local home id=gate-fixture out status fakebin
  home=$(make_home gates)
  intake "$home" "$id" >/dev/null
  write_fast_meta "$home" "$id"

  out=$(run_fast "$home" evidence "$id" --regression-command false --focused-command true)
  status=$?
  [ "$status" -ne 0 ] || fail "failed regression evidence allowed publication"
  assert_contains "$out" "PR publication remains blocked" "failed evidence did not explain the publication block"

  run_fast "$home" evidence "$id" --regression-command true --focused-command true >/dev/null || fail "passing focused evidence was rejected"
  fakebin="$home/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pr)
    case "${2:-}" in
      create) printf 'https://github.com/acme/repo/pull/42\n' ;;
      checks) printf 'summary: "4 passed, 0 failed, 0 pending, 4 total"\n' ;;
    esac
    ;;
esac
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/gh-axi"
  chmod +x "$fakebin/gh"
  printf 'Fast Repair fixture body.\n' > "$home/body.md"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" publish-pr "$id" --title 'Fast Repair fixture' --body-file "$home/body.md")
  assert_contains "$out" 'fast-repair PR opened: https://github.com/acme/repo/pull/42' "passing evidence did not open the direct PR"
  assert_grep 'pr=https://github.com/acme/repo/pull/42' "$home/state/$id.meta" "direct PR was not registered"
  PATH="$fakebin:$PATH" run_fast "$home" broader "$id" --command true >/dev/null || fail "broader tests could not start after direct PR publication"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" ready "$id")
  assert_contains "$out" 'fast-repair ready: https://github.com/acme/repo/pull/42' "green broader and PR evidence did not make the PR ready"
  out=$(PATH="$fakebin:$PATH" run_fast "$home" progress "$id")
  assert_contains "$out" 'pr-checks-green' "green PR checks were not available to the Fast Repair progress cadence"
  pass "Fast Repair blocks failed focused evidence and requires broader plus PR checks before ready"
}

test_exact_prefix_only
test_eligibility_requires_every_typed_fact
test_evidence_and_ready_gates
echo "# all fm-fast-repair tests passed"
