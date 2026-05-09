#!/usr/bin/env bash
# opencode-attach.sh — attach a local TUI to the running `opencode web` backend
# so all clients (web + terminal) share a single session pool.
#
# Loads the server password lazily from macOS Keychain (same source of truth
# as personal/opencode-web.sh), matching the policy in scripts/shell/env/vars.zsh
# of NEVER eagerly populating secrets at shell init. Without this, `opencode
# attach` sends no Basic-Auth credentials and the server replies "unauthorized".
#
# Working directory: bare `opencode attach <url>` falls back to the SERVER's
# CWD (the dir `openweb` was launched from), not the terminal's CWD — so
# every attach lands in the same project regardless of where the alias was
# invoked. We forward `--dir "$PWD"` by default so the attached session
# uses the terminal's CWD instead. The path is interpreted server-side
# (sent via the `x-opencode-directory` header), which is fine on a single
# host but means cross-machine attach must use a path the server can see.
# Caller can override by passing `-- --dir /other/path`; we detect that and
# skip the default injection so the explicit value wins.
# Refs: https://github.com/anomalyco/opencode/issues/14460
#
# Companion: `openweb` (personal/opencode-web.sh) starts the server.
#
# Keychain entry consumed:
#   service: opencode-server-password
#   account: $USER
#
# Exit codes follow lib/common.sh:
#   0  success / clean exec into opencode attach
#   1  generic runtime failure (e.g. keychain entry missing)
#   2  usage error (unknown flag)
#   3  missing dependency (opencode or `security`)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/keychain.sh
source "$SCRIPT_DIR/../lib/keychain.sh"

usage() {
  cat <<'EOF'
Usage: opencode-attach.sh [URL] [-- <opencode attach args>...]

Attach a local opencode TUI to the running web backend, with credentials
loaded from macOS Keychain. Intended to be invoked via the `openattach` alias.

Arguments:
  URL    Backend URL (default: http://${OPENCODE_WEB_HOSTNAME:-127.0.0.1}:${OPENCODE_WEB_PORT:-4096})

Options:
  -h, --help    Show this help.

By default, the attached session uses the current shell's CWD (forwarded
as `--dir "$PWD"`). Override by passing `--dir <path>` after `--`; the
explicit value wins.

Any args after `--` are passed through to `opencode attach`. Example:
  openattach -- --continue
  openattach http://127.0.0.1:4096 -- --session abc123
  openattach -- --dir /other/project          # override the default CWD

Environment overrides:
  OPENCODE_WEB_PORT         Port the backend is on    (default: 4096)
  OPENCODE_WEB_HOSTNAME     Hostname the backend is on (default: 127.0.0.1)
  OPENCODE_SERVER_USERNAME  Basic Auth username        (default: opencode)

Keychain entry required (same one used by openweb):
  security add-generic-password \
    -s 'opencode-server-password' -a "$USER" -w '<password>' -U
EOF
}

# --- arg parsing ---
URL=""
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      PASSTHROUGH=("$@")
      break
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      if [[ -n "$URL" ]]; then
        die_usage "unexpected positional arg: $1"
      fi
      URL="$1"
      shift
      ;;
  esac
done

PORT="${OPENCODE_WEB_PORT:-4096}"
HOST="${OPENCODE_WEB_HOSTNAME:-127.0.0.1}"
URL="${URL:-http://${HOST}:${PORT}}"

# --- preflight ---
require_cmd opencode "Install with: brew install anomalyco/tap/opencode"
require_cmd security

# Load password from Keychain. keychain_get die()s with a clear hint on miss.
OPENCODE_SERVER_PASSWORD="$(keychain_get 'opencode-server-password')" || exit $?
export OPENCODE_SERVER_PASSWORD
export OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"

# Inject the client's CWD as the attached session's working directory unless
# the caller already supplied --dir via passthrough. The opencode server uses
# the `x-opencode-directory` header (forwarded by `--dir`) per request, so
# without this the session falls back to the SERVER's process.cwd() — which
# is whatever dir `openweb` was launched from, not the terminal's CWD.
# Refs: https://github.com/anomalyco/opencode/issues/14460
HAS_DIR=0
for arg in ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}; do
  if [[ "$arg" == "--dir" || "$arg" == --dir=* ]]; then
    HAS_DIR=1
    break
  fi
done

# bash 3.2 (macOS /bin/bash) treats "${arr[@]}" as unbound under `set -u`
# when the array is empty. Use the conditional-expansion idiom that the rest
# of the repo uses (see agent/scripts-doctor.sh) so an empty PASSTHROUGH is
# safe across bash 3.2 → 5.x.
if [[ $HAS_DIR -eq 0 ]]; then
  exec opencode attach "$URL" --dir "$PWD" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
else
  exec opencode attach "$URL" ${PASSTHROUGH[@]+"${PASSTHROUGH[@]}"}
fi
