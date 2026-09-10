#!/usr/bin/env bash
# tests/fm-nm-herdr-monitor.test.sh - portable regression for the home-scoped,
# display-only No-Mistakes Herdr monitor (bin/fm-nm-herdr-monitor.sh).
#
# Portable (no Herdr server, no daemon): Herdr is a PATH-shim fake, crew-state
# is a stub through FM_NM_MONITOR_CREW_STATE, and the read-only pipeline proof
# drives the REAL fm-crew-state.sh against a recording fake `no-mistakes`.
set -u
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MON="$ROOT/bin/fm-nm-herdr-monitor.sh"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot nmmon)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/fake-ps" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *axo*) printf '4242 1\n'; [ -z "${FAKE_PS_CHILD:-}" ] || printf '4343 4242\n' ;;
  *) printf 'S\n' ;;
esac
EOF
chmod +x "$FAKEBIN/fake-ps"

write_fake_herdr() {
  cat > "$FAKEBIN/herdr" <<'EOF'
#!/usr/bin/env bash
# Fake herdr: serves canned workspace/tab/pane/agent answers from $FAKE_STATE.
S="$FAKE_STATE"
args="$*"
case "$args" in
  *"status --json"*) cat "$S/status.json" ;;
  *"session list --json"*) cat "$S/sessions.json" ;;
  *"workspace list"*) cat "$S/workspaces.json" ;;
  *"tab list"*) cat "$S/tabs.json" ;;
  *"tab get"*)
    tab="$3"
    jq -c --arg tab "$tab" '.[$tab] // {"error":{"code":"tab_not_found"}}' "$S/tab-get.json"
    ;;
  *"pane list"*) cat "$S/panes.json" ;;
  *"pane process-info"*) cat "$S/process-info.json" 2>/dev/null || printf '{}' ;;
  *"pane get"*)
    pane="$3"
    case "$pane" in
      *dead*) printf '{"error":{"code":"pane_not_found"}}' ;;
      w1:p-old) printf '{"result":{"pane":{"pane_id":"w1:p-old","tab_id":"t-old","workspace_id":"w-home"}}}' ;;
      w1:p-stale-noagent) printf '{"result":{"pane":{"pane_id":"w1:p-stale-noagent","tab_id":"t-stale","workspace_id":"w-home"}}}' ;;
      w1:p-new) printf '{"result":{"pane":{"pane_id":"w1:p-new","tab_id":"t-new","workspace_id":"w-home"}}}' ;;
      w9:p-launcher) jq -c --arg pane "$pane" '.[$pane]' "$S/pane-get.json" ;;
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
  *"tab close"*)
    printf 'tab close %s\n' "$args" >> "$S/calls.log"
    printf '{}'
    ;;
  *"pane run"*)
    printf 'pane run %s\n' "$args" >> "$S/calls.log"
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
[ -z "${FM_NM_MONITOR_DELAY:-}" ] || sleep "$FM_NM_MONITOR_DELAY"
case "$1" in
  a-active) echo "state: working · source: run-step · validating (running)" ;;
  b-gate) echo "state: parked · source: run-step · parked at review: 2 finding(s)" ;;
  c-failed) echo "state: failed · source: run-step · run failed" ;;
  d-ci) echo "state: done · source: run-step · checks green: PR ready for review (still monitoring for merge/close)" ;;
  e-done) echo "state: done · source: run-step · run completed" ;;
  f-unknown) echo "state: unknown · source: none · daemon socket down despite attributed run record" ;;
  g-blocked) echo "state: blocked · source: status-log · waiting on approver" ;;
  h-paused) echo "state: paused · source: status-log · upstream release window" ;;
  z-new) echo "state: working · source: run-step · validating (running)" ;;
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

# --- render: only active attributed No-Mistakes runs are listed ---------------
home1="$TMP_ROOT/home1"
make_home "$home1"
for t in a-active b-gate c-failed d-ci e-done f-unknown g-blocked h-paused; do
  add_ship "$home1" "$t"
done
printf 'kind=scout\nworktree=/tmp\n' > "$home1/state/scout1.meta"
write_stub_crew_state
out=$(FM_HOME="$home1" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  "$MON" render 2>&1) || fail "render failed: $out"
for want in "a-active | active" "b-gate | gate-waiting" "c-failed | failed" "d-ci | ci-ready"; do
  case "$out" in *"$want"*) pass "render shows $want" ;; *) fail "render missing $want: $out" ;; esac
done
for hidden in e-done f-unknown g-blocked h-paused scout1; do
  case "$out" in *"$hidden"*) fail "render listed non-active task $hidden: $out" ;; esac
done
pass "render hides terminal, non-run, and scout state"

# --- render: empty home is idle, not an error --------------------------------
home_empty="$TMP_ROOT/empty"
make_home "$home_empty"
out=$(FM_HOME="$home_empty" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  "$MON" render 2>&1) || fail "empty render failed"
case "$out" in *"idle | no active No-Mistakes runs"*) pass "empty home renders idle" ;; *) fail "empty home wrong: $out" ;; esac

