#!/usr/bin/env bats
# CLI tests for personal/opencode-attach.sh
#
# Stubs `opencode`, `security` via PATH override and asserts argument shape,
# exit codes, and that the Keychain password is exported into the child env.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/opencode-attach.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  : >"$STATEFILE"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

# --- stub factories ---------------------------------------------------------

# Mirrors the `security find-generic-password` contract used in opencode-web.bats:
# returns $KEYCHAIN_VALUE if set, else fails with rc=44.
write_security_stub() {
  cat >"$STUBDIR/security" <<'EOF'
#!/usr/bin/env bash
echo "security $*" >>"$STATEFILE"
if [[ "${KEYCHAIN_VALUE+set}" != "set" ]]; then
  echo "security: SecKeychainSearchCopyNext: The specified item could not be found in the keychain." >&2
  exit 44
fi
printf '%s' "$KEYCHAIN_VALUE"
EOF
  chmod +x "$STUBDIR/security"
}

# Stub `opencode`: log args + the env vars the wrapper is expected to export,
# so tests can assert credentials propagate to the child without ever logging
# the value itself.
write_opencode_stub() {
  cat >"$STUBDIR/opencode" <<'EOF'
#!/usr/bin/env bash
echo "opencode $*" >>"$STATEFILE"
echo "env OPENCODE_SERVER_USERNAME=${OPENCODE_SERVER_USERNAME-}" >>"$STATEFILE"
echo "env OPENCODE_SERVER_PASSWORD_LEN=${#OPENCODE_SERVER_PASSWORD}" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/opencode"
}

write_all_stubs() {
  write_security_stub
  write_opencode_stub
}

# --- arg parsing tests ------------------------------------------------------

@test "opencode-attach: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
  assert_output --partial "openattach"
}

@test "opencode-attach: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "opencode-attach: unknown flag exits 2" {
  run "$SCRIPT" --bogus-flag
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "opencode-attach: rejects multiple positional URLs" {
  run "$SCRIPT" http://a:1 http://b:2
  assert_failure 2
  assert_output --partial "unexpected positional arg"
}

# --- dependency-check tests -------------------------------------------------

@test "opencode-attach: missing opencode on PATH exits 3" {
  PATH="/usr/bin:/bin" run "$SCRIPT"
  assert_failure 3
  assert_output --partial "opencode"
}

# --- keychain integration tests ---------------------------------------------

@test "opencode-attach: missing keychain entry exits 1 with hint" {
  write_all_stubs
  unset KEYCHAIN_VALUE
  run "$SCRIPT"
  assert_failure 1
  assert_output --partial "Secret not found"
  assert_output --partial "opencode-server-password"
}

@test "opencode-attach: happy path execs opencode attach with default URL" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}

@test "opencode-attach: explicit URL positional is honored" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" "http://10.0.0.5:4096"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://10.0.0.5:4096"
}

@test "opencode-attach: passthrough args after -- are forwarded" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" -- --continue
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096 --dir"
  assert_output --partial "--continue"
}

@test "opencode-attach: URL + passthrough args coexist" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT" "http://h:9" -- --session abc
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://h:9 --dir"
  assert_output --partial "--session abc"
}

# --- --dir injection regression tests ---------------------------------------
#
# `opencode attach` without --dir falls back to the SERVER's process.cwd()
# (the dir openweb was launched from), so every attached session lands in
# the same project regardless of where the alias was invoked. These tests
# pin the wrapper's behavior of injecting `--dir "$PWD"` by default and
# yielding to an explicit caller-supplied --dir.
# Refs: https://github.com/anomalyco/opencode/issues/14460

@test "opencode-attach: injects --dir \$PWD by default" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096 --dir $STUBDIR"
}

@test "opencode-attach: --dir reflects current working directory at invocation" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  local subdir="$STUBDIR/nested/project"
  mkdir -p "$subdir"
  cd "$subdir"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--dir $subdir"
}

@test "opencode-attach: caller-supplied --dir overrides default injection" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" -- --dir /override/path
  assert_success
  run cat "$STATEFILE"
  # The forwarded args should contain the caller's --dir exactly once,
  # and must not contain the default $PWD injection.
  assert_output --partial "--dir /override/path"
  refute_output --partial "--dir $STUBDIR"
}

@test "opencode-attach: caller-supplied --dir=value form also overrides default" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" -- --dir=/override/path
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--dir=/override/path"
  refute_output --partial "--dir $STUBDIR"
}

@test "opencode-attach: --dir injected alongside other passthrough args" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  cd "$STUBDIR"
  run "$SCRIPT" -- --continue
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "--dir $STUBDIR"
  assert_output --partial "--continue"
}

@test "opencode-attach: exports OPENCODE_SERVER_PASSWORD for the child process" {
  write_all_stubs
  export KEYCHAIN_VALUE="0123456789"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_PASSWORD_LEN=10"
}

@test "opencode-attach: exports default OPENCODE_SERVER_USERNAME=opencode" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_USERNAME=opencode"
}

@test "opencode-attach: respects OPENCODE_SERVER_USERNAME override" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_SERVER_USERNAME="hunter"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "env OPENCODE_SERVER_USERNAME=hunter"
}

@test "opencode-attach: OPENCODE_WEB_PORT/HOSTNAME override default URL" {
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  export OPENCODE_WEB_PORT="5555"
  export OPENCODE_WEB_HOSTNAME="0.0.0.0"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://0.0.0.0:5555"
}

@test "opencode-attach: never prints the password to stdout/stderr" {
  write_all_stubs
  export KEYCHAIN_VALUE="THIS_PASSWORD_MUST_NEVER_LEAK"
  run "$SCRIPT"
  assert_success
  refute_output --partial "THIS_PASSWORD_MUST_NEVER_LEAK"
}

# --- bash 3.2 portability regression ---------------------------------------
#
# macOS still ships /bin/bash at version 3.2, and so does GitHub's
# `macos-latest` runner under `#!/usr/bin/env bash`. Under `set -u`, bash 3.2
# raises "unbound variable" for "${arr[@]}" when arr is an empty array — a
# trap newer bash (≥4.4) silently tolerates. This test pins the happy path
# to /bin/bash so any regression of that idiom in the script is caught
# locally, not on CI.

@test "opencode-attach: happy path is bash 3.2 safe (empty PASSTHROUGH array)" {
  [[ -x /bin/bash ]] || skip "no /bin/bash on host"
  write_all_stubs
  export KEYCHAIN_VALUE="x"
  # Invoke the script via /bin/bash explicitly to bypass the env(1) PATH
  # lookup that would otherwise pick up /opt/homebrew/bin/bash.
  run /bin/bash "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "opencode attach http://127.0.0.1:4096"
}
