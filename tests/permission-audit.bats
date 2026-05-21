#!/usr/bin/env bats
# CLI / arg-parsing tests for agent/permission-audit.sh.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../agent/permission-audit.sh"
  STUBDIR="$(mktemp -d)"
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_python_arg_stub() {
  cat >"$STUBDIR/python3" <<'EOF'
#!/usr/bin/env bash
printf 'core=%s\n' "$1"
shift
printf 'args=%s\n' "$*"
EOF
  chmod +x "$STUBDIR/python3"
}

make_path_without_python3() {
  mkdir -p "$STUBDIR/minpath"
  ln -s /bin/bash "$STUBDIR/minpath/bash"
  ln -s /usr/bin/dirname "$STUBDIR/minpath/dirname"
}

@test "permission-audit: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: permission-audit"
  assert_output --partial "--action ask|deny|all"
}

@test "permission-audit: missing python3 exits 3" {
  make_path_without_python3
  run env PATH="$STUBDIR/minpath" PERMISSION_AUDIT_TODAY=2026-05-21 "$SCRIPT"
  assert_failure 3
  assert_output --partial "Missing dependency"
  assert_output --partial "python3"
}

@test "permission-audit: invalid date format exits 2" {
  run "$SCRIPT" --start 2026/05/21
  assert_failure 2
  assert_output --partial "Usage error"
  assert_output --partial "Invalid --start date"
}

@test "permission-audit: default args pass through to python core" {
  write_python_arg_stub
  run env PATH="$STUBDIR:$PATH" PERMISSION_AUDIT_TODAY=2026-05-21 "$SCRIPT"
  assert_success
  assert_output --partial "core=$BATS_TEST_DIRNAME/../agent/permission_audit_core.py"
  assert_output --partial "args=--start 2026-05-21 --end 2026-05-21 --action ask --json"
}
