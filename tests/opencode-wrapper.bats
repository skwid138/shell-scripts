#!/usr/bin/env bats
# CLI tests for personal/opencode-wrapper.sh
#
# Strategy: stub `opencode` (the real one) via PATH override. The wrapper
# walks PATH itself (skipping its own realpath) so we can place a stub at
# any directory ahead of /opt/homebrew/bin and assert that the wrapper
# delegates to it with the right argv + env.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/opencode-wrapper.sh"

  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  : >"$STATEFILE"
  # PATH must contain ONLY the stub dir + system minimums so the wrapper
  # finds our fake opencode and not /opt/homebrew/bin/opencode.
  export PATH="$STUBDIR:/usr/bin:/bin"
  export STATEFILE
  # Force HOME to a sandbox so we can simulate $HOME/code/wpromote/* and
  # $HOME/.config/opencode/instruction/wpromote-context.md without
  # touching the real ones.
  HOMESANDBOX="$(mktemp -d)"
  export HOME="$HOMESANDBOX"
  mkdir -p "$HOME/.config/opencode/instruction"
  # Default: instruction file present so the warn-branch isn't hit
  # unless a test explicitly removes it.
  echo "stub wpromote context" >"$HOME/.config/opencode/instruction/wpromote-context.md"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
  [[ -d "$HOMESANDBOX" ]] && rm -rf "$HOMESANDBOX"
}

# --- stub factories ---------------------------------------------------------

# Stub `opencode`: log argv + the env vars the wrapper might inject.
write_opencode_stub() {
  cat >"$STUBDIR/opencode" <<'EOF'
#!/usr/bin/env bash
echo "argv $*" >>"$STATEFILE"
echo "env OPENCODE_CONFIG_CONTENT=${OPENCODE_CONFIG_CONTENT-}" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR/opencode"
}

# --- help / arg parsing -----------------------------------------------------

@test "wrapper: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: opencode-wrapper.sh"
  assert_output --partial "OPENCODE_CONFIG_CONTENT"
}

@test "wrapper: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "wrapper: --help does NOT delegate to real opencode" {
  # If the wrapper ever passed --help through, our stub would record it.
  write_opencode_stub
  run "$SCRIPT" --help
  assert_success
  run cat "$STATEFILE"
  refute_output --partial "argv --help"
}

# --- missing real opencode --------------------------------------------------

@test "wrapper: missing real opencode on PATH exits 3" {
  # No stub written; PATH has no opencode.
  run "$SCRIPT"
  assert_failure 3
  assert_output --partial "real 'opencode' binary not found"
}

# --- happy path: outside wpromote -------------------------------------------

@test "wrapper: outside wpromote — execs real opencode without injection" {
  write_opencode_stub
  cd "$HOME"
  run "$SCRIPT" run --some-flag
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv run --some-flag"
  assert_output --partial "env OPENCODE_CONFIG_CONTENT="
  refute_output --partial "wpromote-context.md"
}

# --- happy path: under wpromote ---------------------------------------------

@test "wrapper: under wpromote — injects OPENCODE_CONFIG_CONTENT" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run "$SCRIPT" run
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv run"
  assert_output --partial "wpromote-context.md"
}

@test "wrapper: under wpromote subdir — still injects" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-api/src/deep/nest"
  cd "$HOME/code/wpromote/polaris-api/src/deep/nest"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "wpromote-context.md"
}

@test "wrapper: $HOME/code/wpromote itself counts as 'under wpromote'" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote"
  cd "$HOME/code/wpromote"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "wpromote-context.md"
}

@test "wrapper: prefix collision — wpromotex/ does NOT match wpromote/" {
  # Trailing-slash compare guard: $HOME/code/wpromotex/ must not be
  # treated as under $HOME/code/wpromote/.
  write_opencode_stub
  mkdir -p "$HOME/code/wpromotex/inner"
  cd "$HOME/code/wpromotex/inner"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  refute_output --partial "wpromote-context.md"
}

# --- escape hatch: --no-conditional -----------------------------------------

@test "wrapper: --no-conditional skips injection even under wpromote" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run "$SCRIPT" --no-conditional run
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv run"
  refute_output --partial "wpromote-context.md"
}

# --- carve-outs: web / attach pass through unmodified -----------------------

@test "wrapper: 'web' subcommand passes through, no injection (under wpromote)" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run "$SCRIPT" web --port 4096
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv web --port 4096"
  refute_output --partial "wpromote-context.md"
}

@test "wrapper: 'attach' subcommand passes through, no injection (under wpromote)" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run "$SCRIPT" attach http://127.0.0.1:4096
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv attach http://127.0.0.1:4096"
  refute_output --partial "wpromote-context.md"
}

# --- drift detection: missing instruction file ------------------------------

@test "wrapper: warns (does not fail) when wpromote-context.md missing" {
  write_opencode_stub
  rm "$HOME/.config/opencode/instruction/wpromote-context.md"
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run "$SCRIPT"
  assert_success
  assert_output --partial "wpromote instruction file missing"
  assert_output --partial "install-wrapper.sh --check"
  run cat "$STATEFILE"
  # Real opencode still ran, just without the conditional injection.
  assert_output --partial "env OPENCODE_CONFIG_CONTENT="
  refute_output --partial "wpromote-context.md\""
}

# --- verbose mode -----------------------------------------------------------

@test "wrapper: OPENCODE_WRAPPER_VERBOSE=1 prints injection notice" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  OPENCODE_WRAPPER_VERBOSE=1 run "$SCRIPT"
  assert_success
  assert_output --partial "wpromote conditional context loaded"
}

