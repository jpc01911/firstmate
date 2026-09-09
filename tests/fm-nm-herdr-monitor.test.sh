#!/usr/bin/env bash
# tests/fm-nm-herdr-monitor.test.sh - portable regression for the home-scoped,
# display-only No-Mistakes Herdr monitor (bin/fm-nm-herdr-monitor.sh).
#
# Portable (no Herdr server, no daemon): Herdr is a PATH-shim fake, crew-state
# is a stub through FM_NM_MONITOR_CREW_STATE, and the read-only pipeline proof
# drives the REAL fm-crew-state.sh against a recording fake `no-mistakes`.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT/bin/fm-nm-herdr-monitor.sh"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot nmmon)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

write_fake_herdr() {
  cat > "$FAKEBIN/herdr" <<'EOF'
#!/usr/bin/env bash
# Fake herdr: serves canned workspace/tab/pane/agent answers from $FAKE_STATE.
S="$FAKE_STATE"
args="$*"
case "$args" in
  *"status --json"*) cat "$S/status.json" ;;
  *"workspace list"*) cat "$S/workspaces.json" ;;
  *"tab list"*) cat "$S/tabs.json" ;;
  *"pane list"*) cat "$S/panes.json" ;;
  *"pane read"*) cat "$S/read.txt" 2>/dev/null || printf 'stale shell, no header here' ;;
  *"pane get"*)
    pane="$3"
    case "$pane" in
      *dead*) printf '{"error":{"code":"pane_not_found"}}' ;;
      *) printf '{"result":{"pane":{"pane_id":"%s"}}}' "$pane" ;;
    esac
    ;;
  *"agent get"*)
    pane="$3"
    case "$pane" in
      *noagent*|*dead*) printf '{"error":{"code":"agent_not_found"}}' ;;
      *) printf '{"result":{"agent":{"agent_status":"idle"}}}' ;;
    esac
    ;;
  *"tab create"*)
    sleep "${FAKE_TAB_CREATE_DELAY:-0}"
    printf '{"result":{"tab":{"tab_id":"t-new"},"root_pane":{"pane_id":"w1:p-new"}}}'
    printf 'tab create %s\n' "$args" >> "$S/calls.log"
    ;;
  *"pane run"*)
    printf 'pane run %s\n' "$args" >> "$S/calls.log"
    printf '{}'
    ;;
  *"pane close"*)
    printf 'pane close %s\n' "$args" >> "$S/calls.log"
    printf '{}'
    ;;
  *) printf '{}' ;;
esac
EOF
  chmod +x "$FAKEBIN/herdr"
}

write_stub_crew_state() {
  cat > "$FAKEBIN/stub-crew-state.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  a-active) echo "state: working · source: run-step · validating (running)" ;;
  b-gate) echo "state: parked · source: run-step · parked at review: 2 finding(s)" ;;
  c-failed) echo "state: failed · source: run-step · run failed" ;;
  d-ci) echo "state: done · source: run-step · checks green: PR ready for review" ;;
  e-done) echo "state: done · source: run-step · run completed" ;;
  f-unknown) echo "state: unknown · source: none · daemon socket down despite attributed run record" ;;
  g-blocked) echo "state: blocked · source: status-log · waiting on approver" ;;
  h-paused) echo "state: paused · source: status-log · upstream release window" ;;
  *) echo "state: unknown · source: none · no current-state source available" ;;
esac
EOF
  chmod +x "$FAKEBIN/stub-crew-state.sh"
}

make_home() {
  local home=$1
  mkdir -p "$home/state"
}

add_ship() {
  printf 'kind=ship\nworktree=/tmp\nbackend=tmux\nharness=claude\n' > "$1/state/$2.meta"
}

# --- render: all six required views plus blocked/paused, none hidden ---------
home1="$TMP_ROOT/home1"
make_home "$home1"
for t in a-active b-gate c-failed d-ci e-done f-unknown g-blocked h-paused; do
  add_ship "$home1" "$t"
done
printf 'kind=scout\nworktree=/tmp\n' > "$home1/state/scout1.meta"
write_stub_crew_state
out=$(FM_HOME="$home1" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  "$MON" render --state-dir "$home1/state" 2>&1) || fail "render failed: $out"
for want in "a-active | active" "b-gate | gate-waiting" "c-failed | failed" \
  "d-ci | CI-ready" "e-done | completed" "f-unknown | unknown" \
  "g-blocked | blocked" "h-paused | paused"; do
  case "$out" in *"$want"*) pass "render shows $want" ;; *) fail "render missing $want: $out" ;; esac
done
case "$out" in *scout1*) fail "render must list ship runs only, saw scout: $out" ;; *) pass "render lists ship tasks only" ;; esac

# --- render: empty home is idle, not an error --------------------------------
home_empty="$TMP_ROOT/empty"
make_home "$home_empty"
out=$(FM_HOME="$home_empty" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  "$MON" render --state-dir "$home_empty/state" 2>&1) || fail "empty render failed"
case "$out" in *"idle | no ship tasks"*) pass "empty home renders idle" ;; *) fail "empty home wrong: $out" ;; esac

