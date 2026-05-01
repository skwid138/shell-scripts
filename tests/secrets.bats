#!/usr/bin/env bats
# Tests for shell/lib/secrets.sh — memoized keychain loader.
#
# secrets.sh is deliberately bash-portable (a `.sh` file, not `.zsh`) so
# future MCP wrappers can `bash -c '. lib/secrets.sh; …'` without a zsh
# dependency. The file branches on $ZSH_VERSION at runtime to pick a cache
# backend (associative array under zsh; sentinel-prefixed env vars under
# bash). To prove shell-parity we run the same test program under both
# shells via the run_in helper.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  # Per-test scratch dir for the keychain_get-mock invocation counter.
  TMPDIR_TEST="$(mktemp -d)"
  export TMPDIR_TEST
  COUNTER_FILE="$TMPDIR_TEST/keychain_get.count"
  export COUNTER_FILE
  : >"$COUNTER_FILE"

  SECRETS_SH="$BATS_TEST_DIRNAME/../shell/lib/secrets.sh"
  export SECRETS_SH
}

teardown() {
  [[ -n "${TMPDIR_TEST:-}" && -d "$TMPDIR_TEST" ]] && rm -rf "$TMPDIR_TEST"
}

# run_in <shell> <inline-program>
#   Invoke an inline test program under either bash or zsh, with a mock
#   keychain_get that tallies invocations to $COUNTER_FILE. The mock is
#   defined AFTER sourcing secrets.sh so it shadows the real function that
#   secrets.sh pulls in via lib/keychain.sh.
#
#   Why a tempfile counter rather than a shell variable: every secret_get
#   call invokes keychain_get inside `$(...)`, which is a subshell. Subshell
#   variable mutations don't propagate back to the parent. A tempfile is
#   the simplest portable counter that survives the subshell boundary.
run_in() {
  local shell_bin="$1"
  shift
  local prog="$1"
  local prelude
  prelude='
    set +e
    source "$SECRETS_SH"
    keychain_get() {
      # Tally each invocation. Append a single byte; line count == call count.
      printf "x\n" >>"$COUNTER_FILE"
      case "$1" in
        miss-entry|"") return 1 ;;
        *) printf "value-for-%s\n" "$1" ;;
      esac
    }
  '
  "$shell_bin" -c "$prelude
$prog"
}

count_calls() {
  # wc -l prints leading whitespace on macOS; strip it.
  local n
  n="$(wc -l <"$COUNTER_FILE")"
  printf '%s\n' "${n// /}"
}

# ----------------------------------------------------------------------------
# Re-source guard
# ----------------------------------------------------------------------------

@test "secrets.sh: sets _LIB_SECRETS_LOADED=1 on first source (bash)" {
  run bash -c 'source "$SECRETS_SH"; echo "$_LIB_SECRETS_LOADED"'
  assert_success
  assert_output "1"
}

@test "secrets.sh: sets _LIB_SECRETS_LOADED=1 on first source (zsh)" {
  run zsh -c 'source "$SECRETS_SH"; echo "$_LIB_SECRETS_LOADED"'
  assert_success
  assert_output "1"
}

@test "secrets.sh: re-sourcing is a no-op (bash)" {
  # Mutate a sentinel; if the guard fires, the body doesnt re-run and
  # __SECRET_CACHE_SENTINEL stays as we set it.
  run bash -c '
    source "$SECRETS_SH"
    __SECRET_CACHE_SENTINEL="kept"
    source "$SECRETS_SH"
    echo "$__SECRET_CACHE_SENTINEL"
  '
  assert_success
  assert_output "kept"
}

@test "secrets.sh: re-sourcing is a no-op (zsh)" {
  run zsh -c '
    source "$SECRETS_SH"
    __SECRET_CACHE_SENTINEL="kept"
    source "$SECRETS_SH"
    echo "$__SECRET_CACHE_SENTINEL"
  '
  assert_success
  assert_output "kept"
}

# ----------------------------------------------------------------------------
# secret_get: success, cache hit, miss
# ----------------------------------------------------------------------------

@test "secret_get: returns value on hit (bash)" {
  run run_in bash 'secret_get test-entry'
  assert_success
  assert_output "value-for-test-entry"
}

@test "secret_get: returns value on hit (zsh)" {
  run run_in zsh 'secret_get test-entry'
  assert_success
  assert_output "value-for-test-entry"
}

