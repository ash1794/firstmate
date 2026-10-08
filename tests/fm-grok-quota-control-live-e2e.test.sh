#!/usr/bin/env bash
# Opt-in real Grok weekly-limit exit guard on tmux and Herdr.
# Requires an existing login whose quota produces the recorded modal; no option
# is selected, no credentials are changed, and every endpoint belongs to a lab.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_GROK_QUOTA_CONTROL_LIVE grok herdr jq tmux

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
HERDR_LAB_SESSION=$(env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" name grok-quota)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-grok-quota-live.XXXXXX")
FM_HOME="$LAB/home"
LAB_TMUX_DIR=
cleanup() {
  local rc=$? cleanup_rc=0
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" tmux -L fm-lab kill-server 2>/dev/null || true
    "$LAB_HOME_HELPER" teardown "$FM_HOME" || cleanup_rc=1
  fi
  env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || cleanup_rc=1
  rm -rf "$LAB"
  [ "$cleanup_rc" -eq 0 ] || exit "$cleanup_rc"
  exit "$rc"
}
trap cleanup EXIT
env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")
export FM_HOME TMUX_TMPDIR="$LAB_TMUX_DIR"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
VERSION=$(grok --version)
env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json | jq -r '"# Herdr client=\(.client.version) server=\(.server.version)"'
mkdir "$LAB/project"
git -C "$LAB/project" init -q
printf 'preserve this work\n' > "$LAB/project/README.md"

# Route the real control adapter's CLI calls through the same guarded helper.
# Reject missing/foreign sessions; remove the exported function for the helper
# itself so its explicitly scoped real CLI call cannot recurse.
herdr() {
  local selected='' arg
  local -a args=()
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in
      --session) selected=${1:?}; shift ;;
      --session=*) selected=${arg#*=} ;;
      *) args+=("$arg") ;;
    esac
  done
  [ "$selected" = "$HERDR_LAB_SESSION" ] || return 91
  env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
}
export -f herdr
export HERDR_LAB_HELPER HERDR_LAB_SESSION

capture() {
  if [ "$BACKEND" = herdr ]; then
    env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane read "$PANE" --source visible
  else
    tmux -L fm-lab capture-pane -p -t "$TARGET"
  fi
}
for BACKEND in herdr tmux; do
  if [ "$BACKEND" = herdr ]; then
    CREATED=$(env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$LAB/project" --label fm-quota)
    PANE=$(printf '%s' "$CREATED" | jq -r '.result.root_pane.pane_id')
    TARGET="$HERDR_LAB_SESSION:$PANE"
  else
    tmux -L fm-lab new-session -d -s quota -n fm-quota -x 120 -y 40 -c "$LAB/project"
    TARGET=quota:fm-quota
    # The adapter's plain tmux calls address only this private server.
    TMUX="$LAB_TMUX_DIR/tmux-$(id -u)/fm-lab,0,0"
    export TMUX
  fi
  {
    printf 'window=%s\nendpoint_task_id=quota\n' "$TARGET"
    printf 'worktree=%s\nproject=%s\n' "$LAB/project" "$LAB/project"
    printf 'harness=grok\nkind=scout\nmode=no-mistakes\nyolo=off\nbackend=%s\n' "$BACKEND"
    if [ "$BACKEND" = herdr ]; then
      printf 'herdr_session=%s\nherdr_pane_id=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\n' \
        "$HERDR_LAB_SESSION" "$PANE" \
        "$(printf '%s' "$CREATED" | jq -r '.result.root_pane.workspace_id')" \
        "$(printf '%s' "$CREATED" | jq -r '.result.root_pane.tab_id')"
    fi
  } > "$FM_HOME/state/quota.meta"
  CMD="GROK_AGENT_DASHBOARD=0 grok --trust --no-subagents --leader-socket '$LAB/$BACKEND-leader.sock' --model grok-4.7-build-fast --tools '' 'Reply ONLY QUOTA_LAB. Do not run tools.'; printf '%s\\n' \"\$?\" > '$LAB/$BACKEND.exit'"
  if [ "$BACKEND" = herdr ]; then
    env -u BASH_FUNC_herdr%% "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PANE" "$CMD" >/dev/null
  else
    tmux -L fm-lab send-keys -t "$TARGET" -l "$CMD"
    tmux -L fm-lab send-keys -t "$TARGET" Enter
  fi
  seen=0
  for ((i=0; i<60; i++)); do
    SCREEN=$(capture)
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-composer-lib.sh"
    if [ "$(fm_composer_blocking_dialog "$SCREEN" || true)" = 'Grok weekly-limit picker' ]; then seen=1; break; fi
    sleep 0.5
  done
  [ "$seen" -eq 1 ] || fail "$VERSION on $BACKEND: recorded weekly-limit modal unavailable: $SCREEN"
  started=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  OUT=$(FM_CONTROL_EXIT_WAIT=10 "$ROOT/bin/fm-control.sh" quota exit 2>&1) \
    || fail "$VERSION on $BACKEND: native exit failed: $OUT"
  ended=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  for ((i=0; i<20; i++)); do [ ! -f "$LAB/$BACKEND.exit" ] || break; sleep 0.1; done
  [ "$(cat "$LAB/$BACKEND.exit")" = 0 ] || fail "$VERSION on $BACKEND: real process did not exit zero"
  [ -f "$FM_HOME/state/quota.meta" ] && [ "$(cat "$LAB/project/README.md")" = 'preserve this work' ] \
    || fail "$VERSION on $BACKEND: exit lost work or metadata"
  printf 'ok - %s on %s: %s; Grok exit=0; wall_s=%s; endpoint and work preserved\n' \
    "$VERSION" "$BACKEND" "$OUT" "$(awk -v a="$started" -v b="$ended" 'BEGIN{printf "%.3f", b-a}')"
done
