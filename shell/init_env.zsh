#!/usr/bin/env zsh
# init_env.zsh — env-tier barrel. Sourced from ~/.zshenv on EVERY zsh
# invocation (interactive, login, non-interactive, subshells, opencode
# tool calls, cron, LaunchAgents).
#
# Contract (rev. 6 of zsh_init_plan.md §3):
#   - Fast: target p50 < 10ms, p95 < 20ms, hard fail at 50ms.
#   - Silent: no stdout. Stderr only on actual error or 14-day staleness nag.
#   - No side effects beyond exporting env vars and the freshness probe.
#   - Never calls `keychain_get` directly. Use lib/secrets.sh::secret_load
#     from a consumer when needed; secrets are NOT auto-loaded into env.
#   - Sources env/vars.zsh and env/paths.zsh.
#   - Exports REPO_ROOT, EDITOR, VISUAL.
#   - Sources optional env/vars.local.zsh at end (gitignored override).

# Locate ourselves. ${(%):-%x} expands to the path of the file currently
# being sourced under zsh; :A:h resolves symlinks and returns the parent dir.
SCRIPTS_DIR="${${(%):-%x}:A:h}"
if [[ -z "$SCRIPTS_DIR" || "$SCRIPTS_DIR" == "." ]]; then
  SCRIPTS_DIR="$HOME/code/scripts/shell"
fi
REPO_ROOT="$(dirname "$SCRIPTS_DIR")"
# REPO_ROOT is exported as a stable contract (existing convention; consumers
# in agent/ and lib/ rely on it).
export REPO_ROOT

# Shared logging helpers (warn / info / debug). Sourced ONCE here so every
# downstream file gets them with zero per-file overhead (re-source guard
# in lib/common.sh). Note: do NOT call die / die_unauthed / die_missing_dep /
# die_upstream / die_usage from shell/* — they call `exit`, killing the
# user's shell. Use `warn` for non-fatal conditions.
[[ -f "$REPO_ROOT/lib/common.sh" ]] && source "$REPO_ROOT/lib/common.sh"

# Env-tier sub-files.
[[ -f "$SCRIPTS_DIR/env/vars.zsh" ]] && source "$SCRIPTS_DIR/env/vars.zsh"
[[ -f "$SCRIPTS_DIR/env/paths.zsh" ]] && source "$SCRIPTS_DIR/env/paths.zsh"

# Wpromote env-tier (optional; private repo).
[[ -f "$HOME/code/wpromote/scripts/shell/init_env.zsh" ]] &&
  source "$HOME/code/wpromote/scripts/shell/init_env.zsh"

# Local, machine-specific overrides (gitignored). Optional.
[[ -f "$SCRIPTS_DIR/env/vars.local.zsh" ]] && source "$SCRIPTS_DIR/env/vars.local.zsh"

# Explicit success exit. Without this, the final `[[ -f ... ]]` test above
# leaks its exit status (1 when the optional file doesn't exist) as the
# source command's status — breaking `source init_env.zsh && do-thing`
# chains and causing bats `assert_success` to fail spuriously.
return 0
