#!/usr/bin/env bats
# Tests for personal/bq-dadbod-url.sh.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/bq-dadbod-url.sh"

  STUB_DIR="$(mktemp -d)"
  GPM_ARGV_FILE="$STUB_DIR/gpm.argv"

  cat >"$STUB_DIR/gcp-project-map.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$GPM_ARGV_FILE"
case "\$1" in
  --bq) echo "prj-test-fake-tst" ;;
  *)    echo "stub-gpm: unhandled \$*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$STUB_DIR/gcp-project-map.sh"
  export GCP_PROJECT_MAP="$STUB_DIR/gcp-project-map.sh"
}

teardown() {
  rm -rf "$STUB_DIR"
}

gpm_argv() { cat "$GPM_ARGV_FILE" 2>/dev/null; }

# --- usage / help ------------------------------------------------------------

@test "bq-dadbod-url: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: bq-dadbod-url.sh"
  assert_output --partial "bigquery://"
}

@test "bq-dadbod-url: -h short flag works" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: bq-dadbod-url.sh"
}

# --- argument validation ----------------------------------------------------

@test "bq-dadbod-url: no args fails with 'Missing <env>'" {
  run "$SCRIPT"
  assert_failure 2
  assert_output --partial "Missing <env>"
}

@test "bq-dadbod-url: only env fails with 'Missing <dataset>'" {
  run "$SCRIPT" tst
  assert_failure 2
  assert_output --partial "Missing <dataset>"
}

@test "bq-dadbod-url: extra positional fails" {
  run "$SCRIPT" tst all_clients surprise
  assert_failure 2
  assert_output --partial "Unexpected argument: surprise"
}

@test "bq-dadbod-url: unknown flag fails" {
  run "$SCRIPT" --bogus
  assert_failure 2
  assert_output --partial "Unknown option: --bogus"
}

# --- missing dependency -----------------------------------------------------

@test "bq-dadbod-url: missing gcp-project-map.sh exits 3" {
  GCP_PROJECT_MAP="/nonexistent/gcp-project-map.sh" run "$SCRIPT" tst all_clients
  assert_failure 3
  assert_output --partial "gcp-project-map.sh not found"
}

# --- happy path -------------------------------------------------------------

@test "bq-dadbod-url: emits bigquery://<project>/<dataset>" {
  run "$SCRIPT" tst all_clients
  assert_success
  assert_output "bigquery://prj-test-fake-tst/all_clients"
  argv="$(gpm_argv)"
  [[ "$argv" == *"--bq"* ]]
  [[ "$argv" == *"tst"* ]]
}

@test "bq-dadbod-url: dataset name with underscores preserved verbatim" {
  run "$SCRIPT" prd kraken_metadata
  assert_success
  assert_output --partial "/kraken_metadata"
}

# --- resolver failure -------------------------------------------------------

@test "bq-dadbod-url: resolver failure produces clear error" {
  cat >"$STUB_DIR/gcp-project-map.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --bq) echo "Error: unknown env" >&2; exit 1 ;;
esac
EOF
  chmod +x "$STUB_DIR/gcp-project-map.sh"

  run "$SCRIPT" bogus all_clients
  assert_failure
  assert_output --partial "Failed to resolve BQ project for env 'bogus'"
}
