#!/usr/bin/env bats
# Tests for the dual-source contract of shell/lib/auto_nvm.zsh.
#
# auto_nvm.zsh is sourced from BOTH init_profile.zsh (login shells) and
# init_rc.zsh (interactive shells). For login+interactive shells (the GUI
# Terminal/Ghostty first-tab case), it gets sourced twice. This must be
# idempotent:
#   - load_nvmrc defined once.
#   - chpwd_functions contains load_nvmrc exactly once.
#   - Running load_nvmrc twice in the same dir hits the LAST_NVM_DIR
#     short-circuit (no nvm shellouts on repeat).
# It must also be a silent no-op when nvm is not loaded (interactive
# non-login shells only get nvm via the login tier), without poisoning the
# LAST_NVM_DIR sentinel for a later call once nvm is defined.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # Sandbox HOME so nothing in the real ~/.nvm (or any rc file) leaks in.
  export HOME="$BATS_TEST_TMPDIR/home"
  WORKDIR="$BATS_TEST_TMPDIR/work"
  NVM_LOG="$BATS_TEST_TMPDIR/nvm.log"
  mkdir -p "$HOME" "$WORKDIR"
  : >"$NVM_LOG"
}

# Emit a POSIX-ish (bash + zsh) nvm stub definition that logs each call's
# argv to $NVM_LOG and answers the subcommands load_nvmrc relies on.
#   $1 = version reported by `nvm current`
#   $2 = version reported by `nvm alias default`
#   $3 = exit status of `nvm use` (default 0)
nvm_stub() {
  cat <<EOF
nvm() {
  printf '%s\n' "\$*" >>'$NVM_LOG'
  case "\$1" in
    current) printf '%s\n' '$1' ;;
    alias) printf '%s\n' 'default -> 20 (-> $2)' ;;
    use) return ${3:-0} ;;
  esac
}
EOF
}

nvm_call_count() {
  wc -l <"$NVM_LOG" | tr -d ' '
}

# --- nvm absent (interactive non-login shell: nvm only loads in login tier) --

@test "auto_nvm: no nvm and no .nvmrc -> silent success" {
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    source '$REPO/shell/lib/auto_nvm.zsh'
    load_nvmrc
  "
  assert_success
  refute_output --partial 'command not found'
}

@test "auto_nvm: no nvm with .nvmrc present -> silent success" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    source '$REPO/shell/lib/auto_nvm.zsh'
  "
  assert_success
  refute_output --partial 'command not found'
}

@test "auto_nvm: nvm defined later in same shell+dir is still processed" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    source '$REPO/shell/lib/auto_nvm.zsh'   # immediate load_nvmrc, nvm absent
    $(nvm_stub v18.0.0 v18.0.0)
    load_nvmrc                              # same dir, nvm now present
  "
  assert_success
  refute_output --partial 'command not found'
  run cat "$NVM_LOG"
  assert_line 'use'
}

@test "auto_nvm: dual-source registers chpwd hook exactly once" {
  run zsh --no-rcs -c "
    # Stub nvm so auto_nvm.zsh's call doesn't escape into reality.
    nvm() { :; }
    source '$REPO/shell/lib/auto_nvm.zsh' >/dev/null 2>&1
    source '$REPO/shell/lib/auto_nvm.zsh' >/dev/null 2>&1
    # Count load_nvmrc occurrences in chpwd_functions
    print -l \${chpwd_functions[@]} | grep -c '^load_nvmrc\$'
  "
  assert_success
  assert_output "1"
}

@test "auto_nvm: load_nvmrc is defined after sourcing" {
  run zsh --no-rcs -c "
    nvm() { :; }
    source '$REPO/shell/lib/auto_nvm.zsh' >/dev/null 2>&1
    typeset -f load_nvmrc >/dev/null && print -- yes || print -- no
  "
  assert_success
  assert_output "yes"
}

