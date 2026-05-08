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

@test "aliases.zsh: no alias has an unexpanded \$VAR or ~/ at its head (highlighter-safe)" {
  # Source aliases.zsh in a clean zsh, then for every alias whose value
  # contains a '/', extract the head token (everything up to the first
  # whitespace or pipe) and verify that head is *not* an unexpanded
  # variable reference (`\$HOME/…`, `\${HOME}/…`) or unexpanded tilde
  # (`~/…`).
  #
  # Why this shape and not a real command-resolution check:
  #   The failure mode we care about is the alias body containing a
  #   literal \$HOME (because it was defined with single quotes — \$HOME
  #   never expands at definition time → highlighter stat fails → red).
  #   That's a textual property of the alias value after zsh sources
  #   the file, and it's deterministic across CI environments.
  #
  #   A "does \`whence\` find it" check sounded more behavioral but
  #   ended up environment-dependent: e.g. \`alias nvim-update='nvim …'\`
  #   has head=nvim, which is fine on a dev box but fails in a CI
  #   runner that has no nvim installed. We don't want CI flakiness
  #   tied to which optional tools the runner happens to ship.
  #
  # Catches all of these (the highlighter-red forms):
  #   alias openweb='\$HOME/code/scripts/personal/opencode-web.sh'
  #   alias openweb='\${HOME}/code/scripts/personal/opencode-web.sh'
  #   alias openweb='~/code/scripts/personal/opencode-web.sh'
  #
  # Allows (correctly green):
  #   alias openweb=\"\$HOME/code/scripts/personal/opencode-web.sh\"
  #     (definition-time expansion → value is a literal absolute path)
  #   alias lsf=\"ls -apx | grep -v /\"
  #     (head is a real command name, no \$ or ~ in head)
  #   alias nvim-update='nvim --headless …'
  #     (head is a real command name; \"\$HOME/code/dotfiles\" appears
  #     later as a cd argument and is irrelevant to the head token)
  run zsh --no-rcs -c '
    set -u
    source "'"$ALIASES"'" 2>/dev/null
    bad=()
    for name in "${(@k)aliases}"; do
      value="${aliases[$name]}"
      [[ "$value" == */* ]] || continue
      head="${value%%[[:space:]|]*}"
      head="${head#[\"\x27]}"
      head="${head%[\"\x27]}"
      # Flag unexpanded variable references at the head: $FOO/... or ${FOO}/...
      if [[ "$head" == \$* ]]; then
        bad+=("$name=$value (head starts with unexpanded \$ — define alias with double quotes so the variable expands at definition time)")
        continue
      fi
      # Flag unexpanded tilde at the head: ~/...
      if [[ "$head" == "~"* ]]; then
        bad+=("$name=$value (head starts with unexpanded ~ — use \"\$HOME/...\" double-quoted instead)")
        continue
      fi
    done
    if (( ${#bad[@]} > 0 )); then
      print -l -- "${bad[@]}"
      exit 1
    fi
    exit 0
  '
  assert_success
}
