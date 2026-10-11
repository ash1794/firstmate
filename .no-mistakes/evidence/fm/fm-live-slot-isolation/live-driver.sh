#!/usr/bin/env bash
# Credentialed native reservation proof, opt in with FM_WORKTREE_OWNERSHIP_LIVE=1.
# Uses only a marked disposable home, private Treehouse root and helper-owned
# named Herdr session. Never operates the production default session.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_WORKTREE_OWNERSHIP_LIVE herdr treehouse codex jq
SOURCE_ROOT=$ROOT
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_HOME=$(mktemp -d "$ROOT/.test-labs/fm-slot-live.XXXXXX")
"$LAB_HOME_HELPER" create "$LAB_HOME" >/dev/null
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-live-slot-isolation)
cleanup() {
  if [ -n "${OWNER_PANE:-}" ]; then
    PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$OWNER_PANE" --source recent --lines 200 || true
  fi
  "$LAB_HOME_HELPER" teardown "$LAB_HOME"
  PATH="$BASE_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"
  chmod -R u+w "$LAB_HOME"
  rm -rf "$LAB_HOME"
  printf "PASS: lab removed; Herdr teardown and default-session tripwire succeeded\n"
  fm_test_cleanup
}
trap cleanup EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
unset TMUX TMUX_PANE HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_SOCKET_PATH HERDR_ENV
export FM_HOME="$LAB_HOME" TREEHOUSE_ROOT="$LAB_HOME/pool-root" HERDR_SESSION="$HERDR_LAB_SESSION"
export BASE_PATH="$PATH" HERDR_LAB_HELPER HERDR_LAB_SESSION
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
mkdir -p "$FM_HOME/fakebin" "$FM_HOME/project" "$FM_HOME/data/lab-owner" "$FM_HOME/data/lab-newcomer"
# Enforce the brief's helper boundary even for API calls made inside spawn.
cat > "$FM_HOME/fakebin/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "${2:-}" = "$HERDR_LAB_SESSION" ] || exit 93
    shift 2
  else
    args+=("$1"); shift
  fi
done
PATH="$BASE_PATH" exec "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAP
chmod +x "$FM_HOME/fakebin/herdr"
export PATH="$FM_HOME/fakebin:$PATH"
export FM_SPAWN_NO_GUARD=1
git -C "$FM_HOME/project" init -q
git -C "$FM_HOME/project" -c user.name=Test -c user.email=test@example.invalid commit --allow-empty -qm initial
for id in lab-owner lab-newcomer; do
  cat > "$FM_HOME/data/$id/brief.md" <<'BRIEF'
# Task
## Captain's intent
Verify isolated worker launch in a disposable lab.

## Firstmate spec
Do not change files or branches. Calculate 7 * 9 and reply with the result followed by LAB. Remain available.
BRIEF
done
printf 'lab=%s session=%s\n' "$FM_HOME" "$HERDR_LAB_SESSION"
PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json
bash "$SOURCE_ROOT/bin/fm-spawn.sh" lab-owner "$FM_HOME/project" --mode no-mistakes --yolo off --backend herdr --harness codex --model gpt-6.1-sol --effort low
OWNER=$(sed -n 's/^worktree=//p' "$FM_HOME/state/lab-owner.meta")
OWNER_PANE=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/lab-owner.meta")
OWNER_SHA=$(git -C "$OWNER" rev-parse HEAD)
printf 'owner=%s sha=%s\n' "$OWNER" "$OWNER_SHA"
cp "$FM_HOME/state/lab-owner.meta" "$FM_HOME/data/owner-before.meta"
PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$OWNER_PANE" --source visible
# Trust only this fresh disposable repository, then require output absent from
# the prompt so a real authenticated model response is proven.
for attempt in $(seq 1 60); do
  screen=$(PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$OWNER_PANE" --source visible)
  case "$screen" in *'Trust and continue'*)
    PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$OWNER_PANE" Enter
    break ;;
  esac
  sleep 0.5
done
PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane wait-output "$OWNER_PANE" --match '63 LAB' --source recent --lines 200 --timeout 120000
PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$OWNER_PANE" --source visible
printf 'unpublished owner work\n' > "$OWNER/kept.txt"
git -C "$OWNER" add kept.txt
git -C "$OWNER" -c core.hooksPath=/dev/null -c user.name=Test -c user.email=test@example.invalid commit -qm unpublished
printf 'uncommitted owner work\n' > "$OWNER/dirty.txt"
OWNER_SHA=$(git -C "$OWNER" rev-parse HEAD)
# Adversarial duplicate record must refuse before allocation or launch.
printf 'worktree=%s\n' "$OWNER" >> "$FM_HOME/state/lab-owner.meta"
set +e
bash "$SOURCE_ROOT/bin/fm-spawn.sh" lab-newcomer "$FM_HOME/project" --mode no-mistakes --yolo off --backend herdr --harness codex --model gpt-6.1-sol --effort low
REFUSAL=$?
set -e
cp "$FM_HOME/data/owner-before.meta" "$FM_HOME/state/lab-owner.meta"
[ "$REFUSAL" -ne 0 ]
[ ! -e "$FM_HOME/state/lab-newcomer.meta" ]
[ "$(git -C "$OWNER" rev-parse HEAD)" = "$OWNER_SHA" ]
printf 'PASS: ambiguous live owner metadata refused newcomer before allocation and launch\n'

# A second spawn exercises the native reservation, without changing its owner.
bash "$SOURCE_ROOT/bin/fm-spawn.sh" lab-newcomer "$FM_HOME/project" --mode no-mistakes --yolo off --backend herdr --harness codex --model gpt-6.1-sol --effort low
NEW=$(sed -n 's/^worktree=//p' "$FM_HOME/state/lab-newcomer.meta")
[ "$OWNER" != "$NEW" ]
[ "$(cat "$OWNER/dirty.txt")" = "uncommitted owner work" ]
[ "$(cat "$OWNER/kept.txt")" = "unpublished owner work" ]
[ "$(git -C "$OWNER" rev-parse HEAD)" = "$OWNER_SHA" ]
cmp -s "$FM_HOME/state/lab-owner.meta" "$FM_HOME/data/owner-before.meta"
(cd "$FM_HOME/project" && treehouse status --json)
PATH="$BASE_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$OWNER_PANE" --source visible
printf 'PASS: real Herdr/Codex spawns used distinct worktrees; owner HEAD and metadata unchanged\n'
