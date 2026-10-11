#!/usr/bin/env bash
# Executable spawn regression: recorded ownership wins over allocator output,
# process liveness, clean Git status, symlinks and native lease expiration.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-ownership)

make_case() {
  local name=$1
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/project"
  OWNED="$CASE_DIR/pool/1/project"
  FREE="$CASE_DIR/pool/2/project"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" newcomer
  fm_git_worktree "$PROJECT_DIR" "$OWNED" owner-branch
  git -C "$PROJECT_DIR" worktree add -q --detach "$FREE"
  FAKEBIN=$(make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_fake_sleep_noop "$FAKEBIN"
  printf 'worktree=%s\nproject=%s\nwindow=firstmate:fm-owner\nharness=agy\nkind=ship\n' \
    "$OWNED" "$PROJECT_DIR" > "$HOME_DIR/state/owner.meta"
  cp "$HOME_DIR/state/owner.meta" "$CASE_DIR/owner.before"
}

run_spawn() {
  FM_FAKE_LAUNCH_LOG="$CASE_DIR/launch.log" \
    fm_test_run_spawn "$HOME_DIR" "$1" "$FAKEBIN" newcomer "$PROJECT_DIR" --mode no-mistakes --yolo off
}

assert_owner_preserved() {
  cmp -s "$CASE_DIR/owner.before" "$HOME_DIR/state/owner.meta" || fail 'owner metadata changed'
  [ ! -e "$HOME_DIR/state/newcomer.meta" ] || fail 'collision published newcomer metadata'
  [ ! -s "$CASE_DIR/launch.log" ] || fail 'collision launched a worker'
  [ "$(git -C "$OWNED" rev-parse HEAD)" = "$OWNER_SHA" ] || fail 'collision reset owner HEAD'
  [ "$(git -C "$OWNED" branch --show-current)" = owner-branch ] || fail 'collision changed owner branch'
}

test_collision_before_refresh() {
  local form out rc
  for form in direct alias ancestor duplicate; do
    make_case "$form"
    printf 'unpublished\n' > "$OWNED/work.txt"
    git -C "$OWNED" add work.txt
    git -C "$OWNED" -c user.name=Test -c user.email=test@example.invalid commit -qm unpublished
    OWNER_SHA=$(git -C "$OWNED" rev-parse HEAD)
    case "$form" in
      alias)
        ln -s "$OWNED" "$CASE_DIR/alias"
        sed "s|^worktree=.*|worktree=$CASE_DIR/alias|" "$CASE_DIR/owner.before" > "$HOME_DIR/state/owner.meta"
        ;;
      ancestor) printf 'home=%s\n' "$CASE_DIR/pool" >> "$HOME_DIR/state/owner.meta" ;;
      duplicate) printf 'worktree=%s\n' "$FREE" >> "$HOME_DIR/state/owner.meta" ;;
    esac
    cp "$HOME_DIR/state/owner.meta" "$CASE_DIR/owner.before"
    out=$(run_spawn "$OWNED"); rc=$?
    [ "$rc" -ne 0 ] || fail "$form collision accepted"
    assert_owner_preserved
    case "$form" in
      duplicate) assert_contains "$out" 'ambiguous worktree ownership' 'duplicate ownership not diagnosed' ;;
      *) assert_contains "$out" 'still recorded to owner.meta' 'recorded owner not diagnosed' ;;
    esac
    pass "$form: owner commit, branch and metadata survive before launch"
  done
}

# Model the native API, not its store: lease upgrades an existing slot without
# touching Git. A free candidate is available so reservation permits progress.
install_native_fixture() {
  cat > "$FAKEBIN/treehouse" <<'TOOL'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_NATIVE_LOG"
case "$1" in
  status)
    [ "${FM_BAD_INVENTORY:-0}" != 1 ] || { printf '{}\n'; exit 0; }
    state=available
    [ ! -e "$FM_LEASE_FILE" ] || state=leased
    printf '[{"name":"1","path":"%s","status":"%s"}]\n' "$FM_OWNED_PATH" "$state"
    ;;
  lease)
    [ "${FM_LEASE_FAIL:-0}" != 1 ] || exit 1
    touch "$FM_LEASE_FILE"
    printf '%s\n' "$FM_OWNED_PATH"
    ;;
esac
TOOL
  chmod +x "$FAKEBIN/treehouse"
}

run_native_spawn() {
  FM_NATIVE_LOG="$CASE_DIR/native.log" FM_LEASE_FILE="$CASE_DIR/lease" FM_OWNED_PATH="$OWNED" run_spawn "$FREE"
}