@test "wrapper: verbose default is off — no injection notice" {
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run "$SCRIPT"
  assert_success
  refute_output --partial "wpromote conditional context loaded"
}

# --- recursion safety -------------------------------------------------------

@test "wrapper: skips itself when a copy of itself appears earlier on PATH" {
  # Place a hard copy of the wrapper in STUBDIR (so canonicalize() sees
  # it as a different inode/path than the source). Then place the real
  # opencode stub in a SECOND dir later on PATH. The wrapper should walk
  # past its own copy and find the stub.
  cp "$SCRIPT" "$STUBDIR/opencode"
  chmod +x "$STUBDIR/opencode"
  STUBDIR2="$(mktemp -d)"
  cat >"$STUBDIR2/opencode" <<'EOF'
#!/usr/bin/env bash
echo "argv $*" >>"$STATEFILE"
exit 0
EOF
  chmod +x "$STUBDIR2/opencode"
  export PATH="$STUBDIR:$STUBDIR2:/usr/bin:/bin"

  cd "$HOME"
  run "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv"
  rm -rf "$STUBDIR2"
}

# --- bash 3.2 portability ---------------------------------------------------
#
# /bin/bash on macOS is bash 3.2; this is the runtime the wrapper might end
# up under in non-interactive contexts. Pin the happy paths to /bin/bash so
# any regression to bash-4-only idioms is caught locally.

@test "wrapper: happy path is bash 3.2 safe (no wpromote)" {
  [[ -x /bin/bash ]] || skip "no /bin/bash on host"
  write_opencode_stub
  cd "$HOME"
  run /bin/bash "$SCRIPT" run
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "argv run"
}

@test "wrapper: happy path is bash 3.2 safe (under wpromote)" {
  [[ -x /bin/bash ]] || skip "no /bin/bash on host"
  write_opencode_stub
  mkdir -p "$HOME/code/wpromote/polaris-web"
  cd "$HOME/code/wpromote/polaris-web"
  run /bin/bash "$SCRIPT"
  assert_success
  run cat "$STATEFILE"
  assert_output --partial "wpromote-context.md"
}

# --- symlink invocation: regression test for common.sh resolution -----------
#
# When the wrapper is invoked through the install symlink (the documented
# happy path), bash sets BASH_SOURCE[0] to the symlink path, not the
# resolved target. A previous version sourced common.sh via a relative
# path and broke under symlink invocation, printing
# "No such file or directory" to stderr while exit code stayed 0.

@test "wrapper: invoked through symlink, no stderr noise (common.sh resolves)" {
  write_opencode_stub
  # Build a symlink that mirrors the real install layout.
  mkdir -p "$HOME/.config/opencode/bin"
  ln -s "$SCRIPT" "$HOME/.config/opencode/bin/opencode"
  cd "$HOME"
  # Capture stderr separately so we can assert it is silent.
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  "$HOME/.config/opencode/bin/opencode" --no-conditional run 2>"$STDERR_FILE"
  status=$?
  [ "$status" -eq 0 ]
  run cat "$STDERR_FILE"
  refute_output --partial "No such file or directory"
  refute_output --partial "common.sh"
}

@test "wrapper: invoked through symlink with verbose, OPENCODE_COMMON_LIB missing — falls back to stubs" {
  write_opencode_stub
  mkdir -p "$HOME/.config/opencode/bin"
  ln -s "$SCRIPT" "$HOME/.config/opencode/bin/opencode"
  mkdir -p "$HOME/code/wpromote/x"
  cd "$HOME/code/wpromote/x"
  # Point common.sh at a path that does not exist; stubs must take over.
  STDERR_FILE="$BATS_TEST_TMPDIR/stderr"
  OPENCODE_COMMON_LIB="$BATS_TEST_TMPDIR/no-such-common.sh" \
    OPENCODE_WRAPPER_VERBOSE=1 \
    "$HOME/.config/opencode/bin/opencode" 2>"$STDERR_FILE"
  status=$?
  [ "$status" -eq 0 ]
  run cat "$STDERR_FILE"
  refute_output --partial "No such file or directory"
  # Stub info() should still emit the verbose injection notice.
  assert_output --partial "wpromote conditional context loaded"
}

@test "wrapper: invoked through symlink, OPENCODE_COMMON_LIB override is honored" {
  write_opencode_stub
  mkdir -p "$HOME/.config/opencode/bin"
  ln -s "$SCRIPT" "$HOME/.config/opencode/bin/opencode"
  # Custom common.sh that defines info as a marker.
  CUSTOM_COMMON="$BATS_TEST_TMPDIR/custom-common.sh"
  cat >"$CUSTOM_COMMON" <<'EOF'
info() { printf '[CUSTOM-INFO] %s\n' "$*" >&2; }
warn() { printf '[CUSTOM-WARN] %s\n' "$*" >&2; }
die_missing_dep() {
  printf '[CUSTOM-DEP] %s\n' "$*" >&2
  exit 3
}
EOF
  mkdir -p "$HOME/code/wpromote/x"
  cd "$HOME/code/wpromote/x"
  OPENCODE_COMMON_LIB="$CUSTOM_COMMON" \
    OPENCODE_WRAPPER_VERBOSE=1 \
    run "$HOME/.config/opencode/bin/opencode"
  assert_success
  assert_output --partial "[CUSTOM-INFO]"
}
