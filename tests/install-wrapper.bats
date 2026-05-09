#!/usr/bin/env bats
# CLI tests for ~/.config/opencode/bin/install-wrapper.sh
#
# Strategy: override OPENCODE_WRAPPER_LINK and OPENCODE_WRAPPER_TARGET via
# env vars (the script honors them as test seams) so we can exercise
# install / repair / check logic against a sandbox without touching the
# real ~/.config/opencode/bin/ symlink.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$HOME/.config/opencode/bin/install-wrapper.sh"
  [[ -x "$SCRIPT" ]] || skip "install-wrapper.sh not present at $SCRIPT"

  SANDBOX="$(mktemp -d)"
  export OPENCODE_WRAPPER_LINK="$SANDBOX/bin/opencode"
  export OPENCODE_WRAPPER_TARGET="$SANDBOX/source/opencode-wrapper.sh"
}

teardown() {
  # SANDBOX may be unset if setup() called `skip` before mktemp; guard so
  # teardown stays exit-0 in that case (bats fails the test if teardown
  # returns nonzero, which would mask a legitimate skip).
  [[ -n "${SANDBOX:-}" && -d "$SANDBOX" ]] && rm -rf "$SANDBOX"
  return 0
}

write_target() {
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_TARGET")"
  cat >"$OPENCODE_WRAPPER_TARGET" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$OPENCODE_WRAPPER_TARGET"
}

# --- help / arg parsing -----------------------------------------------------

@test "install-wrapper: --help exits 0 and prints Usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: install-wrapper.sh"
  assert_output --partial "--check"
}

@test "install-wrapper: -h exits 0 and prints Usage" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage:"
}

@test "install-wrapper: unknown flag exits 2" {
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "unknown flag"
}

@test "install-wrapper: unexpected positional exits 2" {
  run "$SCRIPT" stray-arg
  assert_failure 2
  assert_output --partial "unexpected argument"
}

# --- install mode happy path ------------------------------------------------

@test "install-wrapper: creates symlink when none exists" {
  write_target
  run "$SCRIPT"
  assert_success
  [[ -L "$OPENCODE_WRAPPER_LINK" ]]
  [[ "$(readlink "$OPENCODE_WRAPPER_LINK")" == "$OPENCODE_WRAPPER_TARGET" ]]
  assert_output --partial "wrapper symlink installed"
}

@test "install-wrapper: creates parent bin/ dir if missing" {
  write_target
  [[ ! -d "$(dirname "$OPENCODE_WRAPPER_LINK")" ]]
  run "$SCRIPT"
  assert_success
  [[ -d "$(dirname "$OPENCODE_WRAPPER_LINK")" ]]
}

@test "install-wrapper: idempotent — re-running on healthy state is fine" {
  write_target
  "$SCRIPT" >/dev/null 2>&1
  run "$SCRIPT"
  assert_success
  [[ "$(readlink "$OPENCODE_WRAPPER_LINK")" == "$OPENCODE_WRAPPER_TARGET" ]]
}

@test "install-wrapper: repairs a drifted symlink" {
  write_target
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  ln -s "/some/wrong/place" "$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT"
  assert_success
  [[ "$(readlink "$OPENCODE_WRAPPER_LINK")" == "$OPENCODE_WRAPPER_TARGET" ]]
}

@test "install-wrapper: repairs a dangling symlink" {
  write_target
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  ln -s "/nonexistent/path" "$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT"
  assert_success
  [[ "$(readlink "$OPENCODE_WRAPPER_LINK")" == "$OPENCODE_WRAPPER_TARGET" ]]
}

# --- install mode refusal cases ---------------------------------------------

@test "install-wrapper: refuses to overwrite a regular file without --force" {
  write_target
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  echo "hand-crafted shim" >"$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT"
  assert_failure 1
  assert_output --partial "exists as a regular file"
  assert_output --partial "--force"
  # File preserved.
  [[ -f "$OPENCODE_WRAPPER_LINK" ]]
  [[ ! -L "$OPENCODE_WRAPPER_LINK" ]]
}

@test "install-wrapper: --force overwrites a regular file" {
  write_target
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  echo "hand-crafted shim" >"$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT" --force
  assert_success
  [[ -L "$OPENCODE_WRAPPER_LINK" ]]
  [[ "$(readlink "$OPENCODE_WRAPPER_LINK")" == "$OPENCODE_WRAPPER_TARGET" ]]
}

@test "install-wrapper: refuses to overwrite a directory even with --force" {
  write_target
  mkdir -p "$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT" --force
  assert_failure 1
  assert_output --partial "is a directory"
  [[ -d "$OPENCODE_WRAPPER_LINK" ]]
}

@test "install-wrapper: refuses when target script is missing (exit 3)" {
  # No write_target call.
  run "$SCRIPT"
  assert_failure 3
  assert_output --partial "source-of-truth wrapper not found"
}

# --- check mode -------------------------------------------------------------

@test "install-wrapper: --check on healthy state exits 0" {
  write_target
  "$SCRIPT" >/dev/null 2>&1
  run "$SCRIPT" --check
  assert_success
  assert_output --partial "healthy"
}

@test "install-wrapper: --check on missing symlink exits 1" {
  write_target
  run "$SCRIPT" --check
  assert_failure 1
  assert_output --partial "missing"
}

@test "install-wrapper: --check on regular-file drift exits 1" {
  write_target
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  echo "shim" >"$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT" --check
  assert_failure 1
  assert_output --partial "regular file"
}

@test "install-wrapper: --check on drifted symlink exits 1" {
  write_target
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  ln -s "/some/wrong/place" "$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT" --check
  assert_failure 1
  assert_output --partial "drift"
}

@test "install-wrapper: --check on dangling symlink (target missing) exits 1" {
  # Symlink points at OPENCODE_WRAPPER_TARGET, but the target file doesn't
  # exist on disk.
  mkdir -p "$(dirname "$OPENCODE_WRAPPER_LINK")"
  ln -s "$OPENCODE_WRAPPER_TARGET" "$OPENCODE_WRAPPER_LINK"
  run "$SCRIPT" --check
  assert_failure 1
  assert_output --partial "target missing"
}

# --- bash 3.2 portability ---------------------------------------------------

@test "install-wrapper: install path is bash 3.2 safe" {
  [[ -x /bin/bash ]] || skip "no /bin/bash on host"
  write_target
  run /bin/bash "$SCRIPT"
  assert_success
  [[ -L "$OPENCODE_WRAPPER_LINK" ]]
}

@test "install-wrapper: --check path is bash 3.2 safe" {
  [[ -x /bin/bash ]] || skip "no /bin/bash on host"
  write_target
  /bin/bash "$SCRIPT" >/dev/null 2>&1
  run /bin/bash "$SCRIPT" --check
  assert_success
}
