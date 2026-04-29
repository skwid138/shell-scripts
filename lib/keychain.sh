#!/usr/bin/env bash
# macOS Keychain helpers for secret retrieval and storage
# Source this file to use keychain_get and keychain_set functions.

# Ensure common.sh is loaded for die().
# Resolving our own location must work under both bash (BASH_SOURCE) and zsh
# (where BASH_SOURCE is unset and we fall back to %x via eval to avoid parse
# errors in non-zsh shells).
if [[ -z "${_LIB_COMMON_LOADED:-}" ]]; then
  if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    _keychain_self="${BASH_SOURCE[0]}"
  elif [[ -n "${ZSH_VERSION:-}" ]]; then
    # In zsh, %x expands to the path of the file currently being sourced.
    # eval keeps the zsh-only syntax out of the bash parser.
    eval '_keychain_self="${(%):-%x}"'
  else
    _keychain_self="$HOME/code/scripts/lib/keychain.sh"
  fi
  _keychain_dir="$(cd "$(dirname "$_keychain_self")" && pwd)"
  # shellcheck source=common.sh
  source "$_keychain_dir/common.sh"
  unset _keychain_self _keychain_dir
fi

# Retrieve a secret from macOS Keychain
# Usage: keychain_get <service> [account]
# Account defaults to $USER
keychain_get() {
  local service="$1"
  local account="${2:-$USER}"

  if [[ -z "$service" ]]; then
    die "keychain_get requires a service name"
  fi

  local value
  value="$(security find-generic-password -s "$service" -a "$account" -w 2>/dev/null)" || {
    die "Secret not found in Keychain: service='$service' account='$account'.
  Add with: security add-generic-password -s '$service' -a '$account' -w '<value>'"
  }
  echo "$value"
}

# Store a secret in macOS Keychain (overwrites if exists)
# Usage: keychain_set <service> <account> <value>
keychain_set() {
  local service="$1"
  local account="${2:-$USER}"
  local value="$3"

  if [[ -z "$service" || -z "$value" ]]; then
    die "keychain_set requires service and value"
  fi

  # Delete existing entry (ignore errors if not found)
  security delete-generic-password -s "$service" -a "$account" 2>/dev/null || true
  # Add new entry
  security add-generic-password -s "$service" -a "$account" -w "$value"
}

# Check if a secret exists in Keychain (no output, exit code only)
# Usage: keychain_exists <service> [account]
keychain_exists() {
  local service="$1"
  local account="${2:-$USER}"
  security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1
}
