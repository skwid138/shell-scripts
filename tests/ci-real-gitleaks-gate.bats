#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for .github/scripts/require-real-gitleaks-tests.sh: the CI gate that
# fails a test job unless the four real-gitleaks hook tests ran (ok, never
# "# skip") in that job's TAP output. Pure text processing; runs everywhere.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  GATE="$BATS_TEST_DIRNAME/../.github/scripts/require-real-gitleaks-tests.sh"
  HOOK_SUITE="$BATS_TEST_DIRNAME/gitleaks-hook.bats"
  T="$BATS_TEST_TMPDIR"
  N1="gitleaks-hook (real gitleaks): staged secret is blocked; worktree-only secret is allowed"
  N2="gitleaks-hook (real gitleaks): 'git commit fileA' uses a temp index, so fileB's staged secret is not scanned or committed"
  N3="gitleaks-hook (real gitleaks): 'git commit -a' with a modified tracked file containing a secret is blocked"
  N4="gitleaks-hook (real gitleaks): --no-verify bypasses even a real staged secret"
}

# tap <line...>: write a TAP file with the given result lines.
tap() {
  {
    echo "1..$#"
    printf '%s\n' "$@"
  } >"$T/out.tap"
}

@test "ci gate: the gate script exists and is executable" {
  [[ -x "$GATE" ]]
}

@test "ci gate: every required name is an exact @test name in tests/gitleaks-hook.bats" {
  run "$GATE" --list
  assert_success
  [[ "${#lines[@]}" -eq 4 ]]
  local n
  for n in "${lines[@]}"; do
    grep -qxF "@test \"$n\" {" "$HOOK_SUITE" || {
      echo "not an @test in gitleaks-hook.bats: $n" >&2
      false
    }
  done
  assert_line "$N1"
  assert_line "$N2"
  assert_line "$N3"
  assert_line "$N4"
}

@test "ci gate: all four ok (any numbering, other lines around) passes" {
  tap "ok 1 other test" "ok 428 $N1" "ok 7 $N3" "ok 429 $N2" "not ok 3 unrelated failure" "ok 9 $N4" "ok 10 x # skip y"
  run "$GATE" "$T/out.tap"
  assert_success
  assert_output --partial "4/4"
}

@test "ci gate: a skipped required test fails the job and names it" {
  tap "ok 428 $N1" "ok 429 $N2 # skip gitleaks not installed" "ok 430 $N3" "ok 431 $N4"
  run "$GATE" "$T/out.tap"
  assert_failure 1
  assert_output --partial "SKIPPED: $N2"
}

@test "ci gate: a missing required test fails the job and names it" {
  tap "ok 428 $N1" "ok 429 $N2" "ok 431 $N4"
  run "$GATE" "$T/out.tap"
  assert_failure 1
  assert_output --partial "MISSING: $N3"
}

@test "ci gate: a failed required test fails the job" {
  tap "ok 428 $N1" "ok 429 $N2" "not ok 430 $N3" "ok 431 $N4"
  run "$GATE" "$T/out.tap"
  assert_failure 1
  assert_output --partial "$N3"
}

@test "ci gate: a name that merely starts with a required name does not count" {
  tap "ok 428 $N1 (variant)" "ok 429 $N2" "ok 430 $N3" "ok 431 $N4"
  run "$GATE" "$T/out.tap"
  assert_failure 1
  assert_output --partial "MISSING: $N1"
}

@test "ci gate: an unreadable or absent TAP file is an error, never a pass" {
  run "$GATE" "$T/nope.tap"
  assert_failure
  run "$GATE"
  assert_failure
}
