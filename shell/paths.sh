#!/bin/bash

# Homebrew and Homebrew packages
export PATH="/opt/homebrew/bin:$PATH"

# Check if brew is available before proceeding
if command -v brew &>/dev/null; then
    # GNU coreutils (head, tail, ls, cp, mv, rm, cat, sort, uniq, etc.)
    export PATH="$(brew --prefix coreutils)/libexec/gnubin:$PATH"

    # GNU grep
    export PATH="$(brew --prefix grep)/libexec/gnubin:$PATH"

    # GNU sed
    export PATH="$(brew --prefix gnu-sed)/libexec/gnubin:$PATH"

    # GNU awk
    export PATH="$(brew --prefix gawk)/libexec/gnubin:$PATH"

    # GNU find
    export PATH="$(brew --prefix findutils)/libexec/gnubin:$PATH"

    # PostgreSQL (versioned)
    if command -v brew &>/dev/null; then
        # Add PostgreSQL binaries to path (versioned packages are keg-only)
        for pg_version in postgresql@17 postgresql@14 postgresql; do
            if [ -d "$(brew --prefix ${pg_version} 2>/dev/null)/bin" ]; then
                export PATH="$(brew --prefix ${pg_version})/bin:$PATH"
                # Log that PostgreSQL was found and added to PATH
                #echo "PostgreSQL ${pg_version} binaries added to PATH"
                break  # Only add the first PostgreSQL version found
            fi
        done
    fi
else
    echo "Warning: brew command not found. Some PATH configurations skipped."
fi

# User-local installs (pipx, Cursor Agent, etc.) if duplicates homebrew versions would be used instead
export PATH="$HOME/.local/bin:$PATH"

# Go packages (installed via `go install`)
if [ -d "$HOME/go/bin" ]; then
    export PATH="$HOME/go/bin:$PATH"
fi

# User bin should be last, so it takes precedence
export PATH="$HOME/bin:$PATH"
