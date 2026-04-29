#!/usr/bin/env bash
set -uo pipefail

# shellcheck source=../lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

CHROME_APP="Google Chrome"
CHROME_BIN="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PORT="9222"
USER_DATA_DIR="/tmp/chrome-devtools-mcp-auth"
MODE="detached"
VERBOSE=0
URL=""
OPEN_TARGET="default" # default | tab | window

usage() {
  cat <<'EOF'
Usage:
  chrome-mcp [options]

Options:
  -F, --foreground           Run Chrome directly in the terminal
                             (attached to the shell; useful for live output)

  -D, --detached             Launch Chrome as a normal macOS app
                             (default)

  -v, --verbose              Enable Chrome logging
                             - foreground: logs stream to the terminal
                             - detached: logs are written to the profile dir

  -U, --url URL              Open Chrome to a specific URL

  -T, --new-tab              Open URL in a new tab when practical
                             - foreground: uses Chrome's default URL behavior
                             - detached: uses AppleScript if a matching Chrome
                               instance is already running

  -W, --new-window           Open URL in a new window

  -C, --check                Check if Chrome is already running on the port
                             (exits 0 if running, 1 if not; no output on success)

  -K, --kill                 Kill any Chrome instance running on the port

  -p, --port PORT            Remote debugging port (default: 9222)

  -u, --user-data-dir PATH   Chrome profile dir
                             (default: /tmp/chrome-devtools-mcp-auth)

  -h, --help                 Show this help

Examples:
  chrome_mcp
  chrome_mcp --url "https://example.com/login"
  chrome_mcp --foreground --verbose
  chrome_mcp --foreground --url "https://example.com/login"
  chrome_mcp --new-window --url "https://example.com/login"
  chrome_mcp --new-tab --url "https://example.com/login"
  chrome_mcp -F -v -p 9333
  chrome_mcp -D -u /tmp/my-chrome-mcp-profile -U "https://example.com"
  chrome_mcp --check              # exits 0 if running, 1 if not
  chrome_mcp --kill               # kill existing instance on port

Exit codes:
  0   Success / Chrome running (--check)
  1   Chrome not running (--check)
  2   Usage error
  3   Missing dependency (Chrome binary not found)
EOF
}

escape_applescript_string() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '%s' "$s"
}

matching_instance_running() {
  local port_flag="--remote-debugging-port=${PORT}"
  local profile_flag="--user-data-dir=${USER_DATA_DIR}"

  ps ax -o command= \
    | grep -F -- "$port_flag" \
    | grep -F -- "$profile_flag" \
    >/dev/null 2>&1
}

open_url_in_new_tab_applescript() {
  local escaped_url
  escaped_url="$(escape_applescript_string "$1")"

  osascript <<EOF
tell application "$CHROME_APP"
  activate
  if (count of windows) = 0 then
    make new window
  end if
  tell front window
    set newTab to make new tab at end of tabs with properties {URL:"$escaped_url"}
    set active tab index to (count of tabs)
  end tell
end tell
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -F|--foreground)
      MODE="foreground"
      shift
      ;;
    -D|--detached)
      MODE="detached"
      shift
      ;;
    -v|--verbose)
      VERBOSE=1
      shift
      ;;
    -U|--url)
      [[ $# -ge 2 ]] || die_usage "Missing value for $1"
      URL="$2"
      shift 2
      ;;
    -C|--check)
      if matching_instance_running; then
        exit 0
      else
        exit 1
      fi
      ;;
    -K|--kill)
      pkill -f "remote-debugging-port=${PORT}" 2>/dev/null || true
      info "Killed Chrome on port ${PORT}"
      exit 0
      ;;
    -T|--new-tab)
      [[ "$OPEN_TARGET" == "window" ]] && die_usage "Cannot use --new-tab and --new-window together"
      OPEN_TARGET="tab"
      shift
      ;;
    -W|--new-window)
      [[ "$OPEN_TARGET" == "tab" ]] && die_usage "Cannot use --new-tab and --new-window together"
      OPEN_TARGET="window"
      shift
      ;;
    -p|--port)
      [[ $# -ge 2 ]] || die_usage "Missing value for $1"
      PORT="$2"
      shift 2
      ;;
    -u|--user-data-dir)
      [[ $# -ge 2 ]] || die_usage "Missing value for $1"
      USER_DATA_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -x "$CHROME_BIN" ]]; then
  die_missing_dep "Chrome binary not found or not executable: $CHROME_BIN"
fi

COMMON_ARGS=(
  "--remote-debugging-port=${PORT}"
  "--user-data-dir=${USER_DATA_DIR}"
)

if [[ "$VERBOSE" -eq 1 ]]; then
  if [[ "$MODE" == "foreground" ]]; then
    COMMON_ARGS+=(
      "--enable-logging=stderr"
      "--log-level=0"
      "--v=1"
    )
  else
    COMMON_ARGS+=(
      "--enable-logging"
      "--log-level=0"
      "--v=1"
    )
  fi
fi

if [[ "$OPEN_TARGET" == "window" ]]; then
  COMMON_ARGS+=("--new-window")
fi

if [[ "$MODE" == "foreground" ]]; then
  info "Starting Chrome in foreground mode on port ${PORT}"
  info "Profile: ${USER_DATA_DIR}"

  if [[ "$VERBOSE" -eq 1 ]]; then
    info "Verbose logging: terminal (stderr)"
  fi

  case "$OPEN_TARGET" in
    tab)
      info "Open target: new tab (Chrome default URL behavior)"
      ;;
    window)
      info "Open target: new window"
      ;;
  esac

  if [[ -n "$URL" ]]; then
    info "Opening URL: ${URL}"
    exec "$CHROME_BIN" "${COMMON_ARGS[@]}" "$URL"
  else
    exec "$CHROME_BIN" "${COMMON_ARGS[@]}"
  fi
else
  info "Starting Chrome in detached mode on port ${PORT}"
  info "Profile: ${USER_DATA_DIR}"

  if [[ "$VERBOSE" -eq 1 ]]; then
    info "Verbose logging: written under the Chrome user data directory"
  fi

  case "$OPEN_TARGET" in
    tab)
      info "Open target: new tab"
      ;;
    window)
      info "Open target: new window"
      ;;
  esac

  if [[ "$OPEN_TARGET" == "tab" && -n "$URL" ]]; then
    if matching_instance_running; then
      info "Matching Chrome instance found; opening URL in a new tab"
      open_url_in_new_tab_applescript "$URL"
      exit 0
    else
      warn "No matching Chrome instance found; falling back to launching a new window"
    fi
  fi

  if [[ -n "$URL" ]]; then
    info "Opening URL: ${URL}"
    open -na "$CHROME_APP" "$URL" --args "${COMMON_ARGS[@]}"
  else
    open -na "$CHROME_APP" --args "${COMMON_ARGS[@]}"
  fi
fi
