#!/usr/bin/env bash
# fm-nm-herdr-monitor.sh - home-scoped, display-only No-Mistakes monitor for Herdr.
#
# A captain-facing pane he can visit at any time. Whenever No-Mistakes runs for
# this home, the active run appears there automatically without entering the
# implementation worker's pane.
#
# Placement: one tab labeled `nm-monitor` holding one pane, inside this home's
# OWN Herdr workspace (the `firstmate` workspace for the primary home, or the
# `2ndmate-<id>` workspace for a secondmate home). That workspace is ADOPTED,
# never created: when it does not exist this script changes nothing, so homes
# that never use Herdr and task placement are unchanged.
#
# Convergence: `ensure` is idempotent.
# It reuses the recorded endpoint when its session matches and its pane, tab, and workspace binding is still exact, and only resolves this home's workspace when a fresh tab has to be created under the serialized convergence lock.
# Creation uses --no-focus and never moves focus.
# The record at state/.nm-monitor holds exact session, workspace, tab, and pane ids; labels and tokens are never authority.
#
# Display: `render` checks this home's state/*.meta ship tasks concurrently through bin/fm-crew-state.sh and prints only active, attributed No-Mistakes run-step states.
# Current and future runs appear with no registration step, and multiple concurrent runs are all listed.
#
# Read-only pipeline contract: this script only ever runs `no-mistakes runs`,
# `no-mistakes axi status`, `no-mistakes axi logs --step ci`, and
# `no-mistakes daemon status`. It never runs, responds, aborts, syncs, reruns,
# merges, or pushes, so the monitor can never race an implementation worker's
# gate decision or take pipeline ownership.
#
# Failure contract: every Herdr and No-Mistakes read is best-effort and
# fail-open. `ensure` exits 0 with a warning when Herdr is absent, the session
# is unreachable, or the home workspace does not exist, so monitor failure can
# never block implementation, validation, or fleet supervision.
#
# Recovery: after a pane, Firstmate, Herdr, or No-Mistakes restart, the next `ensure` revalidates the record against the live session and converges a recorded monitor tab again.
# `watch` re-renders from live state every refresh, so a restarted daemon's runs reappear on their own.
#
# Usage:
#   fm-nm-herdr-monitor.sh ensure
#   fm-nm-herdr-monitor.sh render
#   fm-nm-herdr-monitor.sh watch
#   fm-nm-herdr-monitor.sh -h|--help|help
#
# `ensure` converges the monitor tab and starts `watch` inside it.
# `render` prints one snapshot to stdout.
# `watch` clears and re-renders every 10 seconds until killed.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *) FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
    echo "error: FM_HOME directory cannot be resolved: $FM_HOME" >&2
    exit 2
  } ;;
esac
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# bin/backends/herdr.sh is the single owner of the Herdr client (binary
# resolution plus the protocol_mismatch retry) and of this home's workspace
# label. Sourced, never re-implemented.
# shellcheck source=bin/backends/herdr.sh
. "$FM_ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_ROOT/bin/fm-timeout-lib.sh"
MONITOR_LABEL="nm-monitor"
MONITOR_RECORD="$STATE/.nm-monitor"
MONITOR_INTERVAL_DEFAULT=10
MONITOR_SCAN_WIDTH=4
MONITOR_LOCK_WAIT_SECONDS=10

fm_nm_monitor_usage() {
  sed -n '/^# Usage:/,/^# `ensure`/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_nm_monitor_record_read() {
  FM_NM_MON_SESSION=""; FM_NM_MON_WS=""; FM_NM_MON_TAB=""; FM_NM_MON_PANE=""
  [ -f "$MONITOR_RECORD" ] && [ ! -L "$MONITOR_RECORD" ] || return 1
  [ "$(wc -l < "$MONITOR_RECORD" 2>/dev/null | tr -d '[:space:]')" = 4 ] || return 2
  FM_NM_MON_SESSION=$(sed -n '1p' "$MONITOR_RECORD" 2>/dev/null)
  FM_NM_MON_WS=$(sed -n '2p' "$MONITOR_RECORD" 2>/dev/null)
  FM_NM_MON_TAB=$(sed -n '3p' "$MONITOR_RECORD" 2>/dev/null)
  FM_NM_MON_PANE=$(sed -n '4p' "$MONITOR_RECORD" 2>/dev/null)
  [ -n "$FM_NM_MON_SESSION" ] && [ -n "$FM_NM_MON_WS" ] \
    && [ -n "$FM_NM_MON_TAB" ] && [ -n "$FM_NM_MON_PANE" ] || return 2
  local field
  for field in "$FM_NM_MON_SESSION" "$FM_NM_MON_WS" "$FM_NM_MON_TAB" "$FM_NM_MON_PANE"; do
    case "$field" in
      *['	 ']*|*'*'*) return 2 ;;
    esac
  done
  return 0
}

