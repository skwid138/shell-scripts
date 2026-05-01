#!/usr/bin/env bats
# Tests for end-to-end PATH ordering invariants.
#
# These tests guard the contract that motivated the Phase 4.5 follow-up
# fix: the env-tier (~/code/scripts/shell/env/paths.zsh) is responsible
# for the *order* of PATH, and login shells must end up with
# /opt/homebrew/bin ahead of /usr/bin and /bin.
#
# Why this matters:
#   On macOS, /etc/zprofile runs `path_helper` BETWEEN ~/.zshenv and
#   ~/.zprofile, rewriting PATH from /etc/paths and /etc/paths.d/* and
#   demoting whatever the env-tier carefully built. Symptom in the wild:
#   `#!/usr/bin/env bash` shebangs resolve to /bin/bash 3.2.57 instead
#   of /opt/homebrew/bin/bash 5.x, and bash 3.2 errors on idioms
#   (empty-array expansion under `set -u`, associative-array literals,
#   etc.) that work fine on bash 5.
#
# Two layers of test coverage:
#
#   1. Unit: _path_prepend MUST promote an already-present dir to the
#      front of PATH, not no-op. Without promotion, re-sourcing the
#      env-tier from .zprofile (after path_helper has demoted homebrew)
#      doesn't restore the intended ordering.
#
#   2. Integration: a full `zsh -lc` login shell with a clean parent
#      PATH must end up with /opt/homebrew/bin before /usr/bin:/bin
#      after all init has run.
#
# Strategy: every test pins PATH to a known-bad initial state (the
# `path_helper`-style ordering with /usr/bin:/bin in front) and asserts
# the env-tier moves /opt/homebrew/bin to the front.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
}

# Helper: position of $1 in $PATH (1-indexed, 0 if absent).
# Implemented in zsh inside the test's subshell rather than here in bash.

# --- _path_prepend: promote-to-front semantics -------------------------------

@test "_path_prepend: prepends a dir not already on PATH" {
  run zsh --no-rcs -c '
    source "'"$REPO"'/shell/env/paths.zsh" >/dev/null 2>&1
    PATH="/usr/bin:/bin"
    _path_prepend "/opt/homebrew/bin"
    print -- "$PATH"
  '
  assert_success
  assert_output "/opt/homebrew/bin:/usr/bin:/bin"
}

@test "_path_prepend: no-op when dir is already at the FRONT of PATH" {
  run zsh --no-rcs -c '
    source "'"$REPO"'/shell/env/paths.zsh" >/dev/null 2>&1
    PATH="/opt/homebrew/bin:/usr/bin:/bin"
    _path_prepend "/opt/homebrew/bin"
    print -- "$PATH"
  '
  assert_success
  assert_output "/opt/homebrew/bin:/usr/bin:/bin"
}

@test "_path_prepend: PROMOTES a dir that is on PATH but not at the front" {
  # This is the regression test for the macOS path_helper issue: env-tier
  # runs from .zshenv, prepends /opt/homebrew/bin, then path_helper rewrites
  # PATH and demotes homebrew to AFTER /usr/bin. When .zprofile re-sources
  # the env-tier, _path_prepend must MOVE /opt/homebrew/bin back to the
  # front, not no-op because "it's already on PATH somewhere".
  run zsh --no-rcs -c '
    source "'"$REPO"'/shell/env/paths.zsh" >/dev/null 2>&1
    PATH="/usr/bin:/bin:/opt/homebrew/bin"
    _path_prepend "/opt/homebrew/bin"
    print -- "$PATH"
  '
  assert_success
  assert_output "/opt/homebrew/bin:/usr/bin:/bin"
}

