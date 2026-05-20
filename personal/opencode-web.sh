#!/usr/bin/env bash
# opencode-web.sh — start opencode's web UI for remote access (typically via Tailscale Serve).
#
# Loads the server password lazily from macOS Keychain. This intentionally does
# NOT rely on shell-startup env population, matching the policy in
# scripts/shell/env/vars.zsh of NEVER eagerly populating secrets at shell init.
#
# Process model (verified empirically 2026-05-10):
#   opencode's `web` daemon SELF-DAEMONIZES. After binding the listener,
#   PPID becomes 1 (launchd) and the controlling TTY is detached. Closing
#   the launching terminal does NOT reliably kill it. To stop a daemon:
#     - `openweb --restart`   (graceful refresh)
#     - `opensession --restart`
#     - `kill <pid>` against the listener pid (`lsof -ti tcp:<port> -sTCP:LISTEN`)
#
#   This wrapper therefore spawns the daemon, waits for the listener to bind,
#   verifies its identity via `ps -o comm=` (NOT pgrep -f, which matches the
#   caffeinate wrapper too because caffeinate's argv contains `opencode web`),
#   captures the REAL daemon pid, writes the config-hash sidecar at
#   `~/.local/share/opencode/daemon-config-hash-<port>-<pid>`, and EXITS.
#   The daemon outlives the wrapper. The sidecar is what openattach reads
#   to decide whether the running daemon's config is stale.
#
# Companion: `openattach` attaches a local TUI to the same backend. `opensession`
# is the daily-driver orchestrator that ensures-daemon-then-attaches.
#
# Keychain entry consumed:
#   service: opencode-server-password
#   account: $USER
#
# Exit codes follow lib/common.sh:
#   0  success (daemon spawned, sidecar written, wrapper exiting cleanly)
#   1  generic runtime failure (e.g. keychain entry missing)
#   2  usage error (unknown flag)
#   3  missing dependency (opencode, caffeinate, `security`, or a tool the
#      shared helper needs — pgrep/lsof/ps/date/stat/shasum)
#   5  upstream failure (port already bound, foreign listener, kill timeout,
#      or daemon failed to bind within the wait window)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/keychain.sh
source "$SCRIPT_DIR/../lib/keychain.sh"
# shellcheck source=../lib/opencode-daemon.sh
source "$SCRIPT_DIR/../lib/opencode-daemon.sh"

usage() {
  cat <<'EOF'
Usage: opencode-web.sh [OPTIONS]

Start opencode's web UI on a localhost port, wrapped in `caffeinate -is`,
with the server password loaded from macOS Keychain. Intended to be invoked
via the `openweb` alias.

On successful start, records a content-hash snapshot of ~/.config/opencode/
at `~/.local/share/opencode/daemon-config-hash-<port>-<pid>` so `openattach`
can detect when the running daemon's config has gone stale.

Options:
  -r, --restart   Kill any running daemon on $port, wait for the port to
                  free, then start fresh. Use this after editing config
                  files. Prints an info line if no daemon was running.
  -f, --force     If port is already bound (by anything), bypass the refusal
                  and start anyway. Honors $OPENCODE_WEB_FORCE=1 as well.
  -h, --help      Show this help.

Default behavior: if a daemon is already bound to $port, refuse to start
and print a hint about --restart. If some OTHER process holds the port,
refuse with a distinct error that names the offending pid + comm.

Environment overrides:
  OPENCODE_WEB_PORT         Port to listen on            (default: 4096)
  OPENCODE_WEB_HOSTNAME     Hostname to bind             (default: 127.0.0.1)
  OPENCODE_SERVER_USERNAME  Basic Auth username          (default: opencode)
  OPENCODE_WEB_FORCE        Set to 1 to bypass the port-bound refusal.

Keychain entry required:
  security add-generic-password \
    -s 'opencode-server-password' -a "$USER" -w '<password>' -U

See: ~/.config/opencode/README-remote-access.md
EOF
}

# --- arg parsing ---
RESTART=0
FORCE="${OPENCODE_WEB_FORCE:-0}"
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
HOST="${OPENCODE_WEB_HOSTNAME:-127.0.0.1}"

