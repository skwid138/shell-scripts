#!/usr/bin/env bats
# Tests for shell/init_rc.zsh — the interactive-shell barrel sourced from
# ~/.zshrc on every interactive shell (login or not).
#
# Contract under test (zsh_init_plan.md §3):
#   - Sources rc/* sub-files.
#   - Runs central compinit guard (`_COMPINIT_DONE=1` after first source).
#   - Re-sourcing does not re-run compinit (guard is effective).
#   - Sources lib/auto_nvm.zsh (idempotent re-source, no duplicate hook).
#
# Note: rc/zsh_plugins.zsh sources zplug, which calls `compinit` internally
# during `zplug load` for each plugin. This is independent of our central
# compinit guard. The guard prevents OUR call from firing twice; it doesn't
# (and can't) prevent zplug's internal calls. Tests below assert the guard
# behavior we control, not zplug's.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

# --- compinit guard ---------------------------------------------------------

@test "init_rc: sets _COMPINIT_DONE=1 after first source" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    print -- \"\$_COMPINIT_DONE\"
  "
  assert_success
  assert_output "1"
}

@test "init_rc: re-sourcing does not re-run our central compinit (guard is effective)" {
  # Our central compinit guard sits at the END of init_rc.zsh and is gated
  # on `_COMPINIT_DONE`. Set _COMPINIT_DONE=1 BEFORE the first source — if
  # the guard works, our central compinit call NEVER fires (only zplug's
  # internal compinit calls during plugin load can still happen, but those
  # are not what this guard is about).
  CANARY="$(mktemp)"
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    # Stub compinit BEFORE any sourcing so any call routes through it.
    compinit() { echo call >>'$CANARY'; }
    # Pre-set the guard sentinel; central guard MUST honor it.
    _COMPINIT_DONE=1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    # zplug calls compinit during 'zplug load'; our guard call should NOT
    # fire because _COMPINIT_DONE was pre-set. Compare to a baseline source
    # in a separate sub-shell where _COMPINIT_DONE is unset (guard fires).
    pre_set_count=\$(wc -l <'$CANARY' | tr -d ' ')
    print -- \"pre-set: \$pre_set_count\"
  "
  assert_success
  pre_set="$(echo "$output" | grep -oE 'pre-set: [0-9]+' | awk '{print $2}')"

  # Now run with _COMPINIT_DONE unset — central guard fires once additional.
  CANARY2="$(mktemp)"
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    compinit() { echo call >>'$CANARY2'; }
    # _COMPINIT_DONE is unset — central guard SHOULD fire.
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    print -- \"unset: \$(wc -l <'$CANARY2' | tr -d ' ')\"
  "
  assert_success
  unset_count="$(echo "$output" | grep -oE 'unset: [0-9]+' | awk '{print $2}')"

  # The unset run must call compinit one more time than the pre-set run
  # (our guard block contributes exactly +1 compinit call when sentinel
  # is unset). zplug's own calls are constant across both runs.
  diff=$((unset_count - pre_set))
  assert_equal "$diff" "1"

  rm -f "$CANARY" "$CANARY2"
}

# --- auto_nvm dual-source idempotency --------------------------------------

@test "init_rc: sourcing after init_profile does not duplicate chpwd hook" {
  # The dual-source contract: lib/auto_nvm.zsh is sourced from BOTH
  # init_profile (login) and init_rc (interactive). add-zsh-hook dedups
  # identical (hook,fn) pairs, so chpwd_functions should contain load_nvmrc
  # exactly once.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    # Print only the chpwd_functions array, one per line, then count load_nvmrc.
    print -l \"\${chpwd_functions[@]}\" | grep -c '^load_nvmrc\$'
  "
  assert_success
  assert_output "1"
}

# --- rc-tier sub-file loading -----------------------------------------------

@test "init_rc: defines brew() function (from rc/functions.zsh)" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    typeset -f brew >/dev/null && print -- yes || print -- no
  "
  assert_success
  assert_output "yes"
}

@test "init_rc: defines aliases (from rc/aliases.zsh)" {
  # `v=nvim` is one of the more durable aliases in aliases.zsh; if any future
  # alias-set rename happens, this test will catch it and prompt updating.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    alias v 2>/dev/null
  "
  assert_success
  assert_output --partial "v="
}

@test "init_rc: returns success exit status" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
  "
  assert_success
}
