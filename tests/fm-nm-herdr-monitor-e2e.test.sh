#!/usr/bin/env bash
# tests/fm-nm-herdr-monitor-e2e.test.sh - live-Herdr evidence for the
# home-scoped display-only No-Mistakes monitor (bin/fm-nm-herdr-monitor.sh).
# Every Herdr operation runs through the guarded named non-default lab helper;
# lab teardown verifies the default fleet session is byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

REAL_HERDR=$(command -v herdr)
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-mon-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-nm-herdr-monitor)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision the isolated Herdr lab session"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

# Stand up this home's own workspace the way a first Herdr spawn would, then
# the monitor must adopt it rather than create anything.
WS_OUT=$(lab workspace create --cwd "$HOME_DIR" --label firstmate --no-focus 2>/dev/null) \
  || fail "could not create the home workspace in the lab session"
WSID=$(printf '%s' "$WS_OUT" | jq -r '.result.workspace.workspace_id // empty' 2>/dev/null)
[ -n "$WSID" ] || fail "home workspace create returned no id: $WS_OUT"
pass "lab: home workspace created ($WSID)"

export PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH"
export FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION"

FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-nm-herdr-monitor.sh" ensure --interval 3 >/dev/null 2>&1 \
  || fail "ensure failed in the lab session"
[ -f "$HOME_DIR/state/.nm-monitor" ] || fail "ensure wrote no record"
REC_SESSION=$(sed -n '1p' "$HOME_DIR/state/.nm-monitor")
REC_PANE=$(sed -n '4p' "$HOME_DIR/state/.nm-monitor")
[ "$REC_SESSION" = "$HERDR_LAB_SESSION" ] || fail "record bound the wrong session: $REC_SESSION"
[ -n "$REC_PANE" ] || fail "record holds no pane"
pass "live herdr: ensure converged one monitor tab with a session-bound record"

TABS=$(lab tab list --workspace "$WSID" 2>/dev/null) || fail "could not list lab tabs"
MON_COUNT=$(printf '%s' "$TABS" | jq --arg want "nm-monitor" \
  '[.result.tabs[]? | select(.label == $want)] | length' 2>/dev/null)
[ "$MON_COUNT" = 1 ] || fail "expected exactly one nm-monitor tab, got $MON_COUNT: $TABS"
pass "live herdr: exactly one display-only monitor tab lives in the home workspace"

# A second ensure must converge without a duplicate.
FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-nm-herdr-monitor.sh" ensure --interval 3 >/dev/null 2>&1 \
  || fail "second ensure failed"
TABS2=$(lab tab list --workspace "$WSID" 2>/dev/null) || fail "could not re-list lab tabs"
MON_COUNT2=$(printf '%s' "$TABS2" | jq --arg want "nm-monitor" \
  '[.result.tabs[]? | select(.label == $want)] | length' 2>/dev/null)
[ "$MON_COUNT2" = 1 ] || fail "second ensure duplicated the monitor tab: $TABS2"
[ "$(cat "$HOME_DIR/state/.nm-monitor")" = "$(printf '%s\n%s\n%s\n%s\n' "$REC_SESSION" "$WSID" "$(sed -n '3p' "$HOME_DIR/state/.nm-monitor")" "$REC_PANE")" ] \
  || fail "second ensure rewrote a live record"
pass "live herdr: repeated ensure converges with no duplicate pane"

# Render against the live home: idle now, and a new ship task appears next refresh.
RENDER=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-nm-herdr-monitor.sh" render --state-dir "$HOME_DIR/state" 2>&1) \
  || fail "render failed"
case "$RENDER" in *"no ship tasks"*) pass "live herdr: empty home renders idle" ;; *) fail "empty render wrong: $RENDER" ;; esac
printf 'kind=ship\nworktree=/tmp\nbackend=tmux\nharness=claude\n' > "$HOME_DIR/state/e2e-task.meta"
RENDER2=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-nm-herdr-monitor.sh" render --state-dir "$HOME_DIR/state" 2>&1) \
  || fail "re-render failed"
case "$RENDER2" in *"e2e-task | unknown"*) pass "live herdr: a future run appears on the next render" ;; *) fail "new task hidden: $RENDER2" ;; esac

# Status names the recorded endpoint.
STATUS=$(FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-nm-herdr-monitor.sh" status 2>&1) || fail "status failed"
case "$STATUS" in *"live session=$HERDR_LAB_SESSION"*) pass "live herdr: status reports the live monitor endpoint" ;; *) fail "status wrong: $STATUS" ;; esac