fm_nm_monitor_record_write() {
  mkdir -p "$STATE" 2>/dev/null || return 1
  local tmp
  tmp=$(mktemp "$STATE/.nm-monitor.pending.XXXXXX") 2>/dev/null || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  printf '%s\n%s\n%s\n%s\n' "$1" "$2" "$3" "$4" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$MONITOR_RECORD" || { rm -f "$tmp"; return 1; }
}

fm_nm_monitor_pane_bound() {
  local session=$1 wsid=$2 tab=$3 pane=$4 out
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -e --arg pane "$pane" --arg tab "$tab" --arg wsid "$wsid" '
    .result.pane.pane_id == $pane
    and .result.pane.tab_id == $tab
    and .result.pane.workspace_id == $wsid
  ' >/dev/null 2>&1
}

# Restart recovery for a recorded pane: a Herdr or FirstMate restart leaves the
# recorded tab structurally present but its watch loop gone, which a restored
# layout presents as a lone idle shell. fm_backend_herdr_pane_idle_shell_pid is
# the single owner of that proof (lone recognized shell, no child process, no
# foreground command), so a pane still running the watch loop - or hosting any
# other live process - fails the proof and is left untouched.
fm_nm_monitor_refresh_view_if_stale() {
  local session=$1 pane=$2 cmd
  fm_backend_herdr_pane_idle_shell_pid "$session" "$pane" >/dev/null 2>&1 || return 0
  cmd=$(printf 'exec env FM_HOME=%q %q watch' "$FM_HOME" "$SCRIPT_DIR/fm-nm-herdr-monitor.sh")
  fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1 || true
}

fm_nm_monitor_home_workspace_id() {
  local session=$1 launcher_status matches count
  if fm_backend_herdr_launcher_identity "$session" 2>/dev/null; then
    printf '%s' "$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID"
    return 0
  else
    launcher_status=$?
  fi
  [ "$launcher_status" -eq 2 ] || return 1
  matches=$(fm_backend_herdr_workspace_find_all "$session") || return 1
  count=$(printf '%s\n' "$matches" | grep -c '[^[:space:]]')
  [ "$count" = 1 ] || return 1
  printf '%s' "$matches"
}

fm_nm_monitor_view_of_state_line() {
  local line=$1 state source detail
  state=$(printf '%s' "$line" | sed -n 's/^state: *\([^ ·]*\).*/\1/p')
  source=$(printf '%s' "$line" | sed -n 's/^state: [^ ·]* · source: *\([^ ·]*\).*/\1/p')
  detail=$(printf '%s' "$line" | sed -n 's/^state: [^ ·]* · source: [^ ·]* · //p')
  [ "$source" = run-step ] || return 1
  case "$state" in
    working) printf 'active | %s' "${detail:-validating}" ;;
    parked) printf 'gate-waiting | %s' "${detail:-parked at gate}" ;;
    *) return 1 ;;
  esac
}

fm_nm_monitor_task_ids() {
  local meta id kind
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(grep '^kind=' "$meta" 2>/dev/null | tail -1 | cut -d= -f2-)
    [ -n "$kind" ] || kind=ship
    [ "$kind" = ship ] || continue
    printf '%s\n' "$id"
  done | sort -u
}

fm_nm_monitor_crew_state() {
  local id=$1 out cmd=${FM_NM_MONITOR_CREW_STATE:-$SCRIPT_DIR/fm-crew-state.sh}
  out=$(fm_run_timed 20 "$cmd" "$id" 2>/dev/null) || out=""
  [ -n "$out" ] || out="state: unknown · source: none · no current-state source available"
  printf '%s' "$out" | head -1
}

fm_nm_monitor_render_task() {
  local id=$1 line view
  line=$(fm_nm_monitor_crew_state "$id")
  view=$(fm_nm_monitor_view_of_state_line "$line") || return 0
  printf '%s | %s\n' "$id" "$view"
}

fm_nm_monitor_render() {
  local label now id render_dir result index=0 active=0 inflight=0
  label=$(fm_backend_herdr_workspace_label)
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
  printf 'No-Mistakes monitor · home workspace [%s] · %s\n' "$label" "$now"
  printf 'Display-only: this pane never answers a gate. Respond from the worker pane.\n'
  printf -- '---\n'
  render_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-nm-monitor-render.XXXXXX") || {
    printf 'idle | active run state unavailable\n'
    return 0
  }
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    index=$((index + 1))
    fm_nm_monitor_render_task "$id" > "$render_dir/$(printf '%08d' "$index")" &
    inflight=$((inflight + 1))
    if [ "$inflight" -ge "$MONITOR_SCAN_WIDTH" ]; then
      wait
      inflight=0
    fi
  done <<EOF
