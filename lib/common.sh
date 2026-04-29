#!/usr/bin/env bash
# Common utilities for ~/code/scripts/
# Source this at the top of every script:
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
#
# Exit-code convention (see docs/EXIT-CODES.md):
#   0 = success
#   1 = generic runtime failure (use die)
#   2 = usage error / bad arguments (use die_usage)
#   3 = missing dependency / not on PATH (use die_missing_dep)
#   4 = upstream service not authenticated (use die_unauthed)
#   5 = upstream service failure / non-2xx response (use die_upstream)

# Re-source guard: skip body if already loaded in this process.
if [[ -n "${_LIB_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_LIB_COMMON_LOADED=1

# Colors (only if stderr is a terminal)
if [[ -t 2 ]]; then
  RED=$'\033[0;31m'
  GREEN=$'\033[0;32m'
  YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'
  NC=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  NC=''
fi

# --- logging helpers (stderr) -------------------------------------------------

die() {
  printf '%bError:%b %s\n' "$RED" "$NC" "$*" >&2
  exit 1
}

die_usage() {
  printf '%bUsage error:%b %s\n' "$RED" "$NC" "$*" >&2
  exit 2
}

die_missing_dep() {
  printf '%bMissing dependency:%b %s\n' "$RED" "$NC" "$*" >&2
  exit 3
}

die_unauthed() {
  printf '%bNot authenticated:%b %s\n' "$RED" "$NC" "$*" >&2
  exit 4
}

die_upstream() {
  printf '%bUpstream failure:%b %s\n' "$RED" "$NC" "$*" >&2
  exit 5
}

warn() {
  printf '%bWarning:%b %s\n' "$YELLOW" "$NC" "$*" >&2
}

info() {
  printf '%b✓%b %s\n' "$GREEN" "$NC" "$*" >&2
}

debug() {
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    printf '%bDebug:%b %s\n' "$BLUE" "$NC" "$*" >&2
  fi
}

# --- dependency / auth gates --------------------------------------------------

# require_cmd <cmd> [hint]
# Exits 3 if cmd is not on PATH.
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      die_missing_dep "'$cmd' is required but not found. $hint"
    else
      die_missing_dep "'$cmd' is required but not found."
    fi
  fi
}

# require_auth <cmd> <test_cmd> [fix_hint]
# Exits 3 if cmd missing, exits 4 if auth check fails.
require_auth() {
  local cmd="$1"
  local test_cmd="$2"
  local fix_hint="${3:-}"
  require_cmd "$cmd" "$fix_hint"
  if ! eval "$test_cmd" >/dev/null 2>&1; then
    if [[ -n "$fix_hint" ]]; then
      die_unauthed "'$cmd' is not authenticated. Run: $fix_hint"
    else
      die_unauthed "'$cmd' is not authenticated."
    fi
  fi
}

# --- output helpers -----------------------------------------------------------

# JSON output helper — emits a valid JSON error envelope and exits 1.
# Prefer die_* helpers for new scripts; this exists for legacy JSON-contract scripts.
json_error() {
  local msg="$1"
  # Escape backslashes and double-quotes for valid JSON.
  msg="${msg//\\/\\\\}"
  msg="${msg//\"/\\\"}"
  printf '{"error": "%s"}\n' "$msg"
  exit 1
}
