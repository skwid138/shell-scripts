#!/usr/bin/env zsh
# rc/docker.zsh — Docker CLI completions (rc-tier).
#
# Originally inserted by Docker Desktop installer; now scoped to rc-tier
# only (interactive shells need completions; non-interactive shells don't).
#
# The previous version called `compinit` directly. Completion init now
# happens later in the rc tier (zplug's compinit in rc/zsh_plugins.zsh, or
# the fallback guard in init_rc.zsh) — after ALL fpath-touching files have
# been sourced. This file only manipulates fpath now.

# shellcheck disable=SC2206
# Unquoted $fpath is intentional: zsh array-expand syntax (not bash
# word-splitting). Linted under zsh -n via the Makefile's lint-zsh target.
fpath=("$HOME/.docker/completions" $fpath)
