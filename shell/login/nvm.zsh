#!/bin/bash

# NVM Configuration
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"                   # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion" # This loads nvm bash_completion

# Ensure a Node version is always available (uses nvm's default alias).
# Gated on nvm actually being defined: ~/.nvm can exist without nvm.sh
# (partial/broken install), and an ungated call would print
# "command not found: nvm" and leave this file's last status non-zero.
if typeset -f nvm >/dev/null 2>&1; then
  nvm use default --silent
fi