# --- render: future runs appear with no registration --------------------------
add_ship "$home1" "z-new"
out=$(FM_HOME="$home1" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  "$MON" render --state-dir "$home1/state" 2>&1) || fail "re-render failed"
case "$out" in *"z-new | unknown"*) pass "a new task appears on the next render" ;; *) fail "new task hidden: $out" ;; esac
case "$out" in *"f-unknown | idle"*) fail "an unknown state was mislabeled idle: $out" ;; *) pass "unknown never reads as idle" ;; esac

# --- read-only pipeline proof: real crew-state, recording fake no-mistakes ----
home_ro="$TMP_ROOT/homero"
make_home "$home_ro"
wt="$TMP_ROOT/wt-ro"
git init -q -b main "$wt" 2>/dev/null || git init -q "$wt"
git -C "$wt" config user.email t@t.t
git -C "$wt" config user.name t
echo x > "$wt/f.txt"
git -C "$wt" add f.txt
git -C "$wt" commit -qm init
branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD)
printf 'kind=ship\nworktree=%s\nbackend=tmux\nharness=claude\n' "$wt" > "$home_ro/state/r1.meta"
cat > "$FAKEBIN/no-mistakes" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/nm-calls.log"
if [ "\$1" = "axi" ] && [ "\$2" = "status" ]; then
  printf 'status: running\nbranch: %s\nhead: %s\n' "$branch" "$(git -C "$wt" rev-parse HEAD)"
elif [ "\$1" = "runs" ]; then
  printf ''
elif [ "\$1" = "daemon" ]; then
  exit 0
else
  printf ''
fi
EOF
chmod +x "$FAKEBIN/no-mistakes"
PATH="$FAKEBIN:$PATH" FM_HOME="$home_ro" "$MON" render --state-dir "$home_ro/state" >/dev/null 2>&1 \
  || fail "read-only render failed"
[ -f "$TMP_ROOT/nm-calls.log" ] || fail "no-mistakes was never consulted"
while IFS= read -r call; do
  case "$call" in
    "axi status"|"axi logs"*"--step ci"*|"runs "*|"daemon status") : ;;
    *"respond"*|*"run validation"*|*"abort"*|*"sync"*|*"rerun"*)
      fail "monitor issued a pipeline-mutating call: $call" ;;
  esac
done < "$TMP_ROOT/nm-calls.log"
pass "monitor consulted only read-only pipeline commands"

# --- ensure: reuses the recorded live pane, creates nothing -------------------
export FAKE_STATE="$TMP_ROOT/fs1"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
write_fake_herdr
home2="$TMP_ROOT/home2"
make_home "$home2"
printf 'default\nw-home\nt-old\nw1:p-old\n' > "$home2/state/.nm-monitor"
PATH="$FAKEBIN:$PATH" FM_HOME="$home2" "$MON" ensure >/dev/null 2>&1 \
  || fail "ensure with live record failed"
case "$(cat "$home2/state/.nm-monitor")" in
  *w1:p-old*) pass "ensure reuses the recorded live pane" ;;
  *) fail "ensure rewrote a live record: $(cat "$home2/state/.nm-monitor")" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"tab create"*) fail "ensure created a tab despite a live record" ;;
  *) pass "ensure created nothing when the record is live" ;;
esac

# --- ensure: concurrent convergence creates one monitor tab ------------------
export FAKE_STATE="$TMP_ROOT/fs-concurrent"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
write_fake_herdr
home_concurrent="$TMP_ROOT/home-concurrent"
make_home "$home_concurrent"
FAKE_TAB_CREATE_DELAY=1 PATH="$FAKEBIN:$PATH" FM_HOME="$home_concurrent" "$MON" ensure >/dev/null 2>&1 &
ensure_one=$!
FAKE_TAB_CREATE_DELAY=1 PATH="$FAKEBIN:$PATH" FM_HOME="$home_concurrent" "$MON" ensure >/dev/null 2>&1 &
ensure_two=$!
wait "$ensure_one" || fail "first concurrent ensure failed"
wait "$ensure_two" || fail "second concurrent ensure failed"
creates=$(grep -c '^tab create ' "$FAKE_STATE/calls.log" || true)
[ "$creates" -eq 1 ] || fail "concurrent ensure created $creates monitor tabs"
pass "concurrent ensure creates one monitor tab"

# --- ensure: converges a live unrecorded tab, closes husk duplicates ---------
export FAKE_STATE="$TMP_ROOT/fs2"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[{"tab_id":"t-keep","label":"nm-monitor"},{"tab_id":"t-dup","label":"nm-monitor"},{"tab_id":"t-work","label":"fm-task1"}]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[{"pane_id":"w1:p-keep","tab_id":"t-keep"},{"pane_id":"w1:p-dead-noagent","tab_id":"t-dup"},{"pane_id":"w1:p-work","tab_id":"t-work"}]}}' > "$FAKE_STATE/panes.json"
write_fake_herdr
home3="$TMP_ROOT/home3"
make_home "$home3"
PATH="$FAKEBIN:$PATH" FM_HOME="$home3" "$MON" ensure >/dev/null 2>&1 \
  || fail "ensure adoption failed"
