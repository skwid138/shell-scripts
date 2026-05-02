#!/usr/bin/env bats
# Tests for shell/init_env.zsh — the env-tier barrel sourced from ~/.zshenv
# on EVERY zsh invocation (interactive, login, non-interactive, subshells).
#
# Contract under test (zsh_init_plan.md §3):
#   - Sources env/vars.zsh and env/paths.zsh.
#   - Exports REPO_ROOT, EDITOR, VISUAL.
#   - Silent on stdout. (stderr permitted: 14-day staleness nag.)
#   - No keychain access (no calls to keychain_get).
#   - Does NOT define rc-tier symbols (compinit, prompt, plugins).
#   - Idempotent: re-sourcing produces no PATH duplicates.
#
# All `zsh` invocations use `--no-rcs` so the user's real ~/.zshenv/.zshrc
# don't pollute the test shell with already-loaded state (spaceship, zplug,
# brew shims, secret env vars, etc.).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  # Resolve the repo root via realpath so tests work whether $BATS_TEST_DIRNAME
  # is the /var or the /private/var symlink form on macOS.
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

# --- exports -----------------------------------------------------------------

@test "init_env: exports REPO_ROOT pointing at scripts repo root" {
  run zsh --no-rcs -c "source '$REPO/shell/init_env.zsh' >/dev/null 2>&1; print -- \${REPO_ROOT:A}"
  assert_success
  # :A applies realpath; compare against our :A-resolved REPO.
  expected="$(cd "$REPO" && pwd -P)"
  assert_output "$expected"
}

@test "init_env: exports EDITOR=vim and VISUAL=vim" {
  run zsh --no-rcs -c "source '$REPO/shell/init_env.zsh' >/dev/null 2>&1; print -- \"\$EDITOR|\$VISUAL\""
  assert_success
  assert_output "vim|vim"
}

# --- silence + clean exit ---------------------------------------------------

@test "init_env: produces no stdout" {
  # stderr may carry the 14-day staleness nag — that's spec, not a failure.
  # Use a fresh XDG_CACHE_HOME with a fresh sentinel so the nag doesn't fire,
  # to keep this test about stdout cleanliness specifically.
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  : >"$SANDBOX/.cache/zsh/paths-refreshed"
  run zsh --no-rcs -c "
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>/dev/null
  "
  assert_success
  assert_output ""
  rm -rf "$SANDBOX"
}

@test "init_env: returns success exit status (does not leak optional-file failure)" {
  # Regression guard: prior to the explicit `return 0`, the final
  # `[[ -f optional-file ]]` test propagated exit 1 when the file was absent,
  # breaking `source init_env.zsh && do-thing` chains.
  run zsh --no-rcs -c "source '$REPO/shell/init_env.zsh' 2>/dev/null"
  assert_success
}

# --- no-keychain assertion --------------------------------------------------

@test "init_env: does not call keychain_get during sourcing" {
  # Stub `security` (the macOS keychain CLI keychain_get wraps). If anything
  # in init_env.zsh's chain reaches Keychain, the stub fires and writes to a
  # canary file. Stub returns failure to model "no entry found" without
  # actually probing the user's keychain.
  CANARY="$(mktemp)"
  STUBDIR="$(mktemp -d)"
  cat >"$STUBDIR/security" <<EOF
#!/usr/bin/env bash
echo "STUB-SECURITY-CALLED: \$*" >>"$CANARY"
exit 1
EOF
  chmod +x "$STUBDIR/security"

  run zsh --no-rcs -c "
    export PATH='$STUBDIR:/usr/bin:/bin'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    print -- done
  "
  assert_success
  assert_output --partial "done"

  # Canary must be empty — no security/keychain call happened.
  run cat "$CANARY"
  assert_output ""

  rm -rf "$STUBDIR" "$CANARY"
}

# --- no rc-tier leakage ------------------------------------------------------

@test "init_env: does not run compinit (rc-tier responsibility)" {
  run zsh --no-rcs -c "source '$REPO/shell/init_env.zsh' >/dev/null 2>&1; print -- \"\${_COMPINIT_DONE:-unset}\""
  assert_success
  assert_output "unset"
}

@test "init_env: does not load spaceship/zplug (rc-tier responsibility)" {
  # zsh inherits exported variables from the parent process (bats inherits
  # from this shell, which has spaceship/zplug already loaded). To test
  # that init_env.zsh ITSELF doesn't load these, we explicitly unset them
  # before sourcing and verify they're still unset after.
  run zsh --no-rcs -c "
    unset SPACESHIP_VERSION ZPLUG_HOME zplug_home
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    print -- \"\${SPACESHIP_VERSION:-no-spaceship}|\${ZPLUG_HOME:+zplug-loaded}\"
  "
  assert_success
  # SPACESHIP_VERSION should be "no-spaceship"; ZPLUG_HOME should be empty
  # (so the `${...:+...}` expansion produces nothing).
  assert_output "no-spaceship|"
}

# --- idempotency -------------------------------------------------------------

@test "init_env: triple-source produces zero PATH duplicates" {
  # Reset PATH to a known clean baseline so we measure ONLY duplicates
  # introduced by our own sourcing logic. Without this, the inherited
  # PATH from the bats runner (e.g. Ubuntu CI's PATH listing /snap/bin
  # twice) is reported as a "duplicate" — which is real but not caused
  # by our code, and outside our dedup contract.
  run zsh --no-rcs -c "
    PATH='/usr/bin:/bin'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    # Count duplicate entries in PATH
    print -l \${(s.:.)PATH} | sort | uniq -d
  "
  assert_success
  assert_output ""
}

# --- common.sh availability --------------------------------------------------

@test "init_env: makes warn() available (lib/common.sh sourced)" {
  run zsh --no-rcs -c "
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    typeset -f warn >/dev/null && print -- yes || print -- no
  "
  assert_success
  assert_output "yes"
}
