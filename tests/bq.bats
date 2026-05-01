#!/usr/bin/env bats
# Tests for personal/bq.sh.
#
# Strategy:
#   - bq.sh shells out to gcp-project-map.sh (resolved via GCP_PROJECT_MAP
#     env var) and to `bq` (resolved via BQ_BIN env var). We stub both
#     with tiny scripts in a per-test dir so we can record argv and assert
#     on the exact commands constructed.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'
  SCRIPT="$BATS_TEST_DIRNAME/../personal/bq.sh"

  STUB_DIR="$(mktemp -d)"
  GPM_ARGV_FILE="$STUB_DIR/gpm.argv"
  BQ_ARGV_FILE="$STUB_DIR/bq.argv"

  # Default stub for gcp-project-map.sh: succeeds, records argv, emits a
  # canned project ID for --bq, and emits a canned env list for --list-envs.
  cat >"$STUB_DIR/gcp-project-map.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$GPM_ARGV_FILE"
case "\$1" in
  --bq)         echo "prj-test-fake-tst" ;;
  --list-envs)  printf 'dev\ntst\nprd\n' ;;
  *)            echo "stub-gpm: unhandled \$*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$STUB_DIR/gcp-project-map.sh"
  export GCP_PROJECT_MAP="$STUB_DIR/gcp-project-map.sh"

  # Default stub for `bq`: succeeds, records argv.
  cat >"$STUB_DIR/bq" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$BQ_ARGV_FILE"
echo "STUB_BQ_OK"
EOF
  chmod +x "$STUB_DIR/bq"
  export BQ_BIN="$STUB_DIR/bq"
}

teardown() {
  rm -rf "$STUB_DIR"
}

gpm_argv() { cat "$GPM_ARGV_FILE" 2>/dev/null; }
bq_argv() { cat "$BQ_ARGV_FILE" 2>/dev/null; }

# --- usage / help ------------------------------------------------------------

@test "bq: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: bq.sh"
  assert_output --partial "--list-envs"
}

@test "bq: -h short flag works" {
  run "$SCRIPT" -h
  assert_success
  assert_output --partial "Usage: bq.sh"
}

# --- argument validation -----------------------------------------------------

@test "bq: no args fails with 'No SQL or mode flag'" {
  run "$SCRIPT" --env tst
  assert_failure 2
  assert_output --partial "No SQL or mode flag"
}

@test "bq: missing --env fails with 'Missing --env'" {
  run "$SCRIPT" "SELECT 1"
  assert_failure 2
  assert_output --partial "Missing --env"
}

@test "bq: unknown flag fails with 'Unknown option'" {
  run "$SCRIPT" --bogus tst
  assert_failure 2
  assert_output --partial "Unknown option: --bogus"
}

@test "bq: --table-info requires --dataset" {
  run "$SCRIPT" --env tst --table-info '%foo%'
  assert_failure 2
  assert_output --partial "--table-info requires --dataset"
}

@test "bq: --schema requires --dataset" {
  run "$SCRIPT" --env tst --schema clients
  assert_failure 2
  assert_output --partial "--schema requires --dataset"
}

@test "bq: --last-modified requires --dataset" {
  run "$SCRIPT" --env tst --last-modified clients
  assert_failure 2
  assert_output --partial "--last-modified requires --dataset"
}

@test "bq: mode flags are mutually exclusive" {
  run "$SCRIPT" --env tst --schema clients --table-info '%foo%' --dataset all_clients
  assert_failure 2
  assert_output --partial "mutually exclusive"
}

@test "bq: --list-envs is mutually exclusive with --schema" {
  run "$SCRIPT" --schema clients --list-envs
  assert_failure 2
  assert_output --partial "mutually exclusive"
}

# --- missing dependency -----------------------------------------------------

@test "bq: missing gcp-project-map.sh exits 3 with helpful pointer" {
  GCP_PROJECT_MAP="/nonexistent/gcp-project-map.sh" run "$SCRIPT" --env tst "SELECT 1"
  assert_failure 3
  assert_output --partial "gcp-project-map.sh not found"
  assert_output --partial "wpromote/scripts"
}

@test "bq: missing bq binary exits 3" {
  BQ_BIN="/nonexistent/bq-cli" run "$SCRIPT" --env tst "SELECT 1"
  assert_failure 3
  assert_output --partial "Missing dependency"
}

# --- list-envs --------------------------------------------------------------

@test "bq: --list-envs delegates to gcp-project-map --list-envs" {
  run "$SCRIPT" --list-envs
  assert_success
  assert_line "dev"
  assert_line "tst"
  assert_line "prd"
  argv="$(gpm_argv)"
  [[ "$argv" == *"--list-envs"* ]]
}

