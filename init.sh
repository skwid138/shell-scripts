#!/bin/bash

## Determine script location regardless of source/execution context
if [ -n "$ZSH_VERSION" ]; then
  # For zsh
  SCRIPTS_DIR="${0:A:h}"
  if [[ "$SCRIPTS_DIR" == "." ]]; then
    # When sourced from .zshrc
    SCRIPTS_DIR="$HOME/code/scripts"
  fi
elif [ -n "$BASH_VERSION" ]; then
  # For bash
  SCRIPTS_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
else
  # Fallback to absolute path
  SCRIPTS_DIR="$HOME/code/scripts"
fi

## Core environment
[[ ! -f "$SCRIPTS_DIR/vars.sh" ]] || source "$SCRIPTS_DIR/vars.sh"
[[ ! -f "$SCRIPTS_DIR/paths.sh" ]] || source "$SCRIPTS_DIR/paths.sh"

## Tool-specific configs (only loaded if tool is installed)
[[ ! -d "$HOME/.nvm" ]] || [[ ! -f "$SCRIPTS_DIR/nvm.sh" ]] || source "$SCRIPTS_DIR/nvm.sh"
[[ ! -d "$HOME/miniconda3" ]] || [[ ! -f "$SCRIPTS_DIR/conda.sh" ]] || source "$SCRIPTS_DIR/conda.sh"
[[ ! -f "$SCRIPTS_DIR/gcloud.sh" ]] || source "$SCRIPTS_DIR/gcloud.sh"
[[ ! -f "$SCRIPTS_DIR/docker.sh" ]] || source "$SCRIPTS_DIR/docker.sh"

## Fun terminal additions
[[ ! -f "$SCRIPTS_DIR/cowsay_fortune_lolcat.sh" ]] || source "$SCRIPTS_DIR/cowsay_fortune_lolcat.sh"

## Shell customizations
[[ ! -f "$SCRIPTS_DIR/zsh_config.sh" ]] || source "$SCRIPTS_DIR/zsh_config.sh"
[[ ! -f "$SCRIPTS_DIR/zsh_plugins.sh" ]] || source "$SCRIPTS_DIR/zsh_plugins.sh"
[[ ! -f "$SCRIPTS_DIR/aliases.sh" ]] || source "$SCRIPTS_DIR/aliases.sh"
[[ ! -f "$SCRIPTS_DIR/functions.sh" ]] || source "$SCRIPTS_DIR/functions.sh"
# Ideally temporary search functionality
[[ ! -f "$SCRIPTS_DIR/ghosty_search.sh" ]] || source "$SCRIPTS_DIR/ghosty_search.sh"

# Automatically change node version 
[[ ! -f "$SCRIPTS_DIR/auto_nvm.sh" ]] || source "$SCRIPTS_DIR/auto_nvm.sh"

## Wpromote scripts, functions, and aliases
[[ ! -f "$HOME/code/wpromote/scripts/init.sh" ]] || source "$HOME/code/wpromote/scripts/init.sh"
