#!/bin/bash

## List all files and exclude directories in current directory (ls -p adds trailing slash to directories | ls -x displays mul$
alias lsf="ls -apx | grep -v /"

## List only directories in current path
alias lsd="ls -d -1 */ | lolcat"

# Aliases below use double quotes so $HOME expands at *alias-definition
# time*, producing a literal absolute path as the alias value.
#
# Why definition-time and not use-time:
#   zsh-syntax-highlighting's `main` highlighter resolves an alias and then
#   stats the resulting string to decide if it's a real command. If the
#   alias value is the literal `$HOME/foo.sh`, the highlighter never
#   expands $HOME — stat() fails, and the alias is painted red as
#   `unknown-token`. The shell itself still executes the alias correctly
#   (the variable expands at use time during command execution), but the
#   prompt looks broken in fresh shells.
#
#   Using "$HOME/foo.sh" expands at definition time, so the alias value
#   is a real absolute path the highlighter can stat → green.
#
# This triggers ShellCheck SC2139 ("This expands when defined, not when
# used"), but that's exactly the behavior we want here. The disable
# comments below document the intent.

## Git rev list gist
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/git_rev_list.sh" ]] || alias git_rev_list="$HOME/code/scripts/personal/git_rev_list.sh"

## Watch the latest GitHub Actions run via `gh run watch` and `say` when done.
## Replaces the old github_workflow_tail.sh (deleted; gh covers it natively).
## Usage:
##   gh-watch-say                          # watches latest run, says "workflow completed"
##   gh-watch-say "deploy is green"        # custom message
##   gh-watch-say "all good" Samantha      # custom message + voice
gh-watch-say() {
  local message="${1:-workflow completed}"
  local voice="${2:-}"
  command -v gh >/dev/null 2>&1 || {
    echo "gh-watch-say: gh CLI not on PATH" >&2
    return 127
  }
  gh run watch --exit-status
  local rc=$?
  if [[ -n "$voice" ]]; then
    say -v "$voice" "$message"
  else
    say "$message"
  fi
  return "$rc"
}

# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/mov2gif.sh" ]] || alias mov2gif="$HOME/code/scripts/personal/mov2gif.sh"

## Budget-aware GIF wrapper around mov2gif (see personal/gif_jif.sh --help).
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/gif_jif.sh" ]] || alias gif_jif="$HOME/code/scripts/personal/gif_jif.sh"

## Start Chrome Devtools MCP
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/agent/chrome_mcp.sh" ]] || alias chrome_mcp="$HOME/code/scripts/agent/chrome_mcp.sh"

## OpenCode token totals
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/agent/opencode-token-totals.sh" ]] || alias opentokens="$HOME/code/scripts/agent/opencode-token-totals.sh"

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
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/tmux-sessionizer.sh" ]] || alias tms="$HOME/code/scripts/personal/tmux-sessionizer.sh"

## ───────────────────────────────────────────────────────────────────
## BQ wrappers (bqx, not bq — bq is the actual gcloud binary; we don't shadow it)
## ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/bq.sh" ]] || alias bqx="$HOME/code/scripts/personal/bq.sh"

## ───────────────────────────────────────────────────────────────────
## GCP project map (only if wpromote/scripts is cloned)
## ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/wpromote/scripts/agent/gcp-project-map.sh" ]] ||
  alias gcp-map="$HOME/code/wpromote/scripts/agent/gcp-project-map.sh"

## ───────────────────────────────────────────────────────────────────
## opencode remote access (Tailscale-fronted web UI)
## opensession — daily driver. Ensures a daemon is running, then attaches.
##               Starts one via openweb if needed; otherwise just openattach.
##               --restart for a clean refresh; --force to bypass staleness;
##               --local to prepare LM Studio before attaching.
## local-models — start/verify/load/unload LM Studio local OpenCode models.
## openweb     — start `opencode web` wrapped in caffeinate, password from Keychain.
## openattach  — attach a local TUI to the running web backend so all clients
##               (web + terminal) share one session pool. Requires `openweb` running.
## See: ~/.config/opencode/README.md → "OpenCode daemon and the wrapper quartet"
## ───────────────────────────────────────────────────────────────────
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/opensession.sh" ]] ||
  alias opensession="$HOME/code/scripts/personal/opensession.sh"
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/local-models.sh" ]] ||
  alias local-models="$HOME/code/scripts/personal/local-models.sh"
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/opencode-web.sh" ]] ||
  alias openweb="$HOME/code/scripts/personal/opencode-web.sh"
# shellcheck disable=SC2139
[[ ! -f "$HOME/code/scripts/personal/opencode-attach.sh" ]] ||
  alias openattach="$HOME/code/scripts/personal/opencode-attach.sh"
