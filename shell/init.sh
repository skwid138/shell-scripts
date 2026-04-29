#!/bin/bash

## Determine script location regardless of source/execution context.
## After the shell-scripts repo restructure (2026-04), this file lives at
## ~/code/scripts/shell/init.sh. SCRIPTS_DIR is the directory containing this
## file (i.e. shell/), and REPO_ROOT is one level up.
if [ -n "$ZSH_VERSION" ]; then
  # zsh: %x expands to the path of the file currently being sourced.
  # eval keeps zsh-only syntax out of the bash parser (and out of shellcheck).
  eval 'SCRIPTS_DIR="${${(%):-%x}:A:h}"'
  if [[ -z "$SCRIPTS_DIR" || "$SCRIPTS_DIR" == "." ]]; then
    eval 'SCRIPTS_DIR="${0:A:h}"'
  fi
  if [[ -z "$SCRIPTS_DIR" || "$SCRIPTS_DIR" == "." ]]; then
    SCRIPTS_DIR="$HOME/code/scripts/shell"
  fi
elif [ -n "$BASH_VERSION" ]; then
  SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPTS_DIR="$HOME/code/scripts/shell"
fi

REPO_ROOT="$(dirname "$SCRIPTS_DIR")"
# REPO_ROOT is exported so child scripts (e.g. agent/, lib/) can locate the repo
# root without re-deriving it. Currently unused by shell/* but stable contract.
export REPO_ROOT

## Shared logging helpers (warn / info / debug) for shell/*.sh files.
##
## Sourced ONCE here at startup so every subsequent shell/*.sh has access
## with zero per-file overhead (lib/common.sh has a re-source guard).
##
## CAUTION: lib/common.sh also defines die / die_usage / die_missing_dep /
## die_unauthed / die_upstream — DO NOT call those from shell/*.sh. They
## call `exit`, which would kill the user's interactive shell. Use `warn`
## (yellow stderr message) for non-fatal conditions in this layer.
[[ ! -f "$REPO_ROOT/lib/common.sh" ]] || source "$REPO_ROOT/lib/common.sh"

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

## Wpromote scripts, functions, and aliases (private repo, optional)
[[ ! -f "$HOME/code/wpromote/scripts/shell/init.sh" ]] || source "$HOME/code/wpromote/scripts/shell/init.sh"
