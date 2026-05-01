#!/bin/bash

# Terminal search functionality (Ctrl+F)
# fzf_terminal_search() {
#   # Check if fzf is installed
#   if ! command -v fzf &>/dev/null; then
#     echo "fzf not found. Please install with: brew install fzf"
#     return
#   }

#   # Clear current input
#   BUFFER=""
#   zle redisplay

#   # Create search command using history
#   BUFFER="fc -ln -1000 | fzf --reverse --height 50% --border"
#   zle accept-line
# }

# # Register the widget
# zle -N fzf_terminal_search

# # Bind Ctrl+F to terminal search
# bindkey '^F' fzf_terminal_search
