#!/bin/bash
# Environment variables and secrets for ~/code/scripts/
#
# Secrets are loaded from the macOS Keychain via keychain_get. See the
# secrets-bootstrap doc in the dotfiles repo for how to populate Keychain
# entries on a new machine.
#
# For machine-specific or non-shareable variables that you don't want
# committed, create vars.local.sh in this directory. It's gitignored and
# sourced at the end of this file if present.

# shellcheck source=../lib/keychain.sh
source "$HOME/code/scripts/lib/keychain.sh"

# Core environment variables
export EDITOR=vim
export VISUAL=vim

# Helper: load a Keychain secret into a named env var.
# - Splits declare-and-assign so keychain_get's exit code isn't masked (SC2155).
# - On failure: emits a one-line warning to stderr and exports an empty value
#   so downstream code can detect the missing secret without aborting startup.
_load_secret() {
  local var="$1"
  local entry="$2"
  local value
  if value="$(keychain_get "$entry" 2>/dev/null)" && [[ -n "$value" ]]; then
    export "$var=$value"
  else
    export "$var="
    printf 'Warning: keychain entry %q not found; %s is empty\n' "$entry" "$var" >&2
  fi
}

# PAT for skwid138 wpromote resources (homebrew, wp-sdk)
_load_secret GITHUB_PAT_WPROMOTE github-pat-wpromote

# Variable for https://github.com/wpromote/wp-sdk
export HOMEBREW_GITHUB_API_TOKEN="$GITHUB_PAT_WPROMOTE"

# Hugging Face token for Skwid138 resources
_load_secret HF_READ_TOKEN huggingface-read

# SonarQube token for Skwid138 resources (sonarqube_cli_mbp_m4_2026.04)
_load_secret SONARQUBE_TOKEN sonarqube-token

unset -f _load_secret

# Local, machine-specific overrides (gitignored). Optional.
# shellcheck source=/dev/null
[[ -f "$HOME/code/scripts/shell/vars.local.sh" ]] && source "$HOME/code/scripts/shell/vars.local.sh"
