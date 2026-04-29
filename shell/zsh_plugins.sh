#!/bin/bash

# Source Zplug
if [ -f "/opt/homebrew/opt/zplug/init.zsh" ]; then
  source "/opt/homebrew/opt/zplug/init.zsh"

  # Define plugins
  zplug "spaceship-prompt/spaceship-prompt", use:spaceship.zsh, from:github, as:theme
  zplug "zsh-users/zsh-syntax-highlighting", defer:2
  zplug "zsh-users/zsh-autosuggestions"

  # Install plugins if there are plugins that have not been installed
  if ! zplug check; then
    printf "Install missing Zplug plugins? [y/N]: "
    if read -q; then
      echo
      zplug install
    fi
  fi

  # Load plugins
  zplug load

  # Spaceship prompt configuration
  SPACESHIP_PROMPT_ORDER=(
    user      # Username section
    dir       # Current directory section
    host      # Hostname section
    git       # Git section (git_branch + git_status)
    exec_time # Execution time
    line_sep  # Line break
    jobs      # Background jobs indicator
    exit_code # Exit code section
    char      # Prompt character
  )
  SPACESHIP_PROMPT_ADD_NEWLINE=false
  SPACESHIP_CHAR_SYMBOL="❯ "
  SPACESHIP_CHAR_SUFFIX=" "
fi
