#!/usr/bin/env bats
# Tests for shell/env/paths.zsh — hardcoded brew prefixes + de-dup _path_prepend.
#
# These tests exist primarily to catch the class of bugs that no shellcheck/
# shfmt rule would notice: shfmt-introduced spaces inside `${assoc[key]}`
# subscripts that mangle the key, and EPOCHSECONDS/zstat dependencies
# that fail silently in non-interactive `zsh -c` invocations.
#
# All tests use `zsh --no-rcs` so the user's interactive PATH (which already
# has gnu-sed/gawk/findutils on it from a prior shell init) doesn't mask
# regressions in the env-tier PATH-building logic itself.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  # Clean baseline PATH used by every test below. Tests that need brew dirs
  # to land on PATH start from this minimal set so we observe what
  # paths.zsh _itself_ adds, not what was inherited.
  CLEAN_PATH="/usr/bin:/bin"
}

# --- _BREW_PREFIX assoc-array population ------------------------------------

@test "paths: _BREW_PREFIX defines all six tracked formulas" {
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    print -l \${(k)_BREW_PREFIX} | sort
  "
  assert_success
  # All six keys must be present, one per line. Note key naming: 'gnused'
  # (no hyphen) — see paths.zsh comment for why.
  assert_line "coreutils"
  assert_line "findutils"
  assert_line "gawk"
  assert_line "gnused"
  assert_line "grep"
  assert_line "postgresql"
}

@test "paths: every _BREW_PREFIX value is a non-empty path string" {
  # The original gnu-sed bug manifested as an empty value for the assoc
  # lookup. This test catches it generically: every value must be non-empty.
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    for k in \${(k)_BREW_PREFIX}; do
      v=\${_BREW_PREFIX[\$k]}
      [[ -z \"\$v\" ]] && { print -- \"EMPTY: \$k\"; exit 1; }
    done
    print -- ok
  "
  assert_success
  assert_output "ok"
}

@test "paths: gnu-sed gnubin is added to a clean PATH (regression: shfmt mangling)" {
  # Critical regression guard. The original bug:
  #   shfmt rewrote `${_BREW_PREFIX[gnu-sed]}` → `${_BREW_PREFIX[gnu - sed]}`
  #   and zsh evaluated the expression form, returning empty, so gnu-sed
  #   never landed on PATH. The bug was invisible in interactive shells
  #   that already had gnu-sed on inherited PATH.
  #
  # This test runs from a CLEAN PATH (no prior gnu-sed entry) and asserts
  # the env-tier code itself adds it.
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    expected=\${_BREW_PREFIX[gnused]}/libexec/gnubin
    if [[ ! -d \$expected ]]; then
      print -- 'SKIP-NO-FORMULA'
      exit 0
    fi
    case \":\$PATH:\" in
      *:\$expected:*) print -- ok ;;
      *) print -- \"MISSING: \$expected from PATH=\$PATH\"; exit 1 ;;
    esac
  "
  assert_success
  if [[ "$output" != "SKIP-NO-FORMULA" ]]; then
    assert_output "ok"
  fi
}