case "$(cat "$home3/state/.nm-monitor")" in
  *w1:p-keep*) pass "ensure adopted the single live monitor tab" ;;
  *) fail "ensure adopted wrong tab: $(cat "$home3/state/.nm-monitor")" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"pane close"*"w1:p-dead-noagent"*) pass "ensure closed the husk duplicate" ;;
  *) fail "ensure left the husk duplicate: $(cat "$FAKE_STATE/calls.log")" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"w1:p-work"*) fail "ensure touched the worker pane" ;;
  *) pass "ensure never touched the worker pane" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"tab create"*) fail "ensure created a tab when one was live" ;;
  *) pass "ensure converged without a duplicate" ;;
esac

# --- ensure: missing home workspace changes nothing (non-Herdr homes) ---------
export FAKE_STATE="$TMP_ROOT/fs3"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-other","label":"someone-else"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
write_fake_herdr
home4="$TMP_ROOT/home4"
make_home "$home4"
if PATH="$FAKEBIN:$PATH" FM_HOME="$home4" "$MON" ensure >/dev/null 2>&1; then
  pass "ensure is fail-open without a home workspace"
else
  fail "ensure must exit 0 when the home workspace is absent"
fi
[ ! -e "$home4/state/.nm-monitor" ] || fail "ensure wrote a record with no home workspace"
case "$(cat "$FAKE_STATE/calls.log")" in
  *"tab create"*) fail "ensure created without a home workspace" ;;
  *) pass "non-Herdr layout unchanged" ;;
esac

# --- ensure: a restarted husk pane gets its view re-run, a live view is kept --
export FAKE_STATE="$TMP_ROOT/fs5"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
printf 'stale shell after restart, no header here' > "$FAKE_STATE/read.txt"
home6="$TMP_ROOT/home6"
make_home "$home6"
printf 'default\nw-home\nt-stale\nw1:p-stale-noagent\n' > "$home6/state/.nm-monitor"
PATH="$FAKEBIN:$PATH" FM_HOME="$home6" "$MON" ensure >/dev/null 2>&1 \
  || fail "ensure on a stale pane failed"
case "$(cat "$FAKE_STATE/calls.log")" in
  *"pane run"*"watch"*) pass "ensure re-runs the view in a restarted husk pane" ;;
  *) fail "ensure left a restarted pane blank: $(cat "$FAKE_STATE/calls.log")" ;;
esac
printf 'No-Mistakes monitor · home workspace [firstmate]\nship log line\n' > "$FAKE_STATE/read.txt"
: > "$FAKE_STATE/calls.log"
PATH="$FAKEBIN:$PATH" FM_HOME="$home6" "$MON" ensure >/dev/null 2>&1 \
  || fail "ensure on a live view failed"
case "$(cat "$FAKE_STATE/calls.log")" in
  *"pane run"*) fail "ensure re-ran a live view" ;;
  *) pass "ensure leaves a live monitor view running" ;;
esac

# --- ensure: secondmate homes scope to their own workspace label --------------
export FAKE_STATE="$TMP_ROOT/fs4"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-sm","label":"2ndmate-acme"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
write_fake_herdr
home5="$TMP_ROOT/home5"
make_home "$home5"
printf 'acme\n' > "$home5/.fm-secondmate-home"
PATH="$FAKEBIN:$PATH" FM_HOME="$home5" "$MON" render --state-dir "$home5/state" 2>&1 | head -1 | grep -F '[2ndmate-acme]' >/dev/null \
  || fail "secondmate render mislabeled the home"
pass "secondmate home renders under its own workspace label"
PATH="$FAKEBIN:$PATH" FM_HOME="$home5" HERDR_SESSION=lab "$MON" ensure >/dev/null 2>&1 \
  || fail "secondmate ensure failed"
case "$(cat "$home5/state/.nm-monitor")" in
  lab*) pass "secondmate record binds its own session" ;;
  *) fail "secondmate record wrong: $(cat "$home5/state/.nm-monitor")" ;;
esac

# --- option parsing: a flag with no value fails fast, never spins -------------
for bad in "ensure --interval" "render --state-dir"; do
  # shellcheck disable=SC2086
  out=$(FM_TIMEOUT_MECHANISM_OVERRIDE=bash FM_HOME="$home_empty" fm_run_timed 10 "$MON" $bad 2>&1); rc=$?
  [ "$rc" -ne 124 ] || fail "$bad hung instead of rejecting the missing value"
  [ "$rc" -ne 0 ] || fail "$bad accepted a missing value"
  case "$out" in *"requires a value"*) pass "$bad is rejected with a usage error" ;;
    *) fail "$bad gave no usage error: $out" ;;
  esac
done
