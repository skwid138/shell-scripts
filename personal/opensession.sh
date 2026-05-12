#!/usr/bin/env bash
# opensession.sh — daily-driver orchestrator for an opencode web+attach session.
#
# The docker-compose-up of the opencode wrapper trio: ensures a daemon is
# running on $OPENCODE_WEB_PORT, then attaches a local TUI. Designed to be
# the alias the user invokes 99% of the time; `openweb` and `openattach`
# remain available for explicit standalone use.
#
# Decision tree:
#   no daemon on :$PORT     → background-spawn openweb, wait for listener,
#                             wait briefly for its sidecar, exec openattach.
#                             (Race-safe: listener-identity verified before we
#                             treat the port as "up".)
#   fresh daemon on :$PORT  → exec openattach silently.
#   stale daemon on :$PORT  → exec openattach and let openattach's prompt
#                             handle it. (Don't duplicate prompt logic here.)
#
# Flags:
#   -r, --restart   Call `openweb --restart` (kill + respawn the daemon),
#                   wait for the new listener, exec openattach. Use after
#                   editing config and wanting a clean refresh. Prints an
#                   info line because this disconnects any other clients.
#   -f, --force     Pass-through to `openattach --force` (bypass staleness
#                   check). Equivalent to OPENCODE_ATTACH_FORCE=1.
#   -h, --help      Show this help.
#
# Process model: the daemon self-daemonizes (PPID=1, owned by launchd). This
# wrapper background-spawns `openweb` only when needed; once `openweb` exits
# (after writing its sidecar), the daemon is on its own. Subsequent
# `opensession` invocations from any terminal will find the running daemon
# via its port listener and attach directly.
#
# Companion scripts:
#   personal/opencode-web.sh    starts the daemon (also reachable as `openweb`).
#   personal/opencode-attach.sh attaches the TUI (also reachable as `openattach`).
#
# Environment overrides:
#   OPENCODE_WEB_PORT         Port to query/spawn on        (default: 4096)
#   OPENCODE_WEB_HOSTNAME     Hostname (passed to openweb)  (default: 127.0.0.1)
#   OPENCODE_ATTACH_FORCE     Set to 1 to bypass staleness  (same as --force)
#
# Exit codes follow lib/common.sh:
#   0  success (clean exec into opencode attach, or deliberate openattach abort)
#   1  generic runtime failure
#   2  usage error (unknown flag)
#   3  missing dependency
#   5  upstream failure: daemon failed to bind within timeout, OR a non-opencode
#      listener grabbed the port between our pre-check and the bind

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/opencode-daemon.sh
source "$SCRIPT_DIR/../lib/opencode-daemon.sh"

usage() {
  cat <<'EOF'
Usage: opensession [OPTIONS]

Ensure an opencode web daemon is running on $OPENCODE_WEB_PORT, then attach
a local TUI to it. The docker-compose-up of the opencode wrapper trio.

Options:
  -r, --restart   Kill the running daemon (if any), wait for the port to
                  free, spawn a fresh one, then attach. Use after editing
                  config files when you want a clean refresh.
  -f, --force     Pass through to `openattach --force` — bypass the
                  staleness check. Equivalent to setting OPENCODE_ATTACH_FORCE=1.
  -h, --help      Show this help.

Default behavior: query the port; if no daemon, background-spawn `openweb`
and wait for the listener to bind (≤5s, listener-identity verified), then
wait briefly for its sidecar (≤2s) and exec `openattach`. On stale daemon,
openattach handles the prompt itself — this wrapper stays declarative.

Environment overrides:
  OPENCODE_WEB_PORT         Port to query/spawn on        (default: 4096)
  OPENCODE_WEB_HOSTNAME     Hostname (passed to openweb)  (default: 127.0.0.1)
  OPENCODE_ATTACH_FORCE     Set to 1 to bypass staleness  (same as --force)

See: ~/.config/opencode/README.md → "OpenCode daemon and the wrapper trio"
EOF
}

# --- arg parsing ---
RESTART=0
FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -r | --restart)
      RESTART=1
      shift
      ;;
    -f | --force)
      FORCE=1
      shift
      ;;
    *)
      die_usage "unknown flag: $1"
      ;;
  esac
done

PORT="${OPENCODE_WEB_PORT:-4096}"

# --- locate sibling wrappers -------------------------------------------------
# Use absolute paths so opensession works regardless of $PATH (matters because
# this script may be invoked as `~/code/scripts/personal/opensession.sh`
# directly without the alias in scope, e.g. from cron or another script).
#
# OPENSESSION_OPENWEB_BIN / OPENSESSION_OPENATTACH_BIN env overrides exist
# strictly for the bats suite — they let tests substitute stub wrappers without
# copying this script into a sandbox. NOT a documented user-facing knob; if
# you find yourself reaching for them outside tests, file an issue first.
OPENWEB="${OPENSESSION_OPENWEB_BIN:-$SCRIPT_DIR/opencode-web.sh}"
OPENATTACH="${OPENSESSION_OPENATTACH_BIN:-$SCRIPT_DIR/opencode-attach.sh}"
[[ -x "$OPENWEB" ]] || die_missing_dep "openweb wrapper not found or not executable: $OPENWEB"
[[ -x "$OPENATTACH" ]] || die_missing_dep "openattach wrapper not found or not executable: $OPENATTACH"

