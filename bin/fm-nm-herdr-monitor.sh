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
# It reuses the recorded endpoint when its pane, tab, and workspace binding is still exact, otherwise adopts the single live `nm-monitor` tab in the home workspace, closes surplus husk duplicates by exact id, and creates one fresh tab only when none is live.
# Creation uses --no-focus and never moves focus.
# The record at state/.nm-monitor holds exact session, workspace, tab, and pane ids; labels and tokens are never authority.
#
# Display: `render` enumerates this home's state/*.meta ship tasks on every
# refresh and reads each through bin/fm-crew-state.sh, so current and future
# runs appear with no registration step and multiple concurrent runs are all
# listed. Views are idle (no run), active (working), gate-waiting (parked),
# failed, CI-ready (done with checks green), and completed (other done).
# Blocked, paused, and unknown read exactly as crew-state reports them.
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
# Recovery: after a pane, Firstmate, Herdr, or No-Mistakes restart, the next
# `ensure` revalidates the record against the live session and converges to
# exactly one monitor tab again; `watch` re-renders from live state every
# refresh, so a restarted daemon's runs reappear on their own.
#
# Usage:
#   fm-nm-herdr-monitor.sh ensure [--interval <secs>]
#   fm-nm-herdr-monitor.sh render [--state-dir <dir>]
#   fm-nm-herdr-monitor.sh watch [--interval <secs>]
#   fm-nm-herdr-monitor.sh status
#   fm-nm-herdr-monitor.sh -h|--help|help
#
# `ensure` converges the monitor tab and starts `watch` inside it. `render`
# prints one snapshot to stdout. `watch` clears and re-renders until killed.
# `status` prints the recorded endpoint and whether its pane is present.
# Refresh interval defaults to 10 seconds and is clamped to 3-300.
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

fm_nm_monitor_usage() {
  sed -n '/^# Usage:/,/^# `ensure`/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
  echo "Refresh interval defaults to $MONITOR_INTERVAL_DEFAULT seconds and is clamped to 3-300."
}

fm_nm_monitor_interval() {
  local v=${1:-$MONITOR_INTERVAL_DEFAULT}
  case "$v" in ''|*[!0-9]*) v=$MONITOR_INTERVAL_DEFAULT ;; esac
  [ "$v" -lt 3 ] && v=3
  [ "$v" -gt 300 ] && v=300
  printf '%s' "$v"
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

fm_nm_monitor_pane_present() {
  local session=$1 pane=$2 out pid
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  pid=$(printf '%s' "$out" | jq -r '.result.pane.pane_id // empty' 2>/dev/null)
  [ "$pid" = "$pane" ]
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

fm_nm_monitor_pane_is_husk() {
  local session=$1 pane=$2 out code
  out=$(fm_backend_herdr_cli "$session" pane get "$pane" 2>/dev/null) || return 1
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  [ -n "$code" ] && return 0
  out=$(fm_backend_herdr_cli "$session" agent get "$pane" 2>&1)
  code=$(printf '%s' "$out" | jq -r '.error.code // empty' 2>/dev/null)
  [ "$code" = "agent_not_found" ]
}

# Restart recovery for an adopted pane: a Herdr or FirstMate restart leaves the
# recorded tab structurally present but its watch loop gone. When the pane's
# recent output carries no monitor header and no agent is registered in it,
# re-run the watch there; a pane hosting a live agent is left untouched.
fm_nm_monitor_refresh_view_if_stale() {
  local session=$1 pane=$2 interval=$3 cap out cmd
  cap=$(fm_backend_herdr_cli "$session" pane read "$pane" --source recent --lines 30 2>/dev/null) || return 0
  case "$cap" in
    *"No-Mistakes monitor"*) return 0 ;;
  esac
  fm_nm_monitor_pane_is_husk "$session" "$pane" 2>/dev/null || return 0
  cmd=$(printf 'exec env FM_HOME=%q %q watch --interval %q' "$FM_HOME" "$SCRIPT_DIR/fm-nm-herdr-monitor.sh" "$interval")
  fm_backend_herdr_cli "$session" pane run "$pane" "$cmd" >/dev/null 2>&1 || true
}

fm_nm_monitor_home_workspace_id() {
  local session=$1 label=$2 launcher_status out count wsid
  if fm_backend_herdr_launcher_identity "$session" 2>/dev/null; then
    printf '%s' "$FM_BACKEND_HERDR_LAUNCHER_WORKSPACE_ID"
    return 0
  else
    launcher_status=$?
  fi
  [ "$launcher_status" -eq 2 ] || return 1
  out=$(fm_backend_herdr_cli "$session" workspace list 2>/dev/null) || return 1
  count=$(printf '%s' "$out" | jq --arg want "$label" \
    '[.result.workspaces[]? | select(.label == $want)] | length' 2>/dev/null) || return 1
  [ "$count" = 1 ] || return 1
  wsid=$(printf '%s' "$out" | jq -r --arg want "$label" \
    '.result.workspaces[]? | select(.label == $want) | .workspace_id' 2>/dev/null) || return 1
  [ -n "$wsid" ] || return 1
  printf '%s' "$wsid"
}