@test "auto_nvm: LAST_NVM_DIR short-circuit prevents repeat nvm calls" {
  # The immediate load_nvmrc at source time does the work once; repeat calls
  # in the same directory must not shell out to nvm again.
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v20.1.0 v20.1.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
    print -- \"first=\$(wc -l <'$NVM_LOG' | tr -d ' ')\"
    load_nvmrc
    load_nvmrc
    print -- \"after=\$(wc -l <'$NVM_LOG' | tr -d ' ')\"
  "
  assert_success
  # current + alias default on the first pass; nothing afterwards.
  assert_line 'first=2'
  assert_line 'after=2'
}

@test "auto_nvm: changing directory re-runs the check" {
  mkdir -p "$WORKDIR/other"
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v20.1.0 v20.1.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
    cd '$WORKDIR/other'   # chpwd hook -> load_nvmrc
  "
  assert_success
  [ "$(nvm_call_count)" -eq 4 ]
}

# --- version switching (nvm present) ----------------------------------------

@test "auto_nvm: .nvmrc version mismatch -> nvm use" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v18.0.0 v18.0.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
  "
  assert_success
  run cat "$NVM_LOG"
  assert_line 'use'
  refute_line 'install'
}

@test "auto_nvm: .nvmrc version mismatch and nvm use fails -> nvm install" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v18.0.0 v18.0.0 3)
    source '$REPO/shell/lib/auto_nvm.zsh'
  "
  assert_success
  run cat "$NVM_LOG"
  assert_line 'use'
  assert_line 'install'
}

@test "auto_nvm: .nvmrc version matches current -> no switch" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v20.1.0 v18.0.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
  "
  assert_success
  run cat "$NVM_LOG"
  assert_output 'current'
}

@test "auto_nvm: no .nvmrc and current != default -> nvm use default" {
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v18.0.0 v20.1.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
  "
  assert_success
  run cat "$NVM_LOG"
  assert_line 'use default --silent'
}

@test "auto_nvm: no .nvmrc and current == default -> no switch" {
  run zsh --no-rcs -c "
    cd '$WORKDIR'
    $(nvm_stub v20.1.0 v20.1.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
  "
  assert_success
  run cat "$NVM_LOG"
  refute_line --partial 'use'
}

# --- bash sourcing path -----------------------------------------------------

@test "auto_nvm (bash): sourcing wires PROMPT_COMMAND without calling nvm" {
  run bash --norc --noprofile -c "
    cd '$WORKDIR'
    $(nvm_stub v18.0.0 v20.1.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
    printf '%s\n' \"\$PROMPT_COMMAND\"
  "
  assert_success
  assert_output --partial 'cd_nvm_use'
  [ "$(nvm_call_count)" -eq 0 ]
}

@test "auto_nvm (bash): no nvm -> load_nvmrc is silent success" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run bash --norc --noprofile -c "
    cd '$WORKDIR'
    source '$REPO/shell/lib/auto_nvm.zsh'
    cd_nvm_use
  "
  assert_success
  refute_output --partial 'command not found'
}

@test "auto_nvm (bash): .nvmrc mismatch -> nvm use" {
  echo 'v20.1.0' >"$WORKDIR/.nvmrc"
  run bash --norc --noprofile -c "
    cd '$WORKDIR'
    $(nvm_stub v18.0.0 v18.0.0)
    source '$REPO/shell/lib/auto_nvm.zsh'
    cd_nvm_use
  "
  assert_success
  run cat "$NVM_LOG"
  assert_line 'use'
}

@test "auto_nvm: LAST_NVM_DIR is set after first load_nvmrc call" {
  TMPDIR="$(mktemp -d)"
  run zsh --no-rcs -c "
    cd '$TMPDIR'
    nvm() { :; }
    source '$REPO/shell/lib/auto_nvm.zsh' >/dev/null 2>&1
    print -- \"\$LAST_NVM_DIR\"
  "
  assert_success
  # Realpath/symlink resolution may differ on darwin; just assert it's
  # non-empty and contains the directory leaf.
  assert [ -n "$output" ]
  rm -rf "$TMPDIR"
}