@test "paths: all five GNU gnubin dirs are added to a clean PATH" {
  # Stronger collective guard for the same bug class — covers any future
  # mangling of any of the five GNU formula keys (coreutils, grep, gnused,
  # gawk, findutils).
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    missing=()
    for k in coreutils grep gnused gawk findutils; do
      d=\${_BREW_PREFIX[\$k]}/libexec/gnubin
      [[ -d \$d ]] || continue   # skip if formula not installed locally
      case \":\$PATH:\" in
        *:\$d:*) ;;
        *) missing+=(\$d) ;;
      esac
    done
    if (( \${#missing} == 0 )); then
      print -- ok
    else
      print -- \"MISSING: \${missing[*]}\"
      exit 1
    fi
  "
  assert_success
  assert_output "ok"
}

# --- _path_prepend dedup behavior -------------------------------------------

@test "paths: _path_prepend de-duplicates re-prepends" {
  # Use a real tempdir so _path_prepend's "skip non-existent" guard
  # doesn't no-op every call on Ubuntu CI (where /opt/homebrew/bin
  # doesn't exist). The dedup semantics under test are dir-name-agnostic.
  tdir="$(mktemp -d)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    typeset -f _path_prepend >/dev/null || { print -- 'NO-FN'; exit 1; }
    target='$tdir'
    for i in 1 2 3 4 5; do _path_prepend \"\$target\"; done
    n=\$(print -l \${(s.:.)PATH} | grep -cE \"^\$target\$\" || true)
    print -- \"count=\$n\"
  "
  rm -rf "$tdir"
  assert_success
  assert_output --partial "count=1"
}

@test "paths: _path_prepend skips non-existent directories silently" {
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    source '$REPO/shell/init_env.zsh' >/dev/null 2>&1
    bogus='/nonexistent/path/$(date +%s)/zzz'
    _path_prepend \"\$bogus\"
    case \":\$PATH:\" in
      *:\$bogus:*) print -- 'LEAK'; exit 1 ;;
      *) print -- ok ;;
    esac
  "
  assert_success
  assert_output "ok"
}

# --- freshness nag uses zsh/datetime safely ---------------------------------

@test "paths: 14-day freshness check works in non-interactive zsh -c" {
  # Regression guard: EPOCHSECONDS requires `zmodload zsh/datetime`, which is
  # NOT auto-loaded in `zsh -c` non-interactive shells. If that's missing,
  # the arithmetic in _paths_check_freshness produces zero/garbage age values
  # that always pass the `< 14` check, so the nag never fires for stale
  # sentinels — silently breaking the 14-day backstop.
  #
  # We simulate a 100-day-old sentinel and assert the nag fires with a
  # plausible age (>= 14 days). _PATHS_NAG_FORCE=1 bypasses the
  # interactive-only gate (see paths.zsh and paths_freshness.bats setup).
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  SENTINEL="$SANDBOX/.cache/zsh/paths-refreshed"
  : >"$SENTINEL"
  # macOS BSD touch -t accepts YYYYMMDDhhmm[.SS]. Generate a 100-day-old
  # timestamp using BSD `date -v` (macOS) with a Linux fallback for CI.
  if STAMP="$(/bin/date -v-100d +%Y%m%d%H%M.%S 2>/dev/null)"; then
    touch -t "$STAMP" "$SENTINEL"
  else
    touch -d '100 days ago' "$SENTINEL"
  fi

  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    _PATHS_NAG_FORCE=1
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_output --partial "days ago"
  # Extract the day count and verify it's >= 14 (and definitely not 0/negative).
  reported="$(echo "$output" | grep -oE '[0-9]+ days ago' | head -1 | awk '{print $1}')"
  assert [ -n "$reported" ]
  assert [ "$reported" -ge 14 ]

  rm -rf "$SANDBOX"
}

@test "paths: missing sentinel triggers the 'never refreshed' nag" {
  SANDBOX="$(mktemp -d)"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    _PATHS_NAG_FORCE=1
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_output --partial "never refreshed"
  rm -rf "$SANDBOX"
}

@test "paths: fresh sentinel suppresses the nag" {
  SANDBOX="$(mktemp -d)"
  mkdir -p "$SANDBOX/.cache/zsh"
  : >"$SANDBOX/.cache/zsh/paths-refreshed"
  run zsh --no-rcs -c "
    PATH='$CLEAN_PATH'
    XDG_CACHE_HOME='$SANDBOX/.cache'
    source '$REPO/shell/init_env.zsh' 2>&1 >/dev/null
  "
  assert_success
  refute_output --partial "days ago"
  refute_output --partial "never refreshed"
  rm -rf "$SANDBOX"
}