fm_nm_monitor_live_tabs() {
  local session=$1 wsid=$2 out panes tab pane
  out=$(fm_backend_herdr_cli "$session" tab list --workspace "$wsid" 2>/dev/null) || return 1
  panes=$(fm_backend_herdr_cli "$session" pane list --workspace "$wsid" 2>/dev/null) || return 1
  for tab in $(printf '%s' "$out" | jq -r --arg want "$MONITOR_LABEL" \
    '.result.tabs[]? | select(.label == $want) | .tab_id' 2>/dev/null); do
    [ -n "$tab" ] || continue
    pane=$(printf '%s' "$panes" | jq -r --arg tab "$tab" \
      '.result.panes[]? | select(.tab_id == $tab) | .pane_id' 2>/dev/null | head -1)
    printf '%s\t%s\n' "$tab" "${pane:-}"
  done
}

fm_nm_monitor_view_of_state_line() {
  local line=$1 state detail
  state=$(printf '%s' "$line" | sed -n 's/^state: *\([^ ·]*\).*/\1/p')
  detail=$(printf '%s' "$line" | sed -n 's/^state: [^ ·]* · source: [^ ·]* · //p')
  case "$state" in
    working) printf 'active | %s' "${detail:-validating}" ;;
    parked) printf 'gate-waiting | %s' "${detail:-parked at gate}" ;;
    failed) printf 'failed | %s' "${detail:-run failed}" ;;
    done)
      case "$detail" in
        *checks\ green*) printf 'CI-ready | %s' "$detail" ;;
        *) printf 'completed | %s' "${detail:-run completed}" ;;
      esac
      ;;
    blocked) printf 'blocked | %s' "${detail:-needs firstmate action}" ;;
    paused) printf 'paused | %s' "${detail:-external wait}" ;;
    *) printf 'unknown | %s' "${detail:-state unavailable}" ;;
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

fm_nm_monitor_render() {
  local state_dir=${1:-$STATE}
  STATE="$state_dir"
  MONITOR_RECORD="$STATE/.nm-monitor"
  local label now id line view count=0 active=0
  label=$(fm_backend_herdr_workspace_label)
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
  printf 'No-Mistakes monitor · home workspace [%s] · %s\n' "$label" "$now"
  printf 'Display-only: this pane never answers a gate. Respond from the worker pane.\n'
  printf -- '---\n'
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    line=$(fm_nm_monitor_crew_state "$id")
    view=$(fm_nm_monitor_view_of_state_line "$line")
    case "$view" in active*|gate-waiting*) active=$((active + 1)) ;; esac
    printf '%s | %s\n' "$id" "$view"
  done <<EOF
$(fm_nm_monitor_task_ids)
EOF
  if [ "$count" -eq 0 ]; then
    printf -- 'idle | no ship tasks for this home yet; future runs appear here automatically\n'
  elif [ "$active" -eq 0 ]; then
    printf -- '--\nidle | no active runs; %s tracked task(s) quiet\n' "$count"
  fi
}

fm_nm_monitor_watch() {
  local interval
  interval=$(fm_nm_monitor_interval "${1:-$MONITOR_INTERVAL_DEFAULT}")
  trap 'printf "\nmonitor closed.\n"; exit 0' INT TERM
  while true; do
    printf '\033[2J\033[H'
    fm_nm_monitor_render "$STATE"
    printf '\n(refresh every %ss · read-only · Ctrl-C closes this view, never the runs)\n' "$interval"
    sleep "$interval"
  done
}

fm_nm_monitor_status() {
  local rc session ws tab pane
  fm_nm_monitor_record_read
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'monitor: no record (run ensure to converge one)\n'
    return 0
  fi
  session=$FM_NM_MON_SESSION; ws=$FM_NM_MON_WS; tab=$FM_NM_MON_TAB; pane=$FM_NM_MON_PANE
  if command -v herdr >/dev/null 2>&1 \
    && fm_nm_monitor_pane_bound "$session" "$ws" "$tab" "$pane" 2>/dev/null; then
    printf 'monitor: live session=%s workspace=%s tab=%s pane=%s\n' "$session" "$ws" "$tab" "$pane"
  else
    printf 'monitor: recorded session=%s workspace=%s tab=%s pane=%s (binding not live)\n' "$session" "$ws" "$tab" "$pane"
  fi
}

