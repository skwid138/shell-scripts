#!/usr/bin/env bash
# opencode-web.sh — start opencode's web UI for remote access (typically via Tailscale Serve).
#
# Loads the server password lazily from macOS Keychain. This intentionally does
# NOT rely on shell-startup env population, matching the policy in
# scripts/shell/env/vars.zsh of NEVER eagerly populating secrets at shell init.
#
# Wrapped in `caffeinate -is` so the system stays awake (but the display can
# sleep) for as long as opencode is running. Ctrl+C terminates both.
#
# Companion: `opencode attach http://127.0.0.1:4096` (alias: openattach) lets
# local terminals share the same backend session pool as the web UI.
#
# Keychain entry consumed:
#   service: opencode-server-password
#   account: $USER
#
# Exit codes follow lib/common.sh:
#   0  success / clean exec into caffeinate
#   1  generic runtime failure (e.g. keychain entry missing)
#   2  usage error (unknown flag)
#   3  missing dependency (opencode, caffeinate, or `security`)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/keychain.sh
source "$SCRIPT_DIR/../lib/keychain.sh"

usage() {
  cat <<'EOF'
Usage: opencode-web.sh [OPTIONS]

Start opencode's web UI on a localhost port, wrapped in `caffeinate -is`,
with the server password loaded from macOS Keychain. Intended to be invoked
via the `openweb` alias.

Options:
  -h, --help    Show this help.

Environment overrides:
  OPENCODE_WEB_PORT         Port to listen on            (default: 4096)
  OPENCODE_WEB_HOSTNAME     Hostname to bind             (default: 127.0.0.1)
  OPENCODE_SERVER_USERNAME  Basic Auth username          (default: opencode)

Keychain entry required:
  security add-generic-password \
    -s 'opencode-server-password' -a "$USER" -w '<password>' -U

See: ~/.config/opencode/README-remote-access.md
EOF
}

# --- arg parsing ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
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
info "Press Ctrl+C to stop."

exec caffeinate -is opencode web --port "$PORT" --hostname "$HOST"
