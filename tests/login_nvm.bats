#!/usr/bin/env bats
# Tests for shell/login/nvm.zsh — login-tier nvm loader.
#
# Contract under test:
#   - When ~/.nvm exists but nvm.sh is missing (broken/partial install), the
#     leaf must not call `nvm` (no "command not found: nvm" on stderr) and
#     must leave a 0 status as its last command.
#   - When nvm.sh is present and defines `nvm`, the leaf activates the
#     default alias exactly once (`nvm use default --silent`).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  SANDBOX="$BATS_TEST_TMPDIR/home"
  mkdir -p "$SANDBOX/.nvm"
  # Sandbox HOME (exported, so every spawned zsh starts with it): the real
  # ~/.nvm, ~/miniconda3 and ~/code/wpromote layer are never read.
  export HOME="$SANDBOX"
  export ZPLUG_HOME="$BATS_TEST_TMPDIR/.zplug"
  export ZDOTDIR="$BATS_TEST_TMPDIR/zdot"
  mkdir -p "$ZDOTDIR"
}

@test "login/nvm: leaf returns 0 and stays quiet when ~/.nvm lacks nvm.sh" {
  run zsh --no-rcs -c "
    source '$REPO/shell/login/nvm.zsh' 2>&1
    print -- \"rc=\$?\"
  "
  assert_success
  assert_line 'rc=0'
  refute_output --partial 'command not found: nvm'
}

@test "login/nvm: init_profile barrel emits no nvm error when ~/.nvm lacks nvm.sh" {
  run zsh --no-rcs -c "
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' 2>&1 >/dev/null
    print -- ok
  "
  assert_success
  assert_output --partial 'ok'
  refute_output --partial 'command not found: nvm'
}

@test "login/nvm: leaf calls 'nvm use default --silent' exactly once when nvm loads" {
  # Tested on the leaf, not the barrel: the barrel also sources
  # lib/auto_nvm.zsh whose load_nvmrc may legitimately call nvm again.
  NVM_LOG="$BATS_TEST_TMPDIR/nvm-calls.log"
  : >"$NVM_LOG"
  cat >"$SANDBOX/.nvm/nvm.sh" <<EOF
nvm() { print -r -- "\$*" >>'$NVM_LOG'; }
EOF
  run zsh --no-rcs -c "
    source '$REPO/shell/login/nvm.zsh'
    print -- \"rc=\$?\"
  "
  assert_success
  assert_line 'rc=0'
  run cat "$NVM_LOG"
  assert_output 'use default --silent'
}
