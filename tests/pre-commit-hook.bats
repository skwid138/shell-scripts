#!/usr/bin/env bats
# Tests for .githooks/pre-commit.
#
# Strategy: build a synthetic temp git repo, stage files matching each
# scenario (clean shell file, dirty shell file, no shell files, etc.),
# and assert the hook's exit code + output.
#
# These are integration tests — they exercise real git, real shellcheck,
# and real shfmt. They skip cleanly when those tools aren't available
# (so contributors without the full toolchain can still run the suite).

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  HOOK="$BATS_TEST_DIRNAME/../.githooks/pre-commit"

  # Per-test scratch git repo.
  REPO="$(mktemp -d)"
  (
    cd "$REPO"
    git init -q
    git config user.email "test@example.com"
    git config user.name "test"
  )
}

teardown() {
  rm -rf "$REPO"
}

# --- existence + executability ----------------------------------------------

@test "pre-commit: hook file exists and is executable" {
  [[ -x "$HOOK" ]]
}

@test "pre-commit: --help-style invocation isn't supported but hook runs cleanly outside a repo only when files staged" {
  # Outside a git repo, the hook should fail clearly.
  cd /tmp
  run "$HOOK"
  assert_failure
  assert_output --partial "not inside a git repo"
}

# --- no-op path: nothing shell-y staged -------------------------------------

@test "pre-commit: no staged files -> exits 0 silently" {
  cd "$REPO"
  run "$HOOK"
  assert_success
  # Should produce no output on the no-op path (don't spam non-shell commits).
  [[ -z "$output" ]]
}

@test "pre-commit: only non-shell files staged -> exits 0 silently" {
  cd "$REPO"
  echo "# readme" >README.md
  echo '{"a":1}' >data.json
  git add README.md data.json
  run "$HOOK"
  assert_success
  [[ -z "$output" ]]
}

# --- happy path: clean shell file -------------------------------------------

@test "pre-commit: clean shell file passes all checks" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"

  cd "$REPO"
  cat >ok.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "hello"
EOF
  chmod +x ok.sh
  git add ok.sh
  run "$HOOK"
  assert_success
  assert_output --partial "checking 1 staged shell file"
  assert_output --partial "shellcheck"
  assert_output --partial "shfmt"
  assert_output --partial "all checks passed"
}

# --- failure: shellcheck errors --------------------------------------------

@test "pre-commit: shellcheck errors block the commit" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"

  cd "$REPO"
  # SC1009: missing 'fi' is an ERROR-level finding (not just warning),
  # so it trips the strict gate.
  cat >bad.sh <<'EOF'
#!/usr/bin/env bash
if [ 1 -eq 1 ]
then echo bad
EOF
  chmod +x bad.sh
  git add bad.sh
  run "$HOOK"
  assert_failure
  assert_output --partial "shellcheck reported errors"
}

# --- failure: shfmt drift ---------------------------------------------------

@test "pre-commit: shfmt drift blocks the commit" {
  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"

  cd "$REPO"
  # 4-space indent is the most reliable way to trip shfmt -i 2 drift.
  cat >drift.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
if true; then
    echo "four-space indent"
fi
EOF
  chmod +x drift.sh
  git add drift.sh
  run "$HOOK"
  assert_failure
  assert_output --partial "shfmt drift"
  assert_output --partial "Run 'make fmt'"
}

# --- shebang sniff: extension-less script ----------------------------------

@test "pre-commit: extension-less script with bash shebang is checked" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"

  cd "$REPO"
  cat >toolname <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "tool"
EOF
  chmod +x toolname
  git add toolname
  run "$HOOK"
  assert_success
  # The hook should have picked up the shebang-only file as staged.
  assert_output --partial "checking 1 staged shell file"
}

@test "pre-commit: extension-less file WITHOUT shell shebang is ignored" {
  cd "$REPO"
  echo "plain text content" >notes
  git add notes
  run "$HOOK"
  assert_success
  [[ -z "$output" ]]
}

# --- multiple files: count is correct ---------------------------------------

@test "pre-commit: reports correct count when multiple shell files staged" {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck not installed"
  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"

  cd "$REPO"
  for n in a b c; do
    cat >"$n.sh" <<EOF
#!/usr/bin/env bash
set -uo pipefail
echo "$n"
EOF
    chmod +x "$n.sh"
  done
  git add a.sh b.sh c.sh
  run "$HOOK"
  assert_success
  assert_output --partial "checking 3 staged shell file"
}

# --- bash 3.2 portability: hook itself runs under bash 3.2 ------------------

@test "pre-commit: hook itself runs under /bin/bash 3.2 (no bash-4 features)" {
  bash_3="/bin/bash"
  if [[ ! -x "$bash_3" ]] || ! "$bash_3" -c '[[ "${BASH_VERSINFO[0]}" -lt 4 ]]' 2>/dev/null; then
    skip "bash 3.2 not available at /bin/bash on this host"
  fi
  cd "$REPO"
  # No staged files: should exit 0 silently. Run via bash 3.2 explicitly
  # to catch any mapfile/${var^^}/declare -A regressions.
  run "$bash_3" "$HOOK"
  assert_success
}
