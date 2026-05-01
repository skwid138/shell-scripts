#!/usr/bin/env zsh
# init_profile.zsh — login-tier barrel. Sourced from ~/.zprofile on login
# shells only (`zsh -l`, ssh, GUI Terminal/Ghostty first tab, `su -`).
#
# Contract (rev. 6 of zsh_init_plan.md §3):
#   - Sources heavy tool inits: login/nvm.zsh (gated on $HOME/.nvm),
#     login/conda.zsh (gated on $HOME/miniconda3), login/gcloud.zsh.
#   - Sources lib/auto_nvm.zsh (chpwd hook + immediate load_nvmrc for
#     login-shell startup; also sourced by init_rc.zsh for non-login
#     interactive shells — see lib/auto_nvm.zsh idempotency notes).
#   - Tolerant of missing tools (each sub-file checks for its tool).
#   - Does NOT source rc/docker.zsh (rc-tier; completions belong in
#     interactive shells only).
#
# Assumes init_env.zsh has already run (zsh sources .zshenv before .zprofile).

# Resolve our directory. Prefer the SCRIPTS_DIR exported from init_env.zsh,
# fall back to %x resolution (defensive: covers direct sourcing of this file).
if [[ -z "${SCRIPTS_DIR:-}" ]]; then
  SCRIPTS_DIR="${${(%):-%x}:A:h}"
  [[ -z "$SCRIPTS_DIR" || "$SCRIPTS_DIR" == "." ]] && SCRIPTS_DIR="$HOME/code/scripts/shell"
fi

# Login-tier tool inits. Each is existence-gated.
[[ -d "$HOME/.nvm" && -f "$SCRIPTS_DIR/login/nvm.zsh" ]] && source "$SCRIPTS_DIR/login/nvm.zsh"
[[ -d "$HOME/miniconda3" && -f "$SCRIPTS_DIR/login/conda.zsh" ]] && source "$SCRIPTS_DIR/login/conda.zsh"
[[ -f "$SCRIPTS_DIR/login/gcloud.zsh" ]] && source "$SCRIPTS_DIR/login/gcloud.zsh"

# auto_nvm chpwd hook + immediate load_nvmrc. Sourced from BOTH login and rc
# barrels per the dual-source contract; idempotent via LAST_NVM_DIR
# short-circuit and add-zsh-hook's own dedup of identical hook+function pairs.
[[ -f "$SCRIPTS_DIR/lib/auto_nvm.zsh" ]] && source "$SCRIPTS_DIR/lib/auto_nvm.zsh"

# Wpromote login-tier (optional; private repo).
[[ -f "$HOME/code/wpromote/scripts/shell/init_profile.zsh" ]] &&
  source "$HOME/code/wpromote/scripts/shell/init_profile.zsh"

# Explicit success exit — see init_env.zsh for rationale.
return 0