# --- render: future runs appear with no registration --------------------------
add_ship "$home1" "z-new"
out=$(FM_HOME="$home1" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  "$MON" render 2>&1) || fail "re-render failed"
case "$out" in *"z-new | active"*) pass "a new active run appears on the next render" ;; *) fail "new active run hidden: $out" ;; esac

home_parallel="$TMP_ROOT/parallel"
make_home "$home_parallel"
for t in 01 02 03 04 05 06 07 08 09 10 11 12; do
  add_ship "$home_parallel" "p$t"
done
started=$(date +%s)
FM_HOME="$home_parallel" FM_NM_MONITOR_CREW_STATE="$FAKEBIN/stub-crew-state.sh" \
  FM_NM_MONITOR_DELAY=1 "$MON" render >/dev/null 2>&1 || fail "parallel render failed"
elapsed=$(($(date +%s) - started))
[ "$elapsed" -lt 5 ] || fail "active-run scan serialized twelve one-second reads (${elapsed}s)"
pass "active-run scan reads fleet candidates concurrently"
[ "$elapsed" -ge 2 ] || fail "active-run scan probed all twelve tasks at once (${elapsed}s); the fan-out is unbounded"
pass "active-run scan bounds its concurrent fan-out"

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
PATH="$FAKEBIN:$PATH" FM_HOME="$home_ro" "$MON" render >/dev/null 2>&1 \
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

# --- ensure: a reused pane must still belong to its recorded tab/workspace ----
export FAKE_STATE="$TMP_ROOT/fs-rebound"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
write_fake_herdr
home_rebound="$TMP_ROOT/home-rebound"
make_home "$home_rebound"
printf 'default\nw-home\nt-previous\nw1:p-old\n' > "$home_rebound/state/.nm-monitor"
PATH="$FAKEBIN:$PATH" FM_HOME="$home_rebound" "$MON" ensure >/dev/null 2>&1 \
  || fail "ensure with a rebound recorded pane failed"
case "$(cat "$home_rebound/state/.nm-monitor")" in
  *w1:p-new*) pass "ensure replaces a pane outside its recorded tab binding" ;;
  *) fail "ensure reused a pane whose binding changed: $(cat "$home_rebound/state/.nm-monitor")" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"tab create"*) pass "ensure created a monitor after rejecting the rebound pane" ;;
  *) fail "ensure did not replace the rebound pane" ;;
esac

# --- ensure: a live record survives a duplicate home-label collision ----------
export FAKE_STATE="$TMP_ROOT/fs-dup-record"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-other","label":"firstmate"},{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p-old","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv0":"-bash"}]}}}' > "$FAKE_STATE/process-info.json"
write_fake_herdr
home_dup="$TMP_ROOT/home-dup-record"
make_home "$home_dup"
printf 'default\nw-home\nt-old\nw1:p-old\n' > "$home_dup/state/.nm-monitor"
PATH="$FAKEBIN:$PATH" FM_HOME="$home_dup" FM_HERDR_PS_BIN="$FAKEBIN/fake-ps" \
  "$MON" ensure >/dev/null 2>&1 || fail "ensure failed with duplicate home labels and a live record"
case "$(cat "$home_dup/state/.nm-monitor")" in
  *w1:p-old*) pass "ensure keeps the exact record when the home label is ambiguous" ;;
  *) fail "ensure discarded a live record over a label collision: $(cat "$home_dup/state/.nm-monitor")" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"pane run"*"watch"*) pass "ensure restores the recorded view despite a label collision" ;;
  *) fail "ensure skipped convergence over a label collision: $(cat "$FAKE_STATE/calls.log")" ;;
esac
case "$(cat "$FAKE_STATE/calls.log")" in
  *"tab create"*) fail "ensure created a second monitor tab despite a live record" ;;
  *) pass "ensure creates nothing when the record is still bound" ;;
esac

# --- ensure: launcher identity selects among duplicate home labels ------------
export FAKE_STATE="$TMP_ROOT/fs-launcher"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"sessions":[{"name":"default","running":true,"socket_path":"/tmp/fm-nm-monitor.sock"}]}' > "$FAKE_STATE/sessions.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-other","label":"firstmate"},{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
printf '{"w9:p-launcher":{"result":{"pane":{"pane_id":"w9:p-launcher","tab_id":"t-launcher","workspace_id":"w-home"}}}}' > "$FAKE_STATE/pane-get.json"
printf '{"t-launcher":{"result":{"tab":{"tab_id":"t-launcher","workspace_id":"w-home"}}}}' > "$FAKE_STATE/tab-get.json"
write_fake_herdr
home_launcher="$TMP_ROOT/home-launcher"
make_home "$home_launcher"
PATH="$FAKEBIN:$PATH" FM_HOME="$home_launcher" HERDR_ENV=1 HERDR_PANE_ID=w9:p-launcher \
  HERDR_SESSION=default HERDR_SOCKET_PATH=/tmp/fm-nm-monitor.sock "$MON" ensure >/dev/null 2>&1 \
  || fail "ensure from a launcher with duplicate workspace labels failed"
