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

# Force the emacs keymap. zsh auto-selects vi mode when $EDITOR/$VISUAL
# contains "vi" (we export EDITOR=vim), which makes Ctrl+A/Ctrl+E insert
# literal ^A/^E. Must run BEFORE the bindkey calls below so they land in emacs.
bindkey -e

# Remind myself to use the native shortcuts
#
# The tip is cleared from a line-pre-redraw hook on the next keypress of any
# kind (typed char, backspace, arrows, ...). We deliberately never redefine
# self-insert: zsh-autosuggestions / zsh-syntax-highlighting (loaded later by
# zsh_plugins.zsh) wrap it, and swapping it out would bypass their wrappers.
beginning_of_line_with_reminder() {
  zle beginning-of-line
  zle -M "▶ TIP: You can also use Ctrl+A to move to beginning of line"
  typeset -g _zsh_reminder_pending=1
}
zle -N beginning_of_line_with_reminder

end_of_line_with_reminder() {
  zle end-of-line
  zle -M "▶ TIP: You can also use Ctrl+E to move to end of line"
  typeset -g _zsh_reminder_pending=1
}
zle -N end_of_line_with_reminder

# Runs before every redraw. $LASTWIDGET is the reminder widget on its own
# redraw and the next widget on the following one, so clear only then.
# Must return 0 on every path: add-zle-hook-widget's dispatcher stops at the
# first failing hook, which would skip hooks registered after this one.
_zsh_reminder_clear() {
  if [[ -n ${_zsh_reminder_pending-} ]] &&
    [[ $LASTWIDGET != beginning_of_line_with_reminder ]] &&
    [[ $LASTWIDGET != end_of_line_with_reminder ]]; then
    zle -M ""
    unset _zsh_reminder_pending
  fi
  return 0
}
autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-pre-redraw _zsh_reminder_clear

# Add fn+left/right shortcuts with reminder to use native shortcuts
bindkey '^[[H' beginning_of_line_with_reminder # fn+left arrow
bindkey '^[[F' end_of_line_with_reminder       # fn+right arrow

# Word navigation with Ctrl+Shift+F and Ctrl+Shift+B (Native equivilant (option + b or option + f))
bindkey '^[[102;6u' forward-word # Ctrl+Shift+F (forward one word)
bindkey '^[[98;6u' backward-word # Ctrl+Shift+B (backward one word)