test_reservation_and_retained_records() {
  local out rc
  make_case reserve
  OWNER_SHA=$(git -C "$OWNED" rev-parse HEAD)
  install_native_fixture
  out=$(run_native_spawn); rc=$?
  expect_code 0 "$rc" "native reservation prevented reuse while permitting another slot: $out"
  assert_grep 'lease 1 --lease-holder firstmate:' "$CASE_DIR/native.log" 'recorded slot was not reserved'
  cmp -s "$CASE_DIR/owner.before" "$HOME_DIR/state/owner.meta" || fail 'retained landed record changed'
  [ "$(git -C "$OWNED" rev-parse HEAD)" = "$OWNER_SHA" ] || fail 'reserved copy reset'
  assert_grep "worktree=$FREE" "$HOME_DIR/state/newcomer.meta" 'new task did not use free copy'
  pass 'native state-only reservation preserves retained records and permits a free copy'
}

test_unknown_native_ownership_refuses_before_allocation() {
  local mode out rc
  for mode in inventory lease; do
    make_case "bad-$mode"
    OWNER_SHA=$(git -C "$OWNED" rev-parse HEAD)
    install_native_fixture
    if [ "$mode" = inventory ]; then
      out=$(FM_BAD_INVENTORY=1 run_native_spawn); rc=$?
    else
      out=$(FM_LEASE_FAIL=1 run_native_spawn); rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "unreadable $mode accepted"
    assert_owner_preserved
    pass "$mode failure refuses before allocation or launch"
  done
}

test_unknown_claim_refuses_reassignment() {
  local out rc
  make_case claim
  rm "$HOME_DIR/state/owner.meta"
  printf '{"worktrees":[]}\n' > "$CASE_DIR/pool/treehouse-state.json"
  printf 'task=unresolved-owner\nhome=/missing/home\n' > "$CASE_DIR/pool/1/.fm-slot-owner"
  OWNER_SHA=$(git -C "$OWNED" rev-parse HEAD)
  out=$(run_spawn "$OWNED"); rc=$?
  [ "$rc" -ne 0 ] || fail 'unresolved foreign claim accepted'
  assert_contains "$out" 'unresolved slot ownership' 'unknown claim not diagnosed'
  assert_grep 'task=unresolved-owner' "$CASE_DIR/pool/1/.fm-slot-owner" 'claim overwritten'
  [ "$(git -C "$OWNED" rev-parse HEAD)" = "$OWNER_SHA" ] || fail 'unknown claim copy reset'
  pass 'an orphan foreign claim refuses reassignment without erasing ownership'
}

test_existing_native_lease_is_not_replaced() {
  local out rc
  make_case leased
  install_native_fixture
  touch "$CASE_DIR/lease"
  out=$(run_native_spawn); rc=$?
  expect_code 0 "$rc" "an existing native lease should permit a different copy: $out"
  assert_no_grep 'lease 1 ' "$CASE_DIR/native.log" 'native lease holder was replaced'
  pass 'an existing native lease remains unchanged'
}

test_orphan_claim_is_protected_before_get() {
  local out rc
  make_case orphan-reserve
  install_native_fixture
  rm "$HOME_DIR/state/owner.meta"
  printf 'task=unreachable-owner\nhome=/unavailable/home\n' > "$CASE_DIR/pool/1/.fm-slot-owner"
  out=$(run_native_spawn); rc=$?
  expect_code 0 "$rc" "an orphan claim should be reserved before selecting a free copy: $out"
  assert_grep 'lease 1 --lease-holder firstmate:' "$CASE_DIR/native.log" 'orphan copy was not protected before get'
  assert_grep 'task=unreachable-owner' "$CASE_DIR/pool/1/.fm-slot-owner" 'orphan claim changed'
  pass 'an orphan claim reserves its native slot before get without changing ownership'
}

test_registered_local_home_ownership_is_respected() {
  local out rc child
  make_case registered-home
  child="$CASE_DIR/mate"
  fm_test_spawn_home "$child" codex
  mv "$HOME_DIR/state/owner.meta" "$child/state/owner.meta"
  printf '%s\n' "- mate - fixture (home: $child; scope: test; projects: project; added 2026-01-01)" > "$HOME_DIR/data/secondmates.md"
  OWNER_SHA=$(git -C "$OWNED" rev-parse HEAD)
  out=$(run_spawn "$OWNED"); rc=$?
  [ "$rc" -ne 0 ] || fail 'registered local home owner ignored'
  assert_contains "$out" 'still recorded to owner.meta' 'local owner not identified'
  [ "$(git -C "$OWNED" rev-parse HEAD)" = "$OWNER_SHA" ] || fail 'local home owner reset'
  cmp -s "$child/state/owner.meta" "$CASE_DIR/owner.before" || fail 'local home record changed'
  pass 'registered local home ownership is checked without endpoint inventory'
}

test_collision_before_refresh
test_reservation_and_retained_records
test_unknown_native_ownership_refuses_before_allocation
test_unknown_claim_refuses_reassignment

test_existing_native_lease_is_not_replaced
test_orphan_claim_is_protected_before_get
test_registered_local_home_ownership_is_respected
