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

# --- repo-relative source resolution (regression for 4.6-B) ----------------
# The script must resolve lib/common.sh relative to its own location, NOT
# via $HOME/code/scripts. Otherwise it fails on CI (where the checkout path
# isn't $HOME/code/scripts) AND for any user who clones the repo elsewhere.
# Reverting the fix in personal/bq-dadbod-url.sh to the old hardcoded
# $HOME path makes this test fail.

@test "bq-dadbod-url: resolves lib/common.sh when invoked from a non-\$HOME cwd" {
  # cd somewhere unrelated to the repo so the script's only way to find
  # lib/common.sh is via BASH_SOURCE-relative resolution.
  cd /tmp
  run "$SCRIPT" tst all_clients
  assert_success
  assert_output "bigquery://prj-test-fake-tst/all_clients"
  # If common.sh failed to load, die_usage would be undefined and the
  # missing-arg path below would surface "die_usage: command not found"
  # instead of exit 2 with the expected message.
  run "$SCRIPT"
  assert_failure 2
  assert_output --partial "Missing <env>"
  refute_output --partial "command not found"
}

@test "bq-dadbod-url: resolves lib/common.sh when HOME points elsewhere" {
  # Simulates a CI runner where $HOME exists but doesn't contain
  # code/scripts/. The fix must not rely on $HOME at all.
  fake_home="$(mktemp -d)"
  cd /tmp
  HOME="$fake_home" run "$SCRIPT" tst all_clients
  assert_success
  assert_output "bigquery://prj-test-fake-tst/all_clients"
  rm -rf "$fake_home"
}