# --- preflight ---
require_cmd opencode "Install with: brew install anomalyco/tap/opencode"
require_cmd caffeinate
require_cmd security

# Load password from Keychain. keychain_get die()s with a clear hint on miss.
OPENCODE_SERVER_PASSWORD="$(keychain_get 'opencode-server-password')" || exit $?
export OPENCODE_SERVER_PASSWORD
export OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"

# --- friendly startup banner -------------------------------------------------
# Best-effort tailnet FQDN lookup. Non-fatal if Tailscale is missing or the
# JSON shape changes — never block startup.
TS_FQDN=""
if command -v tailscale >/dev/null 2>&1; then
  TS_FQDN="$(
    tailscale status --json 2>/dev/null |
      /usr/bin/python3 -c \
        'import json,sys
try:
  d=json.load(sys.stdin)
  print(d.get("Self",{}).get("DNSName","").rstrip("."))
except Exception:
  pass' 2>/dev/null || true
  )"
fi

info "Starting opencode web (caffeinated) on ${HOST}:${PORT}"
info "  Local:    http://${HOST}:${PORT}"
[[ -n "$TS_FQDN" ]] && info "  Tailnet:  https://${TS_FQDN}"
info "  User:     ${OPENCODE_SERVER_USERNAME}"

# --- port-state handling ----------------------------------------------------
#
# Decision tree before we spawn anything:
#   --restart                     → kill existing daemon (if any), proceed
#   --force / OPENCODE_WEB_FORCE  → bypass refusal entirely, proceed
#   port held by opencode-web     → refuse with "use --restart" hint        (exit 5)
#   port held by other process    → refuse with "port taken by N (comm)"    (exit 5)
#   port free                     → proceed
#
# This replaces the previous behavior (opencode would bind-and-fail with the
# unhelpful "Unexpected error, check log file" message).
EXISTING_PID="$(opencode_daemon_pid_for_port "$PORT" 2>/dev/null || true)"
LISTENER_PID="$(opencode_port_listener_pid "$PORT" 2>/dev/null || true)"

if [[ "$RESTART" == "1" ]]; then
  # --restart: kill our own daemon (refuse foreign listeners — the user wants
  # to refresh THEIR opencode, not stomp on a sibling process they forgot about).
  if [[ -n "$EXISTING_PID" ]]; then
    info "Restarting: killing daemon on :$PORT (pid $EXISTING_PID)…"
    if ! opencode_kill_daemon "$EXISTING_PID" "$PORT" 5; then
      die_upstream "failed to kill daemon (pid $EXISTING_PID) on :$PORT within 5s"
    fi
  elif [[ -n "$LISTENER_PID" ]]; then
    foreign_comm="$(ps -o comm= -p "$LISTENER_PID" 2>/dev/null | tr -d '[:space:]')"
    die_upstream "port :$PORT taken by pid $LISTENER_PID (${foreign_comm##*/}), not opencode — use \`openweb --force\` to kill it, or OPENCODE_WEB_PORT=…"
  else
    info "no daemon to kill on :$PORT; starting fresh"
  fi
elif [[ "$FORCE" == "1" ]]; then
  # --force: kill ANY holder (opencode-web daemon OR foreign listener) and
  # respawn. The previous implementation just bypassed the refusal and let
  # opencode try to bind-and-fail; the wrapper then silently adopted the
  # pre-existing daemon via opencode_wait_for_opencode_listener and lied about
  # success. See plan §"What we learned" 2026-05-10 force-defect entry.
  if [[ -n "$EXISTING_PID" ]]; then
    info "Force: killing opencode daemon on :$PORT (pid $EXISTING_PID)…"
    if ! opencode_kill_daemon "$EXISTING_PID" "$PORT" 5; then
      die_upstream "failed to kill daemon (pid $EXISTING_PID) on :$PORT within 5s"
    fi
  elif [[ -n "$LISTENER_PID" ]]; then
    foreign_comm="$(ps -o comm= -p "$LISTENER_PID" 2>/dev/null | tr -d '[:space:]')"
    info "Force: killing foreign listener on :$PORT (pid $LISTENER_PID, ${foreign_comm##*/})…"
    kill -TERM "$LISTENER_PID" 2>/dev/null || true
    if ! opencode_wait_for_port_free "$PORT" 5; then
      die_upstream "failed to free :$PORT (foreign pid $LISTENER_PID, ${foreign_comm##*/}) within 5s"
    fi
  fi
