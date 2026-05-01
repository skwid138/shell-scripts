#!/bin/bash

# Homebrew zsh completions (Apple Silicon path)
if [[ -d "/opt/homebrew/share/zsh/site-functions" ]] && [[ ":$FPATH:" != *":/opt/homebrew/share/zsh/site-functions:"* ]]; then
  FPATH="/opt/homebrew/share/zsh/site-functions:${FPATH}"
fi

# Case-insensitive completion
# m:{a-z}={A-Z} - Match lowercase to uppercase
# m:{A-Z}={a-z} - Match uppercase to lowercase
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'

# Advanced configuration with partial-word completion
# 'r:|=*' - Right side can match anything
# 'l:|=*' - Left side can match anything
# zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}' 'r:|=*' 'l:|=*'

# Remind myself to use the native shortcuts
beginning_of_line_with_reminder() {
  zle beginning-of-line
  zle -M "▶ TIP: You can also use Ctrl+A to move to beginning of line"
  # Set up a one-time hook to clear the message on next keypress
  zle -N self-insert clear_message_and_self_insert
}
zle -N beginning_of_line_with_reminder

end_of_line_with_reminder() {
  zle end-of-line
  zle -M "▶ TIP: You can also use Ctrl+E to move to end of line"
  # Set up a one-time hook to clear the message on next keypress
  zle -N self-insert clear_message_and_self_insert
}
zle -N end_of_line_with_reminder

# Clear the message on next keypress
clear_message_and_self_insert() {
  # Clear the message
  zle -M ""
  # Restore the original self-insert widget
  zle -A .self-insert self-insert
  # Process the current key press
  zle .self-insert
}
zle -N clear_message_and_self_insert

# Add fn+left/right shortcuts with reminder to use native shortcuts
bindkey '^[[H' beginning_of_line_with_reminder # fn+left arrow
bindkey '^[[F' end_of_line_with_reminder       # fn+right arrow

# Word navigation with Ctrl+Shift+F and Ctrl+Shift+B (Native equivilant (option + b or option + f))
bindkey '^[[102;6u' forward-word # Ctrl+Shift+F (forward one word)
bindkey '^[[98;6u' backward-word # Ctrl+Shift+B (backward one word)