case "$(cat "$home_launcher/state/.nm-monitor")" in
  $'default\nw-home\n'*) pass "ensure placed the monitor in the launcher's exact workspace" ;;
  *) fail "ensure skipped or chose the wrong duplicate-label workspace: $(cat "$home_launcher/state/.nm-monitor")" ;;
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

# --- ensure: a restored lone-shell pane gets its view re-run, a busy one is kept
export FAKE_STATE="$TMP_ROOT/fs5"
mkdir -p "$FAKE_STATE"
: > "$FAKE_STATE/calls.log"
printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p-stale-noagent","shell_pid":4242,"foreground_process_group_id":4242,"foreground_processes":[{"pid":4242,"name":"bash","argv0":"-bash"}]}}}' > "$FAKE_STATE/process-info.json"
write_fake_herdr
home6="$TMP_ROOT/home6"
make_home "$home6"
printf 'default\nw-home\nt-stale\nw1:p-stale-noagent\n' > "$home6/state/.nm-monitor"
PATH="$FAKEBIN:$PATH" FM_HOME="$home6" FM_HERDR_PS_BIN="$FAKEBIN/fake-ps" \
  "$MON" ensure >/dev/null 2>&1 || fail "ensure on a restored shell pane failed"
case "$(cat "$FAKE_STATE/calls.log")" in
  *"pane run"*"watch"*) pass "ensure re-runs the view in a restored lone-shell pane" ;;
  *) fail "ensure left a restored pane blank: $(cat "$FAKE_STATE/calls.log")" ;;
esac
: > "$FAKE_STATE/calls.log"
PATH="$FAKEBIN:$PATH" FM_HOME="$home6" FM_HERDR_PS_BIN="$FAKEBIN/fake-ps" \
  FAKE_PS_CHILD=1 FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=2 \
  "$MON" ensure >/dev/null 2>&1 || fail "ensure on a busy view failed"
case "$(cat "$FAKE_STATE/calls.log")" in
  *"pane run"*) fail "ensure re-ran a pane that still had a running child process" ;;
  *) pass "ensure leaves a live monitor view running" ;;
esac

# --- ensure: an unpublishable record never leaves an orphan monitor tab -------
if [ "$(id -u)" != 0 ]; then
  export FAKE_STATE="$TMP_ROOT/fs-norecord"
  mkdir -p "$FAKE_STATE"
  : > "$FAKE_STATE/calls.log"
  printf '{"server":{"running":true}}' > "$FAKE_STATE/status.json"
  printf '{"result":{"workspaces":[{"workspace_id":"w-home","label":"firstmate"}]}}' > "$FAKE_STATE/workspaces.json"
  printf '{"result":{"tabs":[]}}' > "$FAKE_STATE/tabs.json"
  printf '{"result":{"panes":[]}}' > "$FAKE_STATE/panes.json"
  write_fake_herdr
  home_norecord="$TMP_ROOT/home-norecord"
  make_home "$home_norecord"
  mkdir -p "$home_norecord/state/.nm-monitor/blocker"
  chmod 0500 "$home_norecord/state/.nm-monitor"
  err=$(PATH="$FAKEBIN:$PATH" FM_HOME="$home_norecord" "$MON" ensure 2>&1 >/dev/null) \
    || fail "ensure must stay fail-open when the record cannot be published"
  chmod 0700 "$home_norecord/state/.nm-monitor"
  case "$err" in
    *"could not publish the monitor record"*) pass "ensure reports an unpublishable monitor record" ;;
    *) fail "ensure published nothing and said nothing: $err" ;;
  esac
  case "$(cat "$FAKE_STATE/calls.log")" in
    *"tab close t-new"*) pass "ensure rolls back the tab it could not record" ;;
    *) fail "ensure left an unrecorded monitor tab behind: $(cat "$FAKE_STATE/calls.log")" ;;
  esac
  case "$(cat "$FAKE_STATE/calls.log")" in
    *"pane run"*) fail "ensure started a view in a tab it could not record" ;;
    *) pass "ensure never starts an unrecorded view" ;;
  esac
fi

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
PATH="$FAKEBIN:$PATH" FM_HOME="$home5" "$MON" render 2>&1 | head -1 | grep -F '[2ndmate-acme]' >/dev/null \
  || fail "secondmate render mislabeled the home"
pass "secondmate home renders under its own workspace label"
PATH="$FAKEBIN:$PATH" FM_HOME="$home5" HERDR_SESSION=lab "$MON" ensure >/dev/null 2>&1 \
  || fail "secondmate ensure failed"
case "$(cat "$home5/state/.nm-monitor")" in
  lab*) pass "secondmate record binds its own session" ;;
  *) fail "secondmate record wrong: $(cat "$home5/state/.nm-monitor")" ;;
esac
