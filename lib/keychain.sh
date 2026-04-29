#!/usr/bin/env bash
# macOS Keychain helpers for secret retrieval and storage
# Source this file to use keychain_get and keychain_set functions.

# Ensure common.sh is loaded for die()
if [[ -z "${_LIB_COMMON_LOADED:-}" ]]; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
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
