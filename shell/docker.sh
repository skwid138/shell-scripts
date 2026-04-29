#!/bin/bash
# shellcheck disable=SC2206
# This file is sourced by zsh (.zshrc), not bash. The fpath=(...) line
# uses zsh array-append syntax where unquoted $fpath expands as an
# array, not as word-splitting (which is what SC2206 flags for bash).
# Originally inserted by Docker Desktop installer; kept as-is for
# Docker CLI completions to work.

# The following lines have been added by Docker Desktop to enable Docker CLI completions.
fpath=("$HOME/.docker/completions" $fpath)
autoload -Uz compinit
compinit
# End of Docker CLI completions
