#!/usr/bin/env bash
# ~/code/scripts/shell/lib/secrets.sh
#
# Memoized, idempotent secret loader. Designed to be sourced from anywhere
# (env-tier, profile-tier, rc-tier, agent scripts, MCP launch shims) without
# re-querying Keychain on every call.
#
# Bash 3.2-compatible AND zsh-friendly: uses associative arrays under zsh,
# sentinel-prefixed env vars under bash. Single source of truth for the API
# contract; one bats fixture exercises both shell paths.
#
# Public API:
#   secret_get   <keychain_entry>           -> echoes value, returns 0/1
#   secret_load  <env_var> <keychain_entry> -> exports env_var, returns 0/1
#   secret_clear [keychain_entry]           -> drop one or all cached secrets
#
# Replaces the inline _load_secret helper currently in shell/vars.sh. The
# old helper warned-and-exported-empty on miss; secret_load returns non-zero
# on miss (callers decide how to handle it) but still emits a stderr warning
# for visibility.
#
# The file is .sh (not .zsh) deliberately so future MCP wrappers can:
#   bash -c '. "$HOME/code/scripts/shell/lib/secrets.sh"; secret_load …; exec …'
# without a zsh dependency.
#
# ----------------------------------------------------------------------------
# Usage guidance — prefer secret_load over secret_get for repeated access
# ----------------------------------------------------------------------------
#
# secret_load is the recommended entry point for almost every consumer. It
# exports the secret as a named env var, then short-circuits on subsequent
# calls by checking that env var directly — meaning the second-and-later
# call costs ~zero (no cache lookup, no subshell, no Keychain shellout).
#
#   # Recommended pattern:
#   secret_load WPRO_OPEN_AI_API_SECRET wpro-openai \
#     || die_unauthed "wpro-openai not in keychain"
#   curl -H "Authorization: Bearer $WPRO_OPEN_AI_API_SECRET" …
#
# secret_get is for callers that DON'T want the secret in the environment
# (e.g. piping into a tool that reads stdin). The in-process cache makes
# repeated calls cheap *within the same shell process*, but watch out:
#
#   # SUBTLE: each $(...) is a subshell. The cache write happens inside
#   # the subshell and dies with it, so the second call re-queries Keychain.
#   token1="$(secret_get wpro-openai)"   # Keychain hit
#   token2="$(secret_get wpro-openai)"   # Keychain hit AGAIN (subshell quirk)
#
#   # Fix: hoist out of the subshell — direct invocation reuses the cache.
#   secret_get wpro-openai >/tmp/token   # Keychain hit
#   secret_get wpro-openai >/tmp/token2  # cached (no Keychain hit)
#
# If you find yourself calling $(secret_get …) more than once in the same
# shell, reach for secret_load instead.
#
# ----------------------------------------------------------------------------
# Two-layer memoization in secret_load — env var (fast path) + cache (fallback)
# ----------------------------------------------------------------------------
#
# secret_load short-circuits in two stages:
#
#   1. Fast path: ${!var}/${(P)var} indirect read on the named env var.
#      If the var is already set non-empty, return immediately. This is the
#      hot path for repeated calls in the same shell.
#
#   2. Fallback: call secret_get, which checks the in-process cache before
#      hitting Keychain. Relevant if the caller manually `unset`s the var
#      (e.g. for re-load semantics) — the cache still holds the value, so
#      the re-load is fast.
#
# These layers are NOT redundant. An `unset MY_TOKEN` will fall through to
# the cache, and `secret_clear MY_TOKEN_ENTRY` will fall through to Keychain.
# Both unset operations together force a fresh Keychain query — useful after
# a rotation.