else
  # Default path: refuse if anything holds the port.
  if [[ -n "$EXISTING_PID" ]]; then
    # An opencode-web daemon already holds the port.
    started_epoch="$(opencode_daemon_start_epoch "$EXISTING_PID" 2>/dev/null || true)"
    if [[ -n "$started_epoch" ]]; then
      started_human="$(/bin/date -r "$started_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || printf 'unknown')"
    else
      started_human="unknown"
    fi
    die_upstream "daemon already on :$PORT (pid $EXISTING_PID, started $started_human). Use \`openweb --restart\` to refresh, or \`openweb --force\` to start anyway."
  elif [[ -n "$LISTENER_PID" ]]; then
    # SOME process holds the port but it's not opencode-web.
    foreign_comm="$(ps -o comm= -p "$LISTENER_PID" 2>/dev/null | tr -d '[:space:]')"
    die_upstream "port :$PORT taken by pid $LISTENER_PID (${foreign_comm##*/}), not opencode — kill it or use OPENCODE_WEB_PORT=…"
  fi
fi

# --- spawn-and-monitor ------------------------------------------------------
#
# opencode self-daemonizes: after binding the listener, PPID becomes 1 and the
# controlling TTY is detached. We therefore DON'T exec into caffeinate — we
# background the chain, wait for the listener to bind, capture the REAL
# daemon pid (NOT $$, NOT the caffeinate pid), write the sidecar, and exit.
# The 2026-05-10 empirical verification (plan §"What we learned" #8) confirmed
# wrapper $$ ≠ daemon pid across 5 iterations.
info "Press Ctrl+C to stop. (Daemon will reparent to launchd; close the terminal at will.)"

# Suppress opencode's auto-browser-open by shadowing `open` in PATH.
# The shim dir is intentionally NOT cleaned up — opencode resolves `open` lazily
# (seconds after fork, once the listener binds), so the file must persist on disk.
# It's one 27-byte file in $TMPDIR; cleaned on reboot.
_OPEN_SHIM_DIR="$(mktemp -d)"
printf '#!/usr/bin/env bash\nexit 0\n' >"$_OPEN_SHIM_DIR/open"
chmod +x "$_OPEN_SHIM_DIR/open"

PATH="$_OPEN_SHIM_DIR:$PATH" caffeinate -is opencode web --port "$PORT" --hostname "$HOST" &
CAFFEINATE_PID=$!
# Do NOT `wait` on $CAFFEINATE_PID — once opencode reparents to launchd
# caffeinate may exit on its own (its child is gone), and we'd block forever
# (or unblock too early and prematurely-write-then-exit before the listener binds).

# Wait for the daemon to bind AND verify the listener is actually opencode.
# The helper returns the REAL daemon pid for the sidecar write.
if ! DAEMON_PID="$(opencode_wait_for_opencode_listener "$PORT" 5)"; then
  # Diagnostic: distinguish "opencode never started" from "opencode is slow".
  # If caffeinate is already gone, opencode failed to spawn (bad config,
  # missing binary, crash on startup) — surface that instead of the generic
  # 5s timeout.
  if ! kill -0 "$CAFFEINATE_PID" 2>/dev/null; then
    die_upstream "caffeinate exited prematurely (pid $CAFFEINATE_PID); opencode likely failed to start — check shell history or stderr"
  fi
  die_upstream "daemon failed to bind :$PORT within 5s"
fi

# Write the sidecar with the REAL daemon pid. NO `|| true` masking — under
# `set -euo pipefail` a failure here aborts the wrapper, leaving the daemon
# alive without a sidecar; the next openattach will warn + treat as stale.
# That's the intended failure mode. Swallowing the error hides real disk /
# permission failures.
opencode_daemon_write_sidecar "$PORT" "$DAEMON_PID"

info "daemon started on :$PORT (pid $DAEMON_PID); sidecar written"
# Wrapper exits cleanly; daemon is already (or imminently) reparented to launchd.
