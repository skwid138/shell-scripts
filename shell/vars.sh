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

source "$HOME/code/scripts/lib/keychain.sh"

# Core environment variables
export EDITOR=vim
export VISUAL=vim

# PAT for skwid138 wpromote resources (homebrew, wp-sdk)
export GITHUB_PAT_WPROMOTE="$(keychain_get github-pat-wpromote)"

# Variable for https://github.com/wpromote/wp-sdk
export HOMEBREW_GITHUB_API_TOKEN="$GITHUB_PAT_WPROMOTE"

# Hugging Face token for Skwid138 resources
export HF_READ_TOKEN="$(keychain_get huggingface-read)"

# SonarQube token for Skwid138 resources (sonarqube_cli_mbp_m4_2026.04)
export SONARQUBE_TOKEN="$(keychain_get sonarqube-token)"

# Local, machine-specific overrides (gitignored). Optional.
[[ -f "$HOME/code/scripts/vars.local.sh" ]] && source "$HOME/code/scripts/vars.local.sh"