# Re-source guard (matches the _LIB_COMMON_LOADED pattern from lib/common.sh).
if [[ -n "${_LIB_SECRETS_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
_LIB_SECRETS_LOADED=1

# Resolve our own location under both bash (BASH_SOURCE) and zsh (%x via
# eval to keep the zsh-only syntax out of the bash parser).
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _secrets_self="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  eval '_secrets_self="${(%):-%x}"'
else
  _secrets_self="$HOME/code/scripts/shell/lib/secrets.sh"
fi
_secrets_dir="$(cd "$(dirname "$_secrets_self")" && pwd)"
# shellcheck source=../../lib/keychain.sh
source "$_secrets_dir/../../lib/keychain.sh"
unset _secrets_self _secrets_dir

# Initialize per-shell cache. zsh uses a typed associative array; bash 3.2
# has no associative arrays, so we fall back to sentinel-prefixed env vars
# (one var per cached entry, suffix sanitized to [A-Za-z0-9_]).
if [[ -n "${ZSH_VERSION:-}" ]]; then
  # Zsh-only: declared via eval to keep typeset flags out of the bash parser.
  # `-g` makes the array global; `-A` declares it associative.
  eval 'typeset -gA __SECRET_CACHE'
fi

# secret_get <keychain_entry>
#   Echo the secret to stdout; cache after first read. Returns 0 on success,
#   1 if the entry is missing from Keychain.
secret_get() {
  if [[ $# -lt 1 || -z "$1" ]]; then
    printf 'usage: secret_get <keychain_entry>\n' >&2
    return 2
  fi
  local entry="$1"
  local cached_var="__SECRET_CACHE_${entry//[^A-Za-z0-9_]/_}"
  local cached=""

  # Cache lookup. The zsh branch is hidden from the bash parser by `eval`
  # because `${__SECRET_CACHE[$entry]}` is parsed differently across shells.
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    eval 'cached="${__SECRET_CACHE[$entry]:-}"'
  else
    # bash 3.2 indirect read: ${!varname}
    cached="${!cached_var:-}"
  fi
  if [[ -n "$cached" ]]; then
    printf '%s\n' "$cached"
    return 0
  fi

  # Miss: query Keychain. keychain_get exits the subshell with die() on miss,
  # so we wrap it in $() and check both exit code and emptiness.
  local value
  if value="$(keychain_get "$entry" 2>/dev/null)" && [[ -n "$value" ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      eval '__SECRET_CACHE[$entry]="$value"'
    else
      # Plain assignment to a dynamically-named global. No `local` here so
      # the value survives function return.
      eval "$cached_var=\"\$value\""
    fi
    printf '%s\n' "$value"
    return 0
  fi
  return 1
}

# secret_load <env_var_name> <keychain_entry>
#   Export the secret as the named env var. Memoizes; safe to re-call.
#   Returns 0 on success, 1 if the entry is missing (and emits stderr nag).
secret_load() {
  if [[ $# -lt 2 || -z "$1" || -z "$2" ]]; then
    printf 'usage: secret_load <env_var> <keychain_entry>\n' >&2
    return 2
  fi
  local var="$1"
  local entry="$2"

  # If already exported in this shell with a non-empty value, no-op. Indirect
  # expansion differs across shells: zsh uses ${(P)var}, bash uses ${!var}.
  local existing=""
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    eval 'existing="${(P)var:-}"'
  else
    existing="${!var:-}"
  fi
  if [[ -n "$existing" ]]; then
    return 0
  fi

  local value
  if value="$(secret_get "$entry")"; then
    export "$var=$value"
    return 0
  fi
  printf 'warn: keychain entry %q not found; %s remains unset\n' "$entry" "$var" >&2
  return 1
}

# secret_clear [keychain_entry]
#   With no args: drop all cached secrets (e.g. after a Keychain rotation).
#   With one arg: drop just that entry's cache slot.
#   Does not unset any env vars previously exported by secret_load — caller
#   is responsible for that if they want a true reset.
secret_clear() {
  if [[ $# -eq 0 ]]; then
    if [[ -n "${ZSH_VERSION:-}" ]]; then
      eval '__SECRET_CACHE=()'
    else
      # bash: unset every sentinel var. compgen -v lists matching var names.
      local v
      for v in $(compgen -v __SECRET_CACHE_ 2>/dev/null); do
        unset "$v"
      done
    fi
    return 0
  fi
  local entry="$1"
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    eval 'unset "__SECRET_CACHE[$entry]"'
  else
    unset "__SECRET_CACHE_${entry//[^A-Za-z0-9_]/_}"
  fi
}
