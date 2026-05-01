#!/usr/bin/env zsh
# init_rc.zsh — interactive-shell barrel. Sourced from ~/.zshrc on every
# interactive shell (login or not).
#
# Contract (rev. 6 of zsh_init_plan.md §3):
#   - Sources rc/docker.zsh (fpath += docker completions; the central
#     compinit lives in this barrel, not in docker.zsh).
#   - Sources remaining rc-tier sub-files: zsh_config.zsh, zsh_plugins.zsh,
#     aliases.zsh, functions.zsh, cowsay_fortune_lolcat.zsh, ghostty_search.zsh.
#   - Sources lib/auto_nvm.zsh (re-registers chpwd hook for non-login
#     interactive shells; idempotent in dual-sourced login+rc case).
#   - Sources Wpromote rc layer when present.
#   - Only entry point that touches FPATH, completions (compinit), zplug,
#     prompts, ZLE.
#   - Applies `compinit -C` daily-cache pattern (prezto/Powerlevel10k
#     convention): full compinit at most once per 24h via .zcompdump mtime
#     check; `-C` (skip security audit) on subsequent shells. Saves
#     15–50ms per shell on warm cache.
#
# Assumes init_env.zsh has already run.

if [[ -z "${SCRIPTS_DIR:-}" ]]; then
  SCRIPTS_DIR="${${(%):-%x}:A:h}"
  [[ -z "$SCRIPTS_DIR" || "$SCRIPTS_DIR" == "." ]] && SCRIPTS_DIR="$HOME/code/scripts/shell"
fi

# rc-tier sub-files. docker.zsh manipulates fpath but does NOT call compinit
# itself anymore (that moved here, post-fpath, so all completion sources are
# registered before the audit runs).
[[ -f "$SCRIPTS_DIR/rc/docker.zsh" ]] && source "$SCRIPTS_DIR/rc/docker.zsh"
[[ -f "$SCRIPTS_DIR/rc/zsh_config.zsh" ]] && source "$SCRIPTS_DIR/rc/zsh_config.zsh"
[[ -f "$SCRIPTS_DIR/rc/zsh_plugins.zsh" ]] && source "$SCRIPTS_DIR/rc/zsh_plugins.zsh"
[[ -f "$SCRIPTS_DIR/rc/aliases.zsh" ]] && source "$SCRIPTS_DIR/rc/aliases.zsh"
[[ -f "$SCRIPTS_DIR/rc/functions.zsh" ]] && source "$SCRIPTS_DIR/rc/functions.zsh"
[[ -f "$SCRIPTS_DIR/rc/cowsay_fortune_lolcat.zsh" ]] && source "$SCRIPTS_DIR/rc/cowsay_fortune_lolcat.zsh"
[[ -f "$SCRIPTS_DIR/rc/ghostty_search.zsh" ]] && source "$SCRIPTS_DIR/rc/ghostty_search.zsh"

# auto_nvm — re-source for non-login interactive shells. Idempotent via
# LAST_NVM_DIR + add-zsh-hook dedup. See auto_nvm_dual_source.bats.
[[ -f "$SCRIPTS_DIR/lib/auto_nvm.zsh" ]] && source "$SCRIPTS_DIR/lib/auto_nvm.zsh"

# Single-invocation compinit guard with daily security-audit refresh.
# Pattern from prezto/Powerlevel10k: full compinit once per 24h, fast `-C`
# (skip audit) on subsequent shells using cached .zcompdump.
if [[ -z "${_COMPINIT_DONE:-}" ]]; then
  autoload -Uz compinit
  local _zcompdump="${ZDOTDIR:-$HOME}/.zcompdump"
  # qN.mh+24 = file exists AND mtime > 24 hours old. If true, full refresh.
  if [[ -n "${_zcompdump}"(#qN.mh+24) ]]; then
    compinit
  else
    compinit -C
  fi
  _COMPINIT_DONE=1
  unset _zcompdump
fi

# Wpromote rc-tier (optional; private repo).
[[ -f "$HOME/code/wpromote/scripts/shell/init_rc.zsh" ]] &&
  source "$HOME/code/wpromote/scripts/shell/init_rc.zsh"
