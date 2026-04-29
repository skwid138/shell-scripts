#!/usr/bin/env bats
# Tests for agent/scripts-doctor.sh.
#
# Strategy: build small synthetic repo trees in temp dirs to exercise pass
# and fail conditions deterministically. Real repos vary too much for
# reliable assertions; the doctor itself runs against real repos in
# integration usage.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../agent/scripts-doctor.sh"

  # Each test gets its own scratch repo tree.
  REPO="$(mktemp -d)"
  mkdir -p "$REPO/agent" "$REPO/tests" "$REPO/.github/workflows"
}

teardown() {
  rm -rf "$REPO"
}

# Helper: write a minimal valid agent script (passes all checks).
write_valid_script() {
  local name="$1"
  cat >"$REPO/agent/$name" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
case "${1:-}" in
  -h|--help) echo "Usage: ..."; exit 0 ;;
esac
EOF
  chmod +x "$REPO/agent/$name"
  # Companion test file
  touch "$REPO/tests/${name%.sh}.bats"
}

# Helper: write a minimal CI workflow.
write_valid_ci() {
  cat >"$REPO/.github/workflows/ci.yml" <<'EOF'
name: ci
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
EOF
}

# --- usage / help ------------------------------------------------------------

@test "scripts-doctor: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: scripts-doctor"
  assert_output --partial "--json"
}

@test "scripts-doctor: -h short flag works" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: scripts-doctor"
}

# --- argument validation -----------------------------------------------------

@test "scripts-doctor: unknown flag fails with exit 2" {
  run "$SCRIPT" --bogus
  assert_failure
  [[ "$status" -eq 2 ]]
  assert_output --partial "unknown flag: --bogus"
}

@test "scripts-doctor: --repo with non-existent path warns but does not crash" {
  # Non-existent paths are tolerated: the doctor records a warning
  # ("no agent/ dir; skipping per-script checks") and continues. This
  # is intentional — the tool should be safe to point at half-set-up
  # repos without abending.
  run "$SCRIPT" --repo /nonexistent/dir
  assert_success
  assert_output --partial "/nonexistent/dir"
  assert_output --partial "no agent/ dir"
}

# --- happy path: everything passes ------------------------------------------

@test "scripts-doctor: clean synthetic repo passes all checks" {
  write_valid_ci
  write_valid_script "good.sh"

  run "$SCRIPT" --repo "$REPO"
  assert_success
  assert_output --partial "good.sh: --help exits 0"
  assert_output --partial "good.sh: strict mode"
  assert_output --partial "good.sh: has bats suite"
  assert_output --partial "result: OK"
}

# --- failure: 'set -e' detection --------------------------------------------

@test "scripts-doctor: detects 'set -euo pipefail' as a failure" {
  write_valid_ci
  cat >"$REPO/agent/badset.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
case "${1:-}" in
  -h|--help) echo "Usage: ..."; exit 0 ;;
esac
EOF
  chmod +x "$REPO/agent/badset.sh"
  touch "$REPO/tests/badset.bats"

  run "$SCRIPT" --repo "$REPO"
  assert_failure
  assert_output --partial "badset.sh: no 'set -e'"
  assert_output --partial "CONVENTIONS forbids"
  assert_output --partial "result: FAIL"
}

@test "scripts-doctor: detects conditionally-applied 'set -e'" {
  # Some scripts only apply set -e when invoked directly, not when sourced.
  # The doctor must catch this too — search isn't anchored to BOL.
  write_valid_ci
  cat >"$REPO/agent/condset.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi
source "$(dirname "$0")/../lib/common.sh"
case "${1:-}" in
  -h|--help) echo "Usage: ..."; exit 0 ;;
esac
EOF
  chmod +x "$REPO/agent/condset.sh"
  touch "$REPO/tests/condset.bats"

  run "$SCRIPT" --repo "$REPO"
  assert_failure
  assert_output --partial "condset.sh: no 'set -e'"
}

# --- failure: missing test file ---------------------------------------------

@test "scripts-doctor: flags missing bats suite as failure" {
  write_valid_ci
  cat >"$REPO/agent/notest.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
case "${1:-}" in
  -h|--help) echo "Usage: ..."; exit 0 ;;
esac
EOF
  chmod +x "$REPO/agent/notest.sh"
  # No companion test file written.

  run "$SCRIPT" --repo "$REPO"
  assert_failure
  assert_output --partial "notest.sh: has bats suite"
  assert_output --partial "expected"
}

# --- failure: --help broken --------------------------------------------------

