#!/bin/bash

## List all files and exclude directories in current directory (ls -p adds trailing slash to directories | ls -x displays mul$
alias lsf="ls -apx | grep -v /"

## List only directories in current path
alias lsd="ls -d -1 */ | lolcat"

# Aliases below use single quotes so $HOME expands at *use time*, not at
# alias-definition time (silences ShellCheck SC2139). Behaviorally
# identical for stable vars like $HOME, but stylistically correct.

## Git rev list gist
[[ ! -f "$HOME/code/scripts/personal/git_rev_list.sh" ]] || alias git_rev_list='"$HOME/code/scripts/personal/git_rev_list.sh"'

## Github workflow tail gist
[[ ! -f "$HOME/code/scripts/personal/github_workflow_tail.sh" ]] || alias gh_wt='"$HOME/code/scripts/personal/github_workflow_tail.sh"'

[[ ! -f "$HOME/code/scripts/personal/mov2gif.sh" ]] || alias mov2gif='"$HOME/code/scripts/personal/mov2gif.sh"'

## Start Chrome Devtools MCP
[[ ! -f "$HOME/code/scripts/agent/chrome_mcp.sh" ]] || alias chrome_mcp='"$HOME/code/scripts/agent/chrome_mcp.sh"'

## ───────────────────────────────────────────────────────────────────
## Neovim
## ───────────────────────────────────────────────────────────────────
alias v='nvim'
alias vim='nvim'

## Update nvim plugins and commit lockfile in dotfiles
## Runs :Lazy sync headless, then auto-commits lazy-lock.json if changed.
alias nvim-update='nvim --headless "+Lazy! sync" +qa && \
  cd "$HOME/code/dotfiles" && \
  { git diff --quiet nvim/.config/nvim/lazy-lock.json || \
    (git add nvim/.config/nvim/lazy-lock.json && \
     git commit -m "nvim: bump plugin lockfile"); } && \
  cd - >/dev/null'

## ───────────────────────────────────────────────────────────────────
## tmux helpers (sessionizer is bound in tmux.conf, but also from shell)
## ───────────────────────────────────────────────────────────────────
[[ ! -f "$HOME/code/scripts/personal/tmux-sessionizer.sh" ]] || alias tms='"$HOME/code/scripts/personal/tmux-sessionizer.sh"'

## ───────────────────────────────────────────────────────────────────
## BQ wrappers (bqx, not bq — bq is the actual gcloud binary; we don't shadow it)
## ───────────────────────────────────────────────────────────────────
[[ ! -f "$HOME/code/scripts/personal/bq.sh" ]] || alias bqx='"$HOME/code/scripts/personal/bq.sh"'

## ───────────────────────────────────────────────────────────────────
## GCP project map (only if wpromote/scripts is cloned)
## ───────────────────────────────────────────────────────────────────
[[ ! -f "$HOME/code/wpromote/scripts/agent/gcp-project-map.sh" ]] ||
  alias gcp-map='"$HOME/code/wpromote/scripts/agent/gcp-project-map.sh"'
