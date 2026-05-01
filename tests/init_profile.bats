#!/usr/bin/env bats
# Tests for shell/init_profile.zsh — the login-tier barrel sourced from
# ~/.zprofile on login shells only (`zsh -l`, ssh, GUI Terminal first tab).
#
# Contract under test (zsh_init_plan.md §3):
#   - Tolerant of missing tools (each sub-file is existence-gated).
#   - Sources lib/auto_nvm.zsh (defines load_nvmrc).
#   - Does NOT touch fpath/compinit (rc-tier).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
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
  # Override HOME to a sandbox where ~/.nvm doesn't exist. The login/nvm.zsh
  # source line is gated on `-d $HOME/.nvm`, so this should be a no-op.
  SANDBOX="$(mktemp -d)"
  run zsh --no-rcs -c "
    HOME='$SANDBOX'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- ok
  "
  assert_success
  assert_output --partial "ok"
  rm -rf "$SANDBOX"
}

@test "init_profile: does not error when ~/miniconda3 is absent" {
  SANDBOX="$(mktemp -d)"
  run zsh --no-rcs -c "
    HOME='$SANDBOX'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    print -- ok
  "
  assert_success
  assert_output --partial "ok"
  rm -rf "$SANDBOX"
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
