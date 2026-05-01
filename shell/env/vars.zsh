#!/usr/bin/env zsh
# env/vars.zsh — env-tier environment variables.
#
# Sourced from init_env.zsh (which is sourced from .zshenv). Runs in EVERY
# zsh invocation, including non-interactive subshells, so the contract is:
# fast, silent, and NO keychain access.
#
# For Keychain-backed secrets, callers use lib/secrets.sh::secret_load
# explicitly at the point of need. The previous _load_secret helper that
# eagerly populated env vars at shell startup has been removed (rev. 6 of
# zsh_init_plan.md §4):
#
#   - GITHUB_PAT_WPROMOTE / HOMEBREW_GITHUB_API_TOKEN: load lazily in any
#     wpromote brew helper that needs them.
#   - HF_READ_TOKEN: load lazily in the one HF script that uses it.
#   - SONARQUBE_TOKEN: was dead coupling. agent/sonar-pr-issues.sh uses
#     `require_auth "sonar"` against the SonarCloud CLI's own auth state
#     and never reads this env var. Removed entirely.
#
# For machine-specific or non-shareable variables, create env/vars.local.zsh
# in this directory. It's gitignored and sourced at the end of init_env.zsh.

# Core environment variables (kept from the original vars.sh contract).
export EDITOR=vim
export VISUAL=vim
