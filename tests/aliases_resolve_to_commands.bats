#!/usr/bin/env bats
# Tests for shell/rc/aliases.zsh — every alias must resolve to a real,
# stat-able command so zsh-syntax-highlighting paints it green, not red.
#
# Background
# ----------
# zsh-syntax-highlighting's `main` highlighter resolves an alias and then
# stats the resulting string to decide whether the alias points at a real
# command. If the alias value is the literal string `$HOME/foo.sh` (i.e.
# the alias was defined with single quotes so $HOME does NOT expand at
# definition time), the highlighter never expands $HOME — stat() fails and
# the alias is painted red as `unknown-token` in fresh shells. The shell
# itself still runs the alias correctly (the variable expands at use time
# during command execution), but the prompt looks broken.
#
# The fix is to define script-path aliases with double quotes so $HOME
# expands at *alias-definition time* and the alias value is a literal
# absolute path the highlighter can stat.
#
# This file pins that invariant so a future "stylistic" rewrite back to
# single-quoted form is caught in CI before it lands.
#
# What we assert (per alias defined in shell/rc/aliases.zsh):
#   - If the alias value contains '/', its head token must resolve to
#     either an absolute path that exists, OR a command findable via
#     `whence -p`. This catches:
#       alias openweb='$HOME/code/scripts/personal/opencode-web.sh'
#                                      ^ literal $, never expands
#     because the head token is `$HOME/code/...` which is neither an
#     absolute path nor a command name.
#   - Plain pipeline aliases like `lsf='ls -apx | grep -v /'` are fine —
#     their head token (`ls`) is a real command.
#   - Pure builtins like `v=nvim` are fine.
#
# We deliberately do NOT lint the source file textually (e.g. grep for
# single-quoted `$HOME`). The behavioral check is what actually matters
# to the highlighter; a textual rule would over-fit and miss
# alternative ways the same bug could regress (e.g. `'~/code/...'`).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  ALIASES="$REPO/shell/rc/aliases.zsh"
}

@test "aliases.zsh: file exists" {
  [[ -f "$ALIASES" ]]
}

@test "aliases.zsh: every alias resolves to a real command (no literal \$HOME / ~ in value)" {
  # Source aliases.zsh in a clean zsh, then for every alias whose value
  # contains a '/', extract the head token (everything up to the first
  # whitespace) and verify it's a command zsh can find. This is the same
  # check zsh-syntax-highlighting effectively performs.
  #
  # whence -p only finds external commands on PATH; we also accept any
  # absolute path that exists on disk, to allow alias values like
  # `/usr/local/bin/foo` even if /usr/local/bin isn't on PATH in the
  # test environment.
  #
  # This is the canonical regression guard for the `'$HOME/foo.sh'`
  # (single-quoted, never-expanded) form. The broken form has a head
  # token of `$HOME/foo.sh`, which is neither an absolute path on disk
  # nor a command zsh can find — so this test fails.
  run zsh --no-rcs -c '
    set -u
    source "'"$ALIASES"'" 2>/dev/null
    bad=()
    # Iterate every defined alias.
    for name in "${(@k)aliases}"; do
      value="${aliases[$name]}"
      # Only check aliases whose value contains a /; plain aliases like
      # v=nvim or vim=nvim resolve trivially.
      [[ "$value" == */* ]] || continue
      # Head token: everything up to the first whitespace or pipe.
      head="${value%%[[:space:]|]*}"
      # Strip surrounding single/double quotes if any leaked through.
      head="${head#[\"\x27]}"
      head="${head%[\"\x27]}"
      # OK if it is an existing absolute path...
      if [[ "$head" == /* && -e "$head" ]]; then
        continue
      fi
      # ...or a command zsh can find on PATH (handles aliases like
      # lsf="ls -apx | grep -v /" where head=ls).
      if whence -p -- "$head" >/dev/null 2>&1; then
        continue
      fi
      # Builtins / functions / reserved words are fine too.
      if whence -- "$head" >/dev/null 2>&1; then
        continue
      fi
      bad+=("$name=$value (unresolvable head: $head)")
    done
    if (( ${#bad[@]} > 0 )); then
      print -l -- "${bad[@]}"
      exit 1
    fi
    exit 0
  '
  assert_success
}
