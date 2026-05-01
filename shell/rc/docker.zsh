#!/usr/bin/env zsh
# rc/docker.zsh — Docker CLI completions (rc-tier).
#
# Originally inserted by Docker Desktop installer; now scoped to rc-tier
# only (interactive shells need completions; non-interactive shells don't).
#
# The previous version called `compinit` directly. Per rev. 6 of
# zsh_init_plan.md §3 contract, the central `compinit` lives in
# init_rc.zsh — running once after ALL fpath-touching files have been
# sourced. This file only manipulates fpath now.

# shellcheck disable=SC2206
# Unquoted $fpath is intentional: zsh array-expand syntax (not bash
# word-splitting). Linted under zsh -n via the Makefile's lint-zsh target.
fpath=("$HOME/.docker/completions" $fpath)