@test "secret_get: caches after first call — second call doesnt re-query keychain (bash)" {
  # Capture via tempfile rather than `$(...)`. Command substitution runs in
  # a subshell, and the cache (an env var or assoc array in the secret_get
  # callee) lives in that subshell — it dies when the subshell exits, so
  # `$(secret_get x)` cannot demonstrate same-process memoization. Direct
  # invocation with stdout-to-file keeps everything in one process.
  out1="$TMPDIR_TEST/out1"
  out2="$TMPDIR_TEST/out2"
  run run_in bash '
    secret_get test-entry >"'"$out1"'"
    secret_get test-entry >"'"$out2"'"
  '
  assert_success
  [[ "$(cat "$out1")" == "value-for-test-entry" ]]
  [[ "$(cat "$out2")" == "value-for-test-entry" ]]
  run count_calls
  assert_output "1"
}

@test "secret_get: caches after first call — second call doesnt re-query keychain (zsh)" {
  out1="$TMPDIR_TEST/out1"
  out2="$TMPDIR_TEST/out2"
  run run_in zsh '
    secret_get test-entry >"'"$out1"'"
    secret_get test-entry >"'"$out2"'"
  '
  assert_success
  [[ "$(cat "$out1")" == "value-for-test-entry" ]]
  [[ "$(cat "$out2")" == "value-for-test-entry" ]]
  run count_calls
  assert_output "1"
}

@test "secret_get: returns 1 on missing entry (bash)" {
  run run_in bash 'secret_get miss-entry'
  assert_failure 1
}

@test "secret_get: returns 1 on missing entry (zsh)" {
  run run_in zsh 'secret_get miss-entry'
  assert_failure 1
}

@test "secret_get: misses are NOT cached — repeated misses re-query keychain (bash)" {
  # If misses were cached, the second call would short-circuit and the
  # counter would be 1. We want 2 (or more), proving the no-empty-cache
  # branch in secrets.sh.
  run run_in bash '
    secret_get miss-entry || true
    secret_get miss-entry || true
  '
  assert_success
  run count_calls
  assert_output "2"
}

@test "secret_get: misses are NOT cached — repeated misses re-query keychain (zsh)" {
  run run_in zsh '
    secret_get miss-entry || true
    secret_get miss-entry || true
  '
  assert_success
  run count_calls
  assert_output "2"
}

@test "secret_get: usage error on no args returns 2 (bash)" {
  run run_in bash 'secret_get'
  assert_failure 2
  assert_output --partial "usage:"
}

@test "secret_get: usage error on no args returns 2 (zsh)" {
  run run_in zsh 'secret_get'
  assert_failure 2
  assert_output --partial "usage:"
}

# ----------------------------------------------------------------------------
# secret_load: export + memoize + idempotent
# ----------------------------------------------------------------------------

@test "secret_load: exports the named env var (bash)" {
  run run_in bash '
    secret_load MY_TOKEN test-entry
    echo "MY_TOKEN=$MY_TOKEN"
  '
  assert_success
  assert_output "MY_TOKEN=value-for-test-entry"
}

@test "secret_load: exports the named env var (zsh)" {
  run run_in zsh '
    secret_load MY_TOKEN test-entry
    echo "MY_TOKEN=$MY_TOKEN"
  '
  assert_success
  assert_output "MY_TOKEN=value-for-test-entry"
}

@test "secret_load: idempotent — re-call with var already set is a no-op (bash)" {
  # First call hits keychain (count=1). Second call sees existing var and
  # MUST short-circuit (count stays at 1).
  run run_in bash '
    secret_load MY_TOKEN test-entry
    secret_load MY_TOKEN test-entry
    echo "MY_TOKEN=$MY_TOKEN"
  '
  assert_success
  assert_output "MY_TOKEN=value-for-test-entry"
  run count_calls
  assert_output "1"
}

@test "secret_load: idempotent — re-call with var already set is a no-op (zsh)" {
  run run_in zsh '
    secret_load MY_TOKEN test-entry
    secret_load MY_TOKEN test-entry
    echo "MY_TOKEN=$MY_TOKEN"
  '
  assert_success
  assert_output "MY_TOKEN=value-for-test-entry"
  run count_calls
  assert_output "1"
}

