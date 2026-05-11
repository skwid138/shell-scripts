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
# Daemon lifecycle: the `opencode web` daemon self-daemonizes (PPID=1, owned
# by launchd) — closing the terminal that ran `openweb` does NOT kill the
# daemon. To stop it: `kill <pid>`, `openweb --restart`, or
# `opensession --restart`. The previous wrapper headers' "Ctrl+C
# kills both" claim was incorrect.
#
# Stale-daemon detection: if the daemon's start-time config snapshot (sha256
# over $OPENCODE_CONFIG_DIR; sidecar at ~/.local/share/opencode/
# daemon-config-hash-<port>-<pid>) no longer matches the current config,
# the user is prompted on /dev/tty before attaching — bypass with
# `--force`/`OPENCODE_ATTACH_FORCE=1`. See the opencode-daemon helper for
# the staleness contract and ~/.config/opencode/README.md for the model.
#
# Companion: `openweb` (personal/opencode-web.sh) starts the server.
#
# Keychain entry consumed:
#   service: opencode-server-password
#   account: $USER
#
# Exit codes follow lib/common.sh:
#   0  success / clean exec into opencode attach (or deliberate-N abort)
#   1  generic runtime failure (e.g. keychain entry missing)
#   2  usage error (unknown flag)
#   3  missing dependency (opencode, security, or a tool the daemon
#      helper requires — pgrep/lsof/stat/ps/date/shasum)
#   5  upstream failure: no daemon at the requested port, OR stale daemon
#      with no usable TTY for the prompt

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
Usage: opencode-attach.sh [URL] [--force] [-- <opencode attach args>...]

Attach a local opencode TUI to the running web backend, with credentials
loaded from macOS Keychain. Intended to be invoked via the `openattach` alias.

Arguments:
  URL    Backend URL (default: http://${OPENCODE_WEB_HOSTNAME:-127.0.0.1}:${OPENCODE_WEB_PORT:-4096})

Options:
  -f, --force   Skip the stale-daemon prompt; attach unconditionally.
  -h, --help    Show this help.

Stale-daemon detection:
  When openweb starts a daemon, it records a sha256 of the current opencode
  config dir to ~/.local/share/opencode/daemon-config-hash-<port>-<pid>.
  On attach we recompute the hash and compare. On mismatch you'll be
  prompted on /dev/tty whether to attach to the (now config-stale) daemon
  anyway. To refresh the daemon: `openweb --restart`.

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
  OPENCODE_ATTACH_FORCE=1   Equivalent to --force (env-driven bypass).

Keychain entry required (same one used by openweb):
  security add-generic-password \
    -s 'opencode-server-password' -a "$USER" -w '<password>' -U
EOF
}

# --- arg parsing ---
URL=""
FORCE=0
PASSTHROUGH=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -f | --force)
      FORCE=1
      shift
      ;;
    --)
      shift
      # PASSTHROUGH is expanded later via the unquoted ${PASSTHROUGH[@]+...}
      # idiom — see the rationale at the exec site near the bottom of this
      # file (search for "bash 3.2"). Don't "fix" the unquoted form.
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

# Env-driven equivalent for the bypass (opensession can set this without
# adding the flag to its own arg surface).
if [[ "${OPENCODE_ATTACH_FORCE:-0}" == "1" ]]; then
  FORCE=1
fi

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

# --- daemon presence + staleness check --------------------------------------
#
# Skip entirely under --force / OPENCODE_ATTACH_FORCE=1: the user has already
# decided they want to attach regardless of state.
#
# Otherwise:
#   - No daemon → die_upstream with actionable message (run openweb).
#   - Daemon exists, sidecar fresh → silent attach (existing behavior).
#   - Daemon exists, sidecar missing/stale → prompt on /dev/tty (if usable)
#     or die with bypass instructions (no TTY).
if [[ "$FORCE" != "1" ]]; then
  DAEMON_PID="$(opencode_daemon_pid_for_port "$PORT" 2>/dev/null || true)"
  if [[ -z "$DAEMON_PID" ]]; then
    die_upstream "no opencode daemon at :$PORT — run \`openweb\` to start one."
  fi

  if opencode_daemon_is_stale "$PORT" "$DAEMON_PID"; then
    # TTY-detect: writability of /dev/tty is the right gate, NOT [[ -t 0 ]].
    # The latter is false in exactly the redirected-stdin case the prompt
    # path is designed to handle (`echo y | openattach`, pipes, opensession's
    # background-spawn handoff). See plan §"Implementation gotchas".
    if { : >/dev/tty; } 2>/dev/null; then
      START_EPOCH="$(opencode_daemon_start_epoch "$DAEMON_PID" 2>/dev/null || printf '0')"
      # Wire fd 3 ← /dev/tty (read), fd 4 → /dev/tty (write). The helper
      # itself has no /dev/tty knowledge — keeps it bats-testable.
      if ! prompt_continue_on_stale "$DAEMON_PID" "$START_EPOCH" "$PORT" 3</dev/tty 4>/dev/tty; then
        # Deliberate user abort. Exit 0: this is not an error, the user
        # made an informed decision. They can run `openweb --restart` and
        # re-invoke openattach.
        exit 0
      fi
    else
      die_upstream "stale daemon on :$PORT (pid $DAEMON_PID) and no /dev/tty for the prompt — run \`openweb --restart\` to refresh, or set OPENCODE_ATTACH_FORCE=1 to attach anyway."
    fi
  fi
fi

# Inject the client's CWD as the attached session's working directory unless
# the caller already supplied --dir via passthrough. The opencode server uses
# the `x-opencode-directory` header (forwarded by `--dir`) per request, so
# without this the session falls back to the SERVER's process.cwd() — which
# is whatever dir `openweb` was launched from, not the terminal's CWD.
# Refs: https://github.com/anomalyco/opencode/issues/14460
HAS_DIR=0
# Unquoted ${PASSTHROUGH[@]+...} is intentional — see the bash-3.2 rationale
# in the conditional-expansion comment below (lines re: empty-array safety).
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