$(fm_nm_monitor_task_ids)
EOF
  wait
  for result in "$render_dir"/*; do
    [ -s "$result" ] || continue
    cat "$result"
    active=$((active + 1))
  done
  rm -f "$render_dir"/*
  rmdir "$render_dir"
  [ "$active" -ne 0 ] || printf 'idle | no active No-Mistakes runs\n'
}

fm_nm_monitor_watch() {
  trap 'printf "\nmonitor closed.\n"; exit 0' INT TERM
  while true; do
    printf '\033[2J\033[H'
    fm_nm_monitor_render
    printf '\n(refresh every %ss · read-only · Ctrl-C closes this view, never the runs)\n' "$MONITOR_INTERVAL_DEFAULT"
    sleep "$MONITOR_INTERVAL_DEFAULT"
  done
}

fm_nm_monitor_ensure_locked() {
  local session=$1 label wsid out new_tab new_pane cmd
  if fm_nm_monitor_record_read 2>/dev/null; then
    if [ "$FM_NM_MON_SESSION" = "$session" ] \
      && fm_nm_monitor_pane_bound "$session" "$FM_NM_MON_WS" "$FM_NM_MON_TAB" "$FM_NM_MON_PANE" 2>/dev/null; then
      fm_nm_monitor_refresh_view_if_stale "$session" "$FM_NM_MON_PANE"
      printf 'monitor: reusing live pane %s:%s\n' "$session" "$FM_NM_MON_PANE"
      return 0
    fi
  fi
  label=$(fm_backend_herdr_workspace_label)
  wsid=$(fm_nm_monitor_home_workspace_id "$session") || {
    echo "warning: fm-nm-herdr-monitor: home workspace '$label' could not be resolved in session '$session'; leaving non-Herdr layout unchanged" >&2
    return 0
  }
  out=$(fm_backend_herdr_cli "$session" tab create --workspace "$wsid" --cwd "$FM_HOME" --label "$MONITOR_LABEL" --no-focus 2>/dev/null) || {
    echo "warning: fm-nm-herdr-monitor: could not create the monitor tab; skipping" >&2
    return 0
  }
  new_tab=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty' 2>/dev/null)
  new_pane=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)
  if [ -z "$new_tab" ] || [ -z "$new_pane" ]; then
    echo "warning: fm-nm-herdr-monitor: monitor create returned incomplete ids; skipping" >&2
    return 0
  fi
  if ! fm_nm_monitor_record_write "$session" "$wsid" "$new_tab" "$new_pane"; then
    echo "warning: fm-nm-herdr-monitor: could not publish the monitor record at $MONITOR_RECORD; closing the new tab so unrecorded monitors cannot accumulate" >&2
    fm_backend_herdr_cli "$session" tab close "$new_tab" >/dev/null 2>&1 || true
    return 0
  fi
  cmd=$(printf 'exec env FM_HOME=%q %q watch' "$FM_HOME" "$SCRIPT_DIR/fm-nm-herdr-monitor.sh")
  if ! fm_backend_herdr_cli "$session" pane run "$new_pane" "$cmd" >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: monitor tab created but the view did not start; visit it and run: bin/fm-nm-herdr-monitor.sh watch" >&2
    return 0
  fi
  printf 'monitor: created %s:%s in workspace %s\n' "$session" "$new_pane" "$wsid"
  return 0
}

fm_nm_monitor_ensure() {
  local session lock rc
  if ! command -v herdr >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: herdr CLI not installed; skipping the No-Mistakes monitor (non-Herdr home unchanged)" >&2
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: jq not installed; skipping the No-Mistakes monitor" >&2
    return 0
  fi
  session=${HERDR_SESSION:-default}
  if ! fm_backend_herdr_cli "$session" status --json >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: herdr session '$session' unreachable; skipping the monitor" >&2
    return 0
  fi
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_ROOT/bin/fm-wake-lib.sh"
  lock="$STATE/.nm-monitor.lock"
  fm_lock_acquire_wait_bounded "$lock" "$MONITOR_LOCK_WAIT_SECONDS" || {
    echo "warning: fm-nm-herdr-monitor: could not lock monitor convergence; skipping" >&2
    return 0
  }
  if fm_nm_monitor_ensure_locked "$session"; then
    rc=0
  else
    rc=$?
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

fm_nm_monitor_main() {
  local cmd=${1:-help}
  shift 2>/dev/null || true
  [ "$#" -eq 0 ] || { echo "error: unknown argument '$1' (see --help)" >&2; return 2; }
  case "$cmd" in
    ensure) fm_nm_monitor_ensure ;;
    render) fm_nm_monitor_render ;;
    watch) fm_nm_monitor_watch ;;
    -h|--help|help) fm_nm_monitor_usage ;;
    *) echo "error: unknown command '$cmd' (see --help)" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_nm_monitor_main "$@"
fi