@test "scripts-doctor: flags scripts whose --help fails" {
  write_valid_ci
  cat >"$REPO/agent/nohelp.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "I crash on --help" >&2
exit 99
EOF
  chmod +x "$REPO/agent/nohelp.sh"
  touch "$REPO/tests/nohelp.bats"

  run "$SCRIPT" --repo "$REPO"
  assert_failure
  assert_output --partial "nohelp.sh: --help exits 0"
}

# --- CI workflow checks ------------------------------------------------------

@test "scripts-doctor: missing CI workflow is a failure" {
  write_valid_script "good.sh"
  # No .github/workflows/ci.yml

  run "$SCRIPT" --repo "$REPO"
  assert_failure
  assert_output --partial "CI workflow exists"
}

@test "scripts-doctor: CI without actions/checkout pin is a failure" {
  cat >"$REPO/.github/workflows/ci.yml" <<'EOF'
name: ci
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: echo no checkout
EOF
  write_valid_script "good.sh"

  run "$SCRIPT" --repo "$REPO"
  assert_failure
  assert_output --partial "CI pins actions/checkout"
}

# --- sources-lib check -------------------------------------------------------

@test "scripts-doctor: passes when script sources lib/detect.sh (transitive)" {
  # detect.sh sources common.sh transitively, so this counts as 'has access
  # to die_* helpers'. The doctor accepts both as evidence of compliance.
  write_valid_ci
  cat >"$REPO/agent/viadetect.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/detect.sh"
case "${1:-}" in
  -h|--help) echo "Usage: ..."; exit 0 ;;
esac
EOF
  chmod +x "$REPO/agent/viadetect.sh"
  touch "$REPO/tests/viadetect.bats"

  run "$SCRIPT" --repo "$REPO"
  assert_success
  assert_output --partial "viadetect.sh: sources lib (common/detect)"
  refute_output --partial "viadetect.sh: sources lib (common/detect)              warn"
}

# --- JSON mode ---------------------------------------------------------------

@test "scripts-doctor: --json emits valid JSON with version, ok, summary, checks" {
  write_valid_ci
  write_valid_script "good.sh"

  run "$SCRIPT" --repo "$REPO" --json
  assert_success
  # Output is JSON; parse it.
  json="$output"
  [[ "$(jq -r .version <<<"$json")" == "1" ]]
  [[ "$(jq -r .ok <<<"$json")" == "true" ]]
  [[ "$(jq -r '.summary | type' <<<"$json")" == "object" ]]
  [[ "$(jq -r '.checks | type' <<<"$json")" == "array" ]]
  # Summary must have pass/fail/warn keys.
  [[ "$(jq -r '.summary | has("pass") and has("fail") and has("warn")' <<<"$json")" == "true" ]]
  # Sample a check object's shape.
  [[ "$(jq -r '.checks[0] | has("repo") and has("name") and has("status") and has("detail")' <<<"$json")" == "true" ]]
}

@test "scripts-doctor: --json sets ok=false and exit=1 on failure" {
  write_valid_ci
  cat >"$REPO/agent/bad.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -h|--help) echo "Usage: ..."; exit 0 ;;
esac
EOF
  chmod +x "$REPO/agent/bad.sh"
  touch "$REPO/tests/bad.bats"

  run "$SCRIPT" --repo "$REPO" --json
  assert_failure
  json="$output"
  [[ "$(jq -r .ok <<<"$json")" == "false" ]]
  [[ "$(jq -r '.summary.fail >= 1' <<<"$json")" == "true" ]]
}

# --- multi-repo --------------------------------------------------------------

@test "scripts-doctor: multiple --repo flags audit each repo independently" {
  REPO2="$(mktemp -d)"
  mkdir -p "$REPO2/agent" "$REPO2/tests" "$REPO2/.github/workflows"
  REPO_BACKUP="$REPO"
  REPO="$REPO2" write_valid_ci   # use REPO2 for second one
  cat >"$REPO2/.github/workflows/ci.yml" <<'EOF'
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
EOF
  cat >"$REPO2/agent/two.sh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
case "${1:-}" in -h|--help) echo "u"; exit 0;; esac
EOF
  chmod +x "$REPO2/agent/two.sh"
  touch "$REPO2/tests/two.bats"

  REPO="$REPO_BACKUP"
  write_valid_ci
  write_valid_script "one.sh"

  run "$SCRIPT" --repo "$REPO" --repo "$REPO2"
  assert_success
  assert_output --partial "one.sh"
  assert_output --partial "two.sh"

  rm -rf "$REPO2"
}