fm_nm_monitor_ensure_locked() {
  local session=$1 wsid=$2 interval=$3 tabs tab pane kept extras out new_tab new_pane cmd
  if fm_nm_monitor_record_read 2>/dev/null; then
    if [ "$FM_NM_MON_SESSION" = "$session" ] && [ "$FM_NM_MON_WS" = "$wsid" ] \
      && fm_nm_monitor_pane_bound "$session" "$FM_NM_MON_WS" "$FM_NM_MON_TAB" "$FM_NM_MON_PANE" 2>/dev/null; then
      fm_nm_monitor_refresh_view_if_stale "$session" "$FM_NM_MON_PANE" "$interval"
      printf 'monitor: reusing live pane %s:%s\n' "$session" "$FM_NM_MON_PANE"
      return 0
    fi
  fi
  tabs=$(fm_nm_monitor_live_tabs "$session" "$wsid") || tabs=""
  kept=""
  extras=""
  if [ -n "$tabs" ]; then
    while IFS="$(printf '\t')" read -r tab pane; do
      [ -n "$tab" ] || continue
      if [ -z "$kept" ] && [ -n "$pane" ] \
        && fm_nm_monitor_pane_present "$session" "$pane" 2>/dev/null; then
        kept="$tab	$pane"
      elif [ -n "$pane" ]; then
        extras="$extras$tab	$pane
"
      fi
    done <<EOF
$tabs
EOF
  fi
  if [ -n "$kept" ]; then
    tab=${kept%%$'	'*}; pane=${kept#*$'	'}
    fm_nm_monitor_record_write "$session" "$wsid" "$tab" "$pane" || true
    fm_nm_monitor_refresh_view_if_stale "$session" "$pane" "$interval"
    if [ -n "$extras" ]; then
      while IFS="$(printf '\t')" read -r tab pane; do
        [ -n "$tab" ] && [ -n "$pane" ] || continue
        if fm_nm_monitor_pane_is_husk "$session" "$pane" 2>/dev/null; then
          fm_backend_herdr_cli "$session" pane close "$pane" >/dev/null 2>&1 || true
        fi
      done <<EOF
$extras
EOF
    fi
    printf 'monitor: adopted live tab in workspace %s\n' "$wsid"
    return 0
  fi
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
  fm_nm_monitor_record_write "$session" "$wsid" "$new_tab" "$new_pane" || true
  cmd=$(printf 'exec env FM_HOME=%q %q watch --interval %q' "$FM_HOME" "$SCRIPT_DIR/fm-nm-herdr-monitor.sh" "$interval")
  if ! fm_backend_herdr_cli "$session" pane run "$new_pane" "$cmd" >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: monitor tab created but the view did not start; visit it and run: bin/fm-nm-herdr-monitor.sh watch" >&2
    return 0
  fi
  printf 'monitor: created %s:%s in workspace %s\n' "$session" "$new_pane" "$wsid"
  return 0
}

fm_nm_monitor_ensure() {
  local interval session label wsid lock rc
  interval=$(fm_nm_monitor_interval "${1:-$MONITOR_INTERVAL_DEFAULT}")
  if ! command -v herdr >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: herdr CLI not installed; skipping the No-Mistakes monitor (non-Herdr home unchanged)" >&2
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: jq not installed; skipping the No-Mistakes monitor" >&2
    return 0
  fi
  session=${HERDR_SESSION:-default}
  label=$(fm_backend_herdr_workspace_label)
  if ! fm_backend_herdr_cli "$session" status --json >/dev/null 2>&1; then
    echo "warning: fm-nm-herdr-monitor: herdr session '$session' unreachable; skipping the monitor" >&2
    return 0
  fi
  wsid=$(fm_nm_monitor_home_workspace_id "$session" "$label") || {
    echo "warning: fm-nm-herdr-monitor: home workspace '$label' could not be resolved in session '$session'; leaving non-Herdr layout unchanged" >&2
    return 0
  }
  # shellcheck source=bin/fm-wake-lib.sh
  . "$FM_ROOT/bin/fm-wake-lib.sh"
  lock="$STATE/.nm-monitor.lock"
  fm_lock_acquire_wait "$lock" || {
    echo "warning: fm-nm-herdr-monitor: could not lock monitor convergence; skipping" >&2
    return 0
  }
  if fm_nm_monitor_ensure_locked "$session" "$wsid" "$interval"; then
    rc=0
  else
    rc=$?
  fi
  fm_lock_release "$lock" || true
  return "$rc"
}

fm_nm_monitor_main() {
  local cmd=${1:-help} interval="$MONITOR_INTERVAL_DEFAULT" state_dir="$STATE"
  shift 2>/dev/null || true
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --interval)
        [ "$#" -ge 2 ] || { echo "error: --interval requires a value (see --help)" >&2; return 2; }
        interval=$2; shift 2 ;;
      --interval=*) interval=${1#--interval=}; shift ;;
      --state-dir)
        [ "$#" -ge 2 ] || { echo "error: --state-dir requires a value (see --help)" >&2; return 2; }
        state_dir=$2; shift 2 ;;
      --state-dir=*) state_dir=${1#--state-dir=}; shift ;;
      -h|--help|help) fm_nm_monitor_usage; return 0 ;;
      *) echo "error: unknown argument '$1' (see --help)" >&2; return 2 ;;
    esac
  done
  case "$cmd" in
    ensure) fm_nm_monitor_ensure "$interval" ;;
    render) fm_nm_monitor_render "$state_dir" ;;
    watch) fm_nm_monitor_watch "$interval" ;;
    status) fm_nm_monitor_status ;;
    -h|--help|help) fm_nm_monitor_usage ;;
    *) echo "error: unknown command '$cmd' (see --help)" >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_nm_monitor_main "$@"
fi