@test "_path_prepend: promotion preserves order of remaining entries" {
  run zsh --no-rcs -c '
    source "'"$REPO"'/shell/env/paths.zsh" >/dev/null 2>&1
    PATH="/a:/b:/opt/homebrew/bin:/c:/d"
    [[ -d "/opt/homebrew/bin" ]] || { print "skip"; exit 0; }
    _path_prepend "/opt/homebrew/bin"
    print -- "$PATH"
  '
  assert_success
  if [[ "$output" == "skip" ]]; then
    skip "/opt/homebrew/bin not present on this host"
  fi
  assert_output "/opt/homebrew/bin:/a:/b:/c:/d"
}

@test "_path_prepend: skips non-existent dirs (no PATH mutation)" {
  run zsh --no-rcs -c '
    source "'"$REPO"'/shell/env/paths.zsh" >/dev/null 2>&1
    PATH="/usr/bin:/bin"
    _path_prepend "/this/does/not/exist/anywhere"
    print -- "$PATH"
  '
  assert_success
  assert_output "/usr/bin:/bin"
}

@test "_path_prepend: idempotent under repeated calls (no duplicates)" {
  run zsh --no-rcs -c '
    source "'"$REPO"'/shell/env/paths.zsh" >/dev/null 2>&1
    PATH="/usr/bin:/bin"
    _path_prepend "/opt/homebrew/bin"
    _path_prepend "/opt/homebrew/bin"
    _path_prepend "/opt/homebrew/bin"
    # Count occurrences via :PATH: framing.
    count=$(print -- ":$PATH:" | grep -o ":/opt/homebrew/bin:" | wc -l | tr -d " ")
    print -- "count=$count"
    print -- "$PATH"
  '
  assert_success
  assert_line "count=1"
  assert_line "/opt/homebrew/bin:/usr/bin:/bin"
}

# --- end-to-end: login-shell PATH ordering ----------------------------------

@test "login shell: /opt/homebrew/bin lands BEFORE /usr/bin in zsh -lc PATH" {
  # The integration test for the full Phase 4 cutover + Phase 4.5 fix.
  # Starts from a path_helper-style PATH (system dirs only) and confirms
  # that after zsh -lc has fully loaded (.zshenv -> /etc/zprofile ->
  # .zprofile), /opt/homebrew/bin has been promoted in front of /usr/bin.
  #
  # Without the _path_prepend promote-to-front fix, this test fails:
  # path_helper demotes homebrew, the env-tier re-source from .zprofile
  # no-ops because "homebrew is already on PATH somewhere", and the final
  # PATH has /usr/bin BEFORE /opt/homebrew/bin.
  if [[ ! -d /opt/homebrew/bin ]]; then
    skip "/opt/homebrew/bin not present on this host"
  fi
  run env PATH="/usr/bin:/bin" zsh -lc 'print -- "$PATH"'
  assert_success
  # Both must appear.
  assert_output --partial "/opt/homebrew/bin"
  assert_output --partial "/usr/bin"
  # Position of /opt/homebrew/bin must be less than position of /usr/bin
  # in the colon-split list. Use awk for the comparison.
  brew_pos="$(awk -v p="$output" -v t="/opt/homebrew/bin" 'BEGIN {
    n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]==t){print i; exit}; print 0
  }')"
  usrbin_pos="$(awk -v p="$output" -v t="/usr/bin" 'BEGIN {
    n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]==t){print i; exit}; print 0
  }')"
  [[ "$brew_pos" -gt 0 ]] || {
    echo "/opt/homebrew/bin missing from PATH" >&3
    false
  }
  [[ "$usrbin_pos" -gt 0 ]] || {
    echo "/usr/bin missing from PATH" >&3
    false
  }
  [[ "$brew_pos" -lt "$usrbin_pos" ]] || {
    echo "expected /opt/homebrew/bin before /usr/bin, got positions $brew_pos vs $usrbin_pos in PATH=$output" >&3
    false
  }
}

