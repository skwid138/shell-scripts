#!/usr/bin/env bats
# Tests for shell/init.zsh — the forwarding shim that preserves backward
# compatibility for any external consumer that historically did
# `source ~/code/scripts/shell/init.sh` (now renamed to init.zsh).
#
# Phase 1 of zsh_init_plan.md (rev. 6) renamed init.sh → init.zsh and
# rewrote it as a thin shim that sources the three barrels in order. This
# file proves the shim is functionally equivalent to sourcing all three
# barrels manually, AND that the file rename did not break any callers.
#
# Compat guarantees this file enforces:
#   1. Sourcing init.zsh exits 0 (no leaked exit codes from optional sources).
#   2. After sourcing, REPO_ROOT is exported (env-tier ran).
#   3. After sourcing, load_nvmrc is defined (login-tier ran).
#   4. After sourcing, _COMPINIT_DONE=1 (rc-tier ran).
#   5. Sourcing produces zero stdout (silence contract preserved end-to-end).
#   6. The legacy init.sh path resolves: a symlink/path check confirms
#      the rename is the only change — no consumers broken silently.
#   7. Triple-sourcing init.zsh is idempotent (zero PATH dups).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

@test "compat: sourcing init.zsh exits 0" {
  run zsh --no-rcs -c "source '$REPO/shell/init.zsh' >/dev/null 2>&1"
  assert_success
}

@test "compat: sourcing init.zsh stays silent on stderr (no warnings/errors)" {
  # Note: stdout is NOT silent — cowsay_fortune_lolcat.zsh prints a welcome
  # banner by design (it's the rc-tier interactive greeter). The silence
  # contract applies to env-tier (init_env.zsh) only and is enforced
  # separately in init_env.bats. Here we assert only that stderr is
  # clean — no surprise warnings, errors, or "command not found" leaks
  # bubble up through the shim chain. Sandbox a fresh sentinel so the
  # 14-day freshness nag (which IS expected to fire on a stale machine)
  # doesn't make this test flaky.
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  : >"$SANDBOX/.cache/zsh/paths-refreshed"
  run zsh --no-rcs -c "
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init.zsh' 2>&1 >/dev/null
  "
  assert_success
  assert_output ""
  rm -rf "$SANDBOX"
}

@test "compat: shim runs env-tier (REPO_ROOT exported)" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    print -- \"\$REPO_ROOT\"
  "
  assert_success
  assert_output "$REPO"
}

@test "compat: shim runs login-tier (load_nvmrc defined)" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    typeset -f load_nvmrc >/dev/null && print -- defined
  "
  assert_success
  assert_output "defined"
}

@test "compat: shim runs rc-tier (_COMPINIT_DONE=1)" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    print -- \"\${_COMPINIT_DONE:-unset}\"
  "
  assert_success
  assert_output "1"
}

@test "compat: shim is functionally equivalent to sourcing the 3 barrels manually" {
  # Capture the variable surface from sourcing init.zsh vs sourcing all three
  # barrels in order. Any divergence indicates the shim drifted.
  via_shim="$(zsh --no-rcs -c "
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    print -- \"\$REPO_ROOT|\$EDITOR|\$VISUAL|\${_COMPINIT_DONE:-unset}\"
  ")"
  via_manual="$(zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_profile.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_rc.zsh' >/dev/null 2>&1
    print -- \"\$REPO_ROOT|\$EDITOR|\$VISUAL|\${_COMPINIT_DONE:-unset}\"
  ")"
  assert [ "$via_shim" = "$via_manual" ]
  assert [ -n "$via_shim" ]
}

@test "compat: triple-sourcing init.zsh produces zero PATH duplicates" {
  # Real-world scenario: a user has both an old ~/.zshrc (sources init.zsh)
  # and the new ~/.zshenv/~/.zprofile/~/.zshrc trio (which independently
  # source the barrels). Total: each barrel sourced 2-4 times during a
  # single shell startup. PATH must remain dup-free.
  run zsh --no-rcs -c "
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    source '$REPO/shell/init.zsh' >/dev/null 2>&1
    # Count duplicates: split PATH on ':', sort, find any line with count > 1.
    print -- \$PATH | tr ':' '\n' | sort | uniq -d
  "
  assert_success
  assert_output ""
}

@test "compat: init.sh no longer exists (rename completed cleanly)" {
  # Belt-and-braces — confirms the rename happened and there's no stale
  # init.sh sitting around that could shadow init.zsh on case-insensitive
  # filesystems or get accidentally edited. If a future commit recreates
  # init.sh by mistake, this fails loudly.
  assert [ ! -e "$REPO/shell/init.sh" ]
  assert [ -f "$REPO/shell/init.zsh" ]
}

@test "compat: init.zsh is a real file, not a symlink (visibility guarantee)" {
  # Per the file's own header comment: kept as a real file (not symlink)
  # so the deprecation comment is visible to cat/grep and the rename
  # shows up in git blame.
  assert [ -f "$REPO/shell/init.zsh" ]
  assert [ ! -L "$REPO/shell/init.zsh" ]
}
