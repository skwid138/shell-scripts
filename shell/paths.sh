#!/bin/bash
# PATH configuration. Sourced from ~/.zshrc.
#
# Defensive note: when `brew --prefix <pkg>` fails (uninstalled keg, broken
# tap), we skip adding that segment instead of injecting an empty prefix that
# would corrupt PATH (e.g. ":/libexec/gnubin:$PATH").

# Homebrew itself
export PATH="/opt/homebrew/bin:$PATH"

# Helper: prepend "<brew-prefix-of-pkg>/<suffix>" to PATH if the prefix exists.
_prepend_brew_path() {
  local pkg="$1"
  local suffix="$2"
  local prefix
  prefix="$(brew --prefix "$pkg" 2>/dev/null)" || return 0
  [[ -n "$prefix" && -d "${prefix}${suffix}" ]] || return 0
  export PATH="${prefix}${suffix}:$PATH"
}

# Check if brew is available before proceeding
if command -v brew &>/dev/null; then
  # GNU coreutils (head, tail, ls, cp, mv, rm, cat, sort, uniq, etc.)
  _prepend_brew_path coreutils /libexec/gnubin

  # GNU grep
  _prepend_brew_path grep /libexec/gnubin

  # GNU sed
  _prepend_brew_path gnu-sed /libexec/gnubin

  # GNU awk
  _prepend_brew_path gawk /libexec/gnubin

  # GNU find
  _prepend_brew_path findutils /libexec/gnubin

  # PostgreSQL (versioned, keg-only). Use the first available version.
  for pg_version in postgresql@17 postgresql@14 postgresql; do
    pg_prefix="$(brew --prefix "$pg_version" 2>/dev/null)" || continue
    if [[ -n "$pg_prefix" && -d "${pg_prefix}/bin" ]]; then
      export PATH="${pg_prefix}/bin:$PATH"
      break # Only add the first PostgreSQL version found
    fi
  done
  unset pg_prefix
else
  echo "Warning: brew command not found. Some PATH configurations skipped." >&2
fi

# User-local installs (pipx, Cursor Agent, etc.) if duplicates homebrew versions would be used instead
export PATH="$HOME/.local/bin:$PATH"

# Go packages (installed via `go install`)
if [ -d "$HOME/go/bin" ]; then
  export PATH="$HOME/go/bin:$PATH"
fi

# User bin should be last, so it takes precedence
export PATH="$HOME/bin:$PATH"
