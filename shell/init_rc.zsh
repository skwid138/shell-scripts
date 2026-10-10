#!/usr/bin/env zsh
# init_rc.zsh — interactive-shell barrel. Sourced from ~/.zshrc on every
# interactive shell (login or not).
#
# Contract (rev. 6 of zsh_init_plan.md §3):
#   - Sources rc/docker.zsh (fpath += docker completions; compinit is NOT
#     called from docker.zsh — see completion init below).
#   - Sources remaining rc-tier sub-files: zsh_config.zsh, zsh_plugins.zsh,
#     aliases.zsh, functions.zsh, cowsay_fortune_lolcat.zsh, ghostty_search.zsh.
#   - Sources lib/auto_nvm.zsh (re-registers chpwd hook for non-login
#     interactive shells; idempotent in dual-sourced login+rc case).
#   - Sources Wpromote rc layer when present.
#   - Only entry point that touches FPATH, completions (compinit), zplug,
#     prompts, ZLE.
#   - Completion init: zplug (rc/zsh_plugins.zsh) runs compinit itself and
#     owns the dump ($ZPLUG_HOME/zcompdump). The guard at the end of this
#     file only calls compinit when completion is NOT already initialized
#     (zplug absent/failed): full compinit if ${ZDOTDIR:-$HOME}/.zcompdump
#     is missing or >=24h old, else `compinit -C`. `_COMPINIT_DONE=1` =
#     completion ready (left unset on failure so a later source retries).
#
# Assumes init_env.zsh has already run.

if [[ -z "${SCRIPTS_DIR:-}" ]]; then
  SCRIPTS_DIR="${${(%):-%x}:A:h}"
  [[ -z "$SCRIPTS_DIR" || "$SCRIPTS_DIR" == "." ]] && SCRIPTS_DIR="$HOME/code/scripts/shell"
fi

# rc-tier sub-files. docker.zsh manipulates fpath but does NOT call compinit
# itself. It is sourced first so its fpath entry is in place before zplug
# (zsh_plugins.zsh) or the fallback guard below runs compinit.
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

# Completion-system guard. `_COMPINIT_DONE=1` means "completion system
# ready" — not necessarily that THIS block called compinit — and is set
# only when that is true.
#
# When zplug is present (rc/zsh_plugins.zsh), it owns completion init and
# the dump file ($ZPLUG_HOME/zcompdump, default ~/.zplug/zcompdump): its
# init runs `compinit -C`, and `zplug load` runs a full `compinit` (with the
# security audit) after plugins are on fpath. Calling compinit again here
# would redo that work and write a second, unused ~/.zcompdump. So if
# completion is already initialized (compdef defined — a function-state
# check, not "is zplug installed", so a failed/aborted zplug compinit still
# falls through), skip it.
#
# Fallback (zplug absent or its compinit failed): prezto/Powerlevel10k-style
# daily refresh on ${ZDOTDIR:-$HOME}/.zcompdump — full (audited) compinit
# when the dump is missing or >=24h old, fast `-C` (skip audit) otherwise.
# If compinit fails or leaves compdef undefined (e.g. audit aborted),
# _COMPINIT_DONE stays unset so a later source can retry.
if [[ -z "${_COMPINIT_DONE:-}" ]]; then
  if ((${+functions[compdef]})); then
    _COMPINIT_DONE=1
  else
    autoload -Uz compinit
    # Anonymous function so `emulate -L` scopes the glob options (glob
    # qualifiers need them; must not leak into the interactive shell).
    # Succeeds when a full refresh is due: dump missing, or age >=24h.
    # Minute granularity on purpose: `mm+1439` matches age >1439 whole
    # minutes, i.e. >=1440 min. (`mh+24` truncates to whole hours and would
    # only match at >=25h.)
    if () {
      emulate -L zsh -o extendedglob
      local dump="${ZDOTDIR:-$HOME}/.zcompdump"
      local -a stale
      stale=("$dump"(N.mm+1439))
      [[ ! -e "$dump" ]] || ((${#stale}))
    }; then
      compinit && ((${+functions[compdef]})) && _COMPINIT_DONE=1
    else
      compinit -C && ((${+functions[compdef]})) && _COMPINIT_DONE=1
    fi
  fi
fi

# Wpromote rc-tier (optional; private repo).
[[ -f "$HOME/code/wpromote/scripts/shell/init_rc.zsh" ]] &&
  source "$HOME/code/wpromote/scripts/shell/init_rc.zsh"

# Explicit success exit — see init_env.zsh for rationale.
return 0