# Compose the openattach argv once — used in every branch below.
# Bash 3.2 idiom: build the array, expand with the conditional form at the
# `exec` site so an empty array doesn't trip `set -u`.
ATTACH_ARGS=()
if [[ "$FORCE" == "1" ]]; then
  ATTACH_ARGS+=("--force")
fi

# --- restart path ------------------------------------------------------------
# --restart is straightforward: delegate the kill+respawn to openweb (it owns
# that logic, including foreign-listener handling), then attach. Race-safety
# comes from openweb's own opencode_wait_for_opencode_listener call before it
# writes the sidecar and exits.
if [[ "$RESTART" == "1" ]]; then
  info "Restarting opencode daemon on :${PORT}…"
  "$OPENWEB" --restart || die_upstream "openweb --restart failed (exit $?)"
  # openweb exits only after the listener is bound + sidecar written, so
  # we can attach immediately. No additional wait needed here.
  exec "$OPENATTACH" ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}
fi

# --- default path: ensure-then-attach ----------------------------------------
# Query the helper for an opencode-web listener on $PORT. Returns the pid on
# success (some opencode process is bound there); non-zero if nothing's
# listening, or a foreign process holds the port. We distinguish those two
# cases via `opencode_port_listener_pid` so a foreign listener gets a clean
# error rather than a misleading spawn attempt.
if EXISTING_PID="$(opencode_daemon_pid_for_port "$PORT" 2>/dev/null)"; then
  # Daemon is up. Fresh or stale → either way, openattach handles it. If stale,
  # openattach's prompt fires; if fresh, it attaches silently. opensession
  # does NOT duplicate that decision tree.
  :
else
  # No opencode listener. Check whether ANY process holds the port — if so,
  # surface the foreign-listener error rather than trying to spawn (which
  # would fail to bind, then opencode_wait_for_opencode_listener would
  # fail-fast with the listener-identity message anyway, but with worse UX).
  FOREIGN_PID="$(opencode_port_listener_pid "$PORT" 2>/dev/null || true)"
  if [[ -n "$FOREIGN_PID" ]]; then
    foreign_comm="$(ps -o comm= -p "$FOREIGN_PID" 2>/dev/null | tr -d '[:space:]')"
    die_upstream "port :$PORT taken by pid $FOREIGN_PID (${foreign_comm##*/}), not opencode — kill it or use OPENCODE_WEB_PORT=…"
  fi

  # Port is free; spawn a daemon. Use the pinned form (Saruman Should Address
  # #5): nohup + background + disown, no subshell, single layout. The log
  # captures openweb's stdout/stderr including the keychain miss / port-bound
  # banner / spawn diagnostics — distinct from the daemon's own log under
  # ~/.local/share/opencode/log/, which opencode itself owns.
  LOG_DIR="${OPENCODE_DAEMON_STATE_DIR:-$HOME/.local/share/opencode}/log"
  mkdir -p "$LOG_DIR" || die "cannot create log dir: $LOG_DIR"
  LOG="$LOG_DIR/opensession-$(/bin/date +%Y%m%d-%H%M%S).log"
  info "No daemon on :$PORT; starting one (log: $LOG)…"

  # The pinned form. DO NOT rewrite this as a subshell or `(…) &` — bash 3.2
  # portability is pinned by a regression test in tests/opensession.bats.
  nohup "$OPENWEB" </dev/null >>"$LOG" 2>&1 &
  DAEMON_PID=$!
  disown "$DAEMON_PID"

  # Wait for the listener to bind AND verify it's opencode (not some racing
  # third-party). Same helper openweb uses internally; calling it here closes
  # the race window between our pre-check and the actual bind. On fast fail
  # the helper emits die_upstream with the offending pid+comm; on timeout it
  # returns non-zero and we surface a "daemon failed to bind" message with
  # the log path so the user can look.
  LISTENER_PID_FILE="$LOG_DIR/opensession-listener-pid.$$"
  if ! opencode_wait_for_opencode_listener "$PORT" 5 >"$LISTENER_PID_FILE"; then
    rm -f "$LISTENER_PID_FILE"
    die_upstream "daemon failed to bind :$PORT within 5s; see $LOG"
  fi
  LISTENER_PID="$(<"$LISTENER_PID_FILE")"
  rm -f "$LISTENER_PID_FILE"
  info "daemon started on :$PORT; attaching…"

  # openweb writes the config-hash sidecar after the listener binds. Wait
  # briefly so openattach's staleness check doesn't observe the in-between
  # state as a false missing-sidecar stale daemon warning.
  SIDECAR="$(_opencode_sidecar_path "$PORT" "$LISTENER_PID")"
  SIDECAR_WAIT_ATTEMPTS=20
  while [[ ! -f "$SIDECAR" && "$SIDECAR_WAIT_ATTEMPTS" -gt 0 ]]; do
    sleep 0.1
    SIDECAR_WAIT_ATTEMPTS=$((SIDECAR_WAIT_ATTEMPTS - 1))
  done
  if [[ ! -f "$SIDECAR" ]]; then
    warn "config-hash sidecar for daemon on :$PORT (pid $LISTENER_PID) did not appear within 2s; attaching anyway"
  fi
fi

# --- attach ------------------------------------------------------------------
# Single `exec` site for both fresh-daemon and just-spawned-daemon paths.
# `exec` replaces this wrapper with the openattach process so the user's TUI
# gets the terminal cleanly; opensession does not linger in the process tree.
exec "$OPENATTACH" ${ATTACH_ARGS[@]+"${ATTACH_ARGS[@]}"}
