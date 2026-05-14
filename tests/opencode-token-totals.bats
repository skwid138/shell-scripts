#!/usr/bin/env bats
# Tests for opencode-token-totals.sh

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../agent/opencode-token-totals.sh"
  TMP_DATA="$BATS_TEST_TMPDIR/opencode-data"
  mkdir -p "$TMP_DATA"
}

create_session_table() {
  sqlite3 "$TMP_DATA/opencode.db" <<'SQL'
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  time_created INTEGER,
  tokens_input INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0,
  tokens_cache_read INTEGER DEFAULT 0,
  tokens_cache_write INTEGER DEFAULT 0
);
SQL
}

insert_fixture_sessions() {
  sqlite3 "$TMP_DATA/opencode.db" <<'SQL'
INSERT INTO session (id, time_created, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write)
VALUES
  ('old', (strftime('%s','now') - 30 * 86400) * 1000, 100, 200, 300, 400),
  ('recent-1', (strftime('%s','now') - 6 * 86400) * 1000, 50000, 0, 900000, 50000),
  ('recent-2', (strftime('%s','now') - 1 * 86400) * 1000, 10, 10, 80, 0);
SQL
}

@test "--help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage:"
}

@test "unknown flag exits 2" {
  run "$SCRIPT" --bogus
  assert_failure 2
}

@test "missing sqlite3 exits 3" {
  stub_bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_bin"
  ln -s "$(command -v bash)" "$stub_bin/bash"
  ln -s "$(command -v dirname)" "$stub_bin/dirname"

  PATH="$stub_bin" run "$SCRIPT"

  assert_failure 3
}

@test "missing DB file exits 1 with not found" {
  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT"

  assert_failure 1
  assert_output --partial "not found"
}

@test "empty DB prints no sessions" {
  create_session_table

  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT"

  assert_success
  assert_output --partial "No sessions found."
}

@test "sessions with zero total tokens print no sessions" {
  create_session_table
  sqlite3 "$TMP_DATA/opencode.db" <<'SQL'
INSERT INTO session (id, time_created, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write)
VALUES ('zeroes', strftime('%s','now') * 1000, 0, 0, 0, 0);
SQL

  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT"

  assert_success
  assert_output --partial "No sessions found."
}

@test "lifetime query prints active days sessions tokens and cache reads" {
  create_session_table
  insert_fixture_sessions

  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT"

  assert_success
  assert_output --partial "Active days:     3"
  assert_output --partial "Total sessions:  3"
  assert_output --partial "Total tokens:    1,001,100"
  assert_output --partial "Cache reads:     90%"
}

@test "--days 7 includes only recent sessions" {
  create_session_table
  insert_fixture_sessions

  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT" --days 7

  assert_success
  assert_output --partial "Active days:     2"
  assert_output --partial "Total sessions:  2"
  assert_output --partial "Total tokens:    1,000,100"
  assert_output --partial "Cache reads:     90%"
}

@test "cache reads percentage is rounded from cache-read tokens over total tokens" {
  create_session_table
  sqlite3 "$TMP_DATA/opencode.db" <<'SQL'
INSERT INTO session (id, time_created, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write)
VALUES
  ('one', strftime('%s','now') * 1000, 100, 100, 50, 0),
  ('two', strftime('%s','now') * 1000, 50, 50, 50, 0);
SQL

  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT"

  assert_success
  assert_output --partial "Cache reads:     25%"
}

@test "large numbers are formatted with commas" {
  create_session_table
  sqlite3 "$TMP_DATA/opencode.db" <<'SQL'
INSERT INTO session (id, time_created, tokens_input, tokens_output, tokens_cache_read, tokens_cache_write)
VALUES ('million', strftime('%s','now') * 1000, 1000000, 0, 0, 0);
SQL

  OPENCODE_DATA_DIR="$TMP_DATA" run "$SCRIPT"

  assert_success
  assert_output --partial "Total tokens:    1,000,000"
}