@test "login shell: /opt/homebrew/bin lands BEFORE /bin in zsh -lc PATH" {
  if [[ ! -d /opt/homebrew/bin ]]; then
    skip "/opt/homebrew/bin not present on this host"
  fi
  run env PATH="/usr/bin:/bin" zsh -lc 'print -- "$PATH"'
  assert_success
  brew_pos="$(awk -v p="$output" -v t="/opt/homebrew/bin" 'BEGIN {
    n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]==t){print i; exit}; print 0
  }')"
  bin_pos="$(awk -v p="$output" -v t="/bin" 'BEGIN {
    n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]==t){print i; exit}; print 0
  }')"
  [[ "$brew_pos" -gt 0 ]] || {
    echo "/opt/homebrew/bin missing" >&3
    false
  }
  [[ "$bin_pos" -gt 0 ]] || {
    echo "/bin missing" >&3
    false
  }
  [[ "$brew_pos" -lt "$bin_pos" ]] || {
    echo "expected /opt/homebrew/bin before /bin, got $brew_pos vs $bin_pos in PATH=$output" >&3
    false
  }
}

@test "login shell: 'bash' resolves to /opt/homebrew/bin/bash (NOT /bin/bash 3.2)" {
  # The most consequential symptom of the path_helper demotion: shebang
  # resolution. `#!/usr/bin/env bash` picks the first 'bash' on PATH.
  # If /usr/bin:/bin wins, that's bash 3.2.57, which errors on idioms
  # used throughout the agent layer. We want bash 5.x from homebrew.
  if [[ ! -x /opt/homebrew/bin/bash ]]; then
    skip "/opt/homebrew/bin/bash not present on this host"
  fi
  run env PATH="/usr/bin:/bin" zsh -lc 'command -v bash'
  assert_success
  assert_output "/opt/homebrew/bin/bash"
}

@test "login shell: PATH has no duplicate of /opt/homebrew/bin" {
  if [[ ! -d /opt/homebrew/bin ]]; then
    skip "/opt/homebrew/bin not present on this host"
  fi
  run env PATH="/usr/bin:/bin" zsh -lc 'print -- "$PATH"'
  assert_success
  # NB: this assertion runs in bash (bats), so use printf, not zsh's print.
  count="$(printf '%s' ":$output:" | grep -o ":/opt/homebrew/bin:" | wc -l | tr -d ' ')"
  [[ "$count" -eq 1 ]] || {
    echo "expected exactly 1 occurrence of /opt/homebrew/bin in PATH, got $count: $output" >&3
    false
  }
}

# --- non-interactive shell parity -------------------------------------------

@test "non-interactive zsh -c: /opt/homebrew/bin still lands before /usr/bin" {
  # For completeness: the same invariant must hold for `zsh -c '...'`
  # (no -l). path_helper does NOT run for non-login shells (it's in
  # /etc/zprofile), so the env-tier's first prepend is sufficient.
  # This test confirms there's no regression in the simple case.
  if [[ ! -d /opt/homebrew/bin ]]; then
    skip "/opt/homebrew/bin not present on this host"
  fi
  run env PATH="/usr/bin:/bin" zsh -c 'print -- "$PATH"'
  assert_success
  brew_pos="$(awk -v p="$output" -v t="/opt/homebrew/bin" 'BEGIN {
    n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]==t){print i; exit}; print 0
  }')"
  usrbin_pos="$(awk -v p="$output" -v t="/usr/bin" 'BEGIN {
    n=split(p,a,":"); for(i=1;i<=n;i++) if(a[i]==t){print i; exit}; print 0
  }')"
  [[ "$brew_pos" -gt 0 && "$usrbin_pos" -gt 0 ]] || {
    echo "missing entries in PATH: $output" >&3
    false
  }
  [[ "$brew_pos" -lt "$usrbin_pos" ]] || {
    echo "expected /opt/homebrew/bin before /usr/bin in non-interactive zsh -c, got $brew_pos vs $usrbin_pos" >&3
    false
  }
}