@test "secret_load: returns 1 and warns on miss; var stays unset (bash)" {
  run run_in bash '
    if secret_load MY_TOKEN miss-entry; then
      echo "unexpected success"; exit 1
    fi
    echo "MY_TOKEN=${MY_TOKEN:-<unset>}"
  '
  assert_success
  assert_output --partial "warn: keychain entry"
  assert_output --partial "MY_TOKEN=<unset>"
}

@test "secret_load: returns 1 and warns on miss; var stays unset (zsh)" {
  run run_in zsh '
    if secret_load MY_TOKEN miss-entry; then
      echo "unexpected success"; exit 1
    fi
    echo "MY_TOKEN=${MY_TOKEN:-<unset>}"
  '
  assert_success
  assert_output --partial "warn: keychain entry"
  assert_output --partial "MY_TOKEN=<unset>"
}

@test "secret_load: usage error on missing args returns 2 (bash)" {
  run run_in bash 'secret_load only-one-arg'
  assert_failure 2
  assert_output --partial "usage:"
}

@test "secret_load: usage error on missing args returns 2 (zsh)" {
  run run_in zsh 'secret_load only-one-arg'
  assert_failure 2
  assert_output --partial "usage:"
}

# ----------------------------------------------------------------------------
# secret_clear: drop one or all cached secrets
# ----------------------------------------------------------------------------

@test "secret_clear (no args): empties cache; next secret_get re-queries keychain (bash)" {
  run run_in bash '
    secret_get test-entry >/dev/null            # call 1: real
    secret_get test-entry >/dev/null            # call 2: cached (no keychain hit)
    secret_clear                                # drop cache
    secret_get test-entry >/dev/null            # call 3: real again
  '
  assert_success
  run count_calls
  # Expect exactly 2 keychain hits (calls 1 and 3; call 2 is cached).
  assert_output "2"
}

@test "secret_clear (no args): empties cache; next secret_get re-queries keychain (zsh)" {
  run run_in zsh '
    secret_get test-entry >/dev/null
    secret_get test-entry >/dev/null
    secret_clear
    secret_get test-entry >/dev/null
  '
  assert_success
  run count_calls
  assert_output "2"
}

@test "secret_clear <entry>: drops only that entry; other entries still cached (bash)" {
  run run_in bash '
    secret_get entry-a >/dev/null   # call 1
    secret_get entry-b >/dev/null   # call 2
    secret_clear entry-a            # drop only A
    secret_get entry-a >/dev/null   # call 3 (re-queried)
    secret_get entry-b >/dev/null   # cached, no call
  '
  assert_success
  run count_calls
  assert_output "3"
}

@test "secret_clear <entry>: drops only that entry; other entries still cached (zsh)" {
  run run_in zsh '
    secret_get entry-a >/dev/null
    secret_get entry-b >/dev/null
    secret_clear entry-a
    secret_get entry-a >/dev/null
    secret_get entry-b >/dev/null
  '
  assert_success
  run count_calls
  assert_output "3"
}

# ----------------------------------------------------------------------------
# Per-process cache scope
# ----------------------------------------------------------------------------

@test "cache is per-process — separate shell invocations don't share state (bash)" {
  # Two separate `bash -c` invocations both miss the cache => 2 keychain hits.
  run_in bash 'secret_get test-entry >/dev/null'
  run_in bash 'secret_get test-entry >/dev/null'
  run count_calls
  assert_output "2"
}

@test "cache is per-process — separate shell invocations don't share state (zsh)" {
  run_in zsh 'secret_get test-entry >/dev/null'
  run_in zsh 'secret_get test-entry >/dev/null'
  run count_calls
  assert_output "2"
}

# ----------------------------------------------------------------------------
# Sanitization: keychain entries with non-[A-Za-z0-9_] characters
# ----------------------------------------------------------------------------

@test "secret_get: handles keychain entries with hyphens and dots (bash sentinel-var path)" {
  # Bash uses sentinel env vars; entry names with hyphens/dots must be
  # sanitized to a valid identifier. Verify the cache key actually works.
  run run_in bash '
    secret_get my-fancy.entry >/dev/null
    secret_get my-fancy.entry >/dev/null
  '
  assert_success
  run count_calls
  assert_output "1"
}

@test "secret_get: handles keychain entries with hyphens and dots (zsh assoc-array path)" {
  run run_in zsh '
    secret_get my-fancy.entry >/dev/null
    secret_get my-fancy.entry >/dev/null
  '
  assert_success
  run count_calls
  assert_output "1"
}
