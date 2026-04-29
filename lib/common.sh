#!/usr/bin/env bash
# Common utilities for ~/code/scripts/
# Source this at the top of every script: source "$(dirname "$0")/lib/common.sh"

# Guard: only set options if this is being sourced into a script (not interactive shell)
if [[ "${BASH_SOURCE[0]}" != "${0}" ]] && [[ -z "${_LIB_COMMON_LOADED:-}" ]]; then
  _LIB_COMMON_LOADED=1
fi

# Colors (only if terminal)
if [[ -t 2 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

die() {
  echo -e "${RED}Error:${NC} $*" >&2
  exit 1
}

warn() {
  echo -e "${YELLOW}Warning:${NC} $*" >&2
}

info() {
  echo -e "${GREEN}✓${NC} $*" >&2
}

debug() {
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    echo -e "${BLUE}Debug:${NC} $*" >&2
  fi
}

# Check that a command exists
# Usage: require_cmd "gh" "Install with: brew install gh"
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      die "'$cmd' is required but not found. $hint"
    else
      die "'$cmd' is required but not found."
    fi
  fi
}

# Check that a command is authenticated
# Usage: require_auth "gh" "gh auth status" "gh auth login"
require_auth() {
  local cmd="$1"
  local test_cmd="$2"
  local fix_hint="${3:-}"
  require_cmd "$cmd" "$fix_hint"
  if ! eval "$test_cmd" >/dev/null 2>&1; then
    die "'$cmd' is not authenticated. Run: $fix_hint"
  fi
}

# JSON output helper — ensures valid JSON even on error
json_error() {
  local msg="$1"
  printf '{"error": "%s"}\n' "$msg"
  exit 1
}
