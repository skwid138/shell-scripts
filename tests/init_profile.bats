#!/usr/bin/env bats
# Tests for shell/init_profile.zsh — the login-tier barrel sourced from
# ~/.zprofile on login shells only (`zsh -l`, ssh, GUI Terminal first tab).
#
# Contract under test (zsh_init_plan.md §3):
#   - Tolerant of missing tools (each sub-file is existence-gated).
#   - Sources lib/auto_nvm.zsh (defines load_nvmrc).
#   - Does NOT touch fpath/compinit (rc-tier).
#
# HOME and ZDOTDIR are exported as per-test temp dirs in setup(): the barrel
# resolves ~/.nvm, ~/miniconda3 and the ~/code/wpromote private layer from
# $HOME, so every test runs against an empty sandbox HOME (no nvm, no conda)
# unless it plants files there (see the sandbox canary test).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  ISO_HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$ISO_HOME"
  export HOME="$ISO_HOME"
  export ZDOTDIR="$BATS_TEST_TMPDIR/zdot"
  mkdir -p "$ZDOTDIR"
}

@test "init_profile: resolves HOME-relative nvm/private paths inside the test sandbox" {
  # Canary: plant a fake ~/.nvm/nvm.sh and private-layer barrels under the sandbox HOME (via $ISO_HOME, never $HOME, so a broken
  # isolation can't write into the real home) and assert they are the ones
  # the barrel picks up.
  CANARY="$BATS_TEST_TMPDIR/canary.log"
  : >"$CANARY"
  priv="$ISO_HOME/code/wpromote/scripts/shell"
  mkdir -p "$priv" "$ISO_HOME/.nvm"
  for tier in env profile; do
    printf 'print -r -- wpromote-%s >>%q\n' "$tier" "$CANARY" >"$priv/init_$tier.zsh"
  done
  printf 'nvm() { print -r -- "nvm $*" >>%q; }\n' "$CANARY" >"$ISO_HOME/.nvm/nvm.sh"

  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -r -- \"NVM_DIR=\$NVM_DIR\"
  "
  assert_success
  assert_output "NVM_DIR=$ISO_HOME/.nvm"
  run cat "$CANARY"
  assert_line "wpromote-env"
  assert_line "wpromote-profile"
  assert_line "nvm use default --silent"
}

# --- safe sourcing -----------------------------------------------------------

@test "init_profile: sources cleanly after init_env" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- ok
  "
  assert_success
  assert_output --partial "ok"
}

@test "init_profile: sources cleanly even when invoked first (defensive %x fallback)" {
  # init_env normally exports SCRIPTS_DIR; init_profile has a defensive
  # fallback. Test the fallback by NOT sourcing init_env first.
  run zsh --no-rcs -c "
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- ok
  "
  assert_success
  assert_output --partial "ok"
}

@test "init_profile: returns success exit status" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
  "
  assert_success
}

# --- auto_nvm exposes load_nvmrc --------------------------------------------

@test "init_profile: defines load_nvmrc function" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    typeset -f load_nvmrc >/dev/null && print -- yes || print -- no
  "
  assert_success
  assert_output "yes"
}

# --- tool-init existence-gating ---------------------------------------------

@test "init_profile: does not error when ~/.nvm is absent" {
  # The sandbox HOME from setup() has no ~/.nvm. The login/nvm.zsh source
  # line is gated on `-d $HOME/.nvm`, so this should be a no-op, and
  # lib/auto_nvm.zsh's immediate load_nvmrc must not leak
  # "command not found: nvm" to stderr.
  [[ ! -e "$ISO_HOME/.nvm" ]]
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' 2>&1 >/dev/null
    print -- ok
  "
  assert_success
  assert_output --partial "ok"
  refute_output --partial "command not found: nvm"
}

@test "init_profile: does not error when ~/miniconda3 is absent" {
  # The sandbox HOME from setup() has no ~/miniconda3.
  [[ ! -e "$ISO_HOME/miniconda3" ]]
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- ok
  "
  assert_success
  assert_output --partial "ok"
}

# --- no rc-tier work --------------------------------------------------------

@test "init_profile: does not run compinit" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- \"\${_COMPINIT_DONE:-unset}\"
  "
  assert_success
  assert_output "unset"
}