# --- env resolution propagation ---------------------------------------------

@test "bq: resolver failure exits non-zero with clear message" {
  # Override the gpm stub to fail on --bq.
  cat >"$STUB_DIR/gcp-project-map.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --bq) echo "Error: No BQ project found for env 'bogus'" >&2; exit 1 ;;
esac
exit 99
EOF
  chmod +x "$STUB_DIR/gcp-project-map.sh"

  run "$SCRIPT" --env bogus "SELECT 1"
  assert_failure
  assert_output --partial "Failed to resolve BQ project for env 'bogus'"
}

# --- happy paths: argv to bq -----------------------------------------------

@test "bq: raw SQL builds 'bq query' with project + standard SQL + format" {
  run "$SCRIPT" --env tst "SELECT 1"
  assert_success
  assert_output --partial "STUB_BQ_OK"

  argv="$(bq_argv)"
  [[ "$argv" == *"--project_id=prj-test-fake-tst"* ]]
  [[ "$argv" == *"query"* ]]
  [[ "$argv" == *"--use_legacy_sql=false"* ]]
  [[ "$argv" == *"--format=pretty"* ]]
  [[ "$argv" == *"SELECT 1"* ]]
}

@test "bq: --format overrides default" {
  run "$SCRIPT" --env tst --format json "SELECT 1"
  assert_success
  argv="$(bq_argv)"
  [[ "$argv" == *"--format=json"* ]]
  [[ "$argv" != *"--format=pretty"* ]]
}

@test "bq: --table-info builds COLUMN_FIELD_PATHS query" {
  run "$SCRIPT" --env tst --table-info '%client_id%' --dataset all_clients
  assert_success
  argv="$(bq_argv)"
  [[ "$argv" == *"INFORMATION_SCHEMA.COLUMN_FIELD_PATHS"* ]]
  [[ "$argv" == *"prj-test-fake-tst.all_clients"* ]]
  [[ "$argv" == *"%client_id%"* ]]
  [[ "$argv" == *"--use_legacy_sql=false"* ]]
}

@test "bq: --last-modified builds __TABLES__ query for given table" {
  run "$SCRIPT" --env tst --last-modified clients --dataset all_clients
  assert_success
  argv="$(bq_argv)"
  [[ "$argv" == *"__TABLES__"* ]]
  [[ "$argv" == *"prj-test-fake-tst.all_clients"* ]]
  [[ "$argv" == *"table_id = 'clients'"* ]]
}

@test "bq: --schema uses 'bq show --schema' (not query)" {
  run "$SCRIPT" --env tst --schema clients --dataset all_clients
  assert_success
  argv="$(bq_argv)"
  [[ "$argv" == *"show"* ]]
  [[ "$argv" == *"--schema"* ]]
  [[ "$argv" == *"--format=prettyjson"* ]]
  [[ "$argv" == *"prj-test-fake-tst:all_clients.clients"* ]]
  # Should NOT have invoked 'query' subcommand for --schema.
  [[ "$argv" != *"query"* ]]
}

# --- bq exit propagation ----------------------------------------------------

@test "bq: bq nonzero exit propagates (not swallowed)" {
  cat >"$STUB_DIR/bq" <<'EOF'
#!/usr/bin/env bash
echo "bq: simulated upstream failure" >&2
exit 7
EOF
  chmod +x "$STUB_DIR/bq"

  run "$SCRIPT" --env tst "SELECT 1"
  assert_failure
  [[ "$status" -eq 7 ]]
  assert_output --partial "simulated upstream failure"
}

# --- repo-relative source resolution (regression for 4.6-B) ----------------
# Same defense as in bq-dadbod-url.bats: bq.sh historically sourced
# lib/common.sh via $HOME/code/scripts which broke on CI runners and
# anyone cloning the repo elsewhere. The fix resolves via BASH_SOURCE.

@test "bq: resolves lib/common.sh when invoked from a non-\$HOME cwd" {
  cd /tmp
  # Hit a no-shellout codepath so we don't need bq itself.
  run "$SCRIPT" --list-envs
  assert_success
  assert_output --partial "tst"
  # Confirm common.sh actually loaded: missing-arg path uses die_usage.
  run "$SCRIPT"
  assert_failure 2
  refute_output --partial "command not found"
}

@test "bq: resolves lib/common.sh when HOME points elsewhere" {
  fake_home="$(mktemp -d)"
  cd /tmp
  HOME="$fake_home" run "$SCRIPT" --list-envs
  assert_success
  assert_output --partial "tst"
  rm -rf "$fake_home"
}
