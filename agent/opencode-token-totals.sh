#!/usr/bin/env bash
# Summarize OpenCode token usage from the local SQLite database.

set -uo pipefail

# shellcheck source=../lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: opencode-token-totals [options]

Print a human-readable token usage summary from OpenCode's SQLite database.

Options:
  --days N      Limit to sessions created in the last N days
  -h, --help   Show this help
EOF
}

format_commas() {
  local n="$1"
  local sign=""
  local out=""
  local chunk=""

  if [[ "$n" == -* ]]; then
    sign="-"
    n="${n#-}"
  fi

  while [[ ${#n} -gt 3 ]]; do
    chunk="${n:$((${#n} - 3)):3}"
    out=",${chunk}${out}"
    n="${n:0:$((${#n} - 3))}"
  done

  printf '%s%s%s\n' "$sign" "$n" "$out"
}

days=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --days)
      [[ $# -ge 2 ]] || die_usage "--days requires an integer argument"
      [[ "$2" =~ ^[0-9]+$ ]] || die_usage "--days requires an integer argument"
      days="$2"
      shift 2
      ;;
    *)
      die_usage "Unknown option: $1"
      ;;
  esac
done

require_cmd sqlite3

db_path="${OPENCODE_DATA_DIR:-$HOME/.local/share/opencode}/opencode.db"
[[ -f "$db_path" ]] || die "Database not found: $db_path"

where_clause="1 = 1"
if [[ -n "$days" ]]; then
  where_clause="time_created >= (strftime('%s','now') - ${days} * 86400) * 1000"
fi

if ! query_result="$(
  sqlite3 -noheader -separator '|' "$db_path" <<SQL
WITH totals AS (
  SELECT
    COUNT(*) AS session_count,
    COALESCE(SUM(tokens_input + tokens_output + tokens_cache_read + tokens_cache_write), 0) AS total_tokens,
    COALESCE(SUM(tokens_cache_read), 0) AS cache_read_tokens,
    COUNT(DISTINCT date(time_created / 1000, 'unixepoch')) AS active_days
  FROM session
  WHERE ${where_clause}
)
SELECT
  session_count,
  total_tokens,
  CASE
    WHEN total_tokens = 0 THEN 0
    ELSE CAST(ROUND(cache_read_tokens * 100.0 / total_tokens) AS INTEGER)
  END,
  active_days
FROM totals;
SQL
)"; then
  die "Failed to query database: $db_path"
fi

IFS='|' read -r session_count total_tokens cache_read_percent active_days <<EOF
$query_result
EOF

if [[ "$session_count" == "0" || "$total_tokens" == "0" ]]; then
  printf 'No sessions found.\n'
  exit 0
fi

printf '%-17s%s\n' 'Active days:' "$(format_commas "$active_days")"
printf '%-17s%s\n' 'Total sessions:' "$(format_commas "$session_count")"
printf '%-17s%s\n' 'Total tokens:' "$(format_commas "$total_tokens")"
printf '%-17s%s%%\n' 'Cache reads:' "$cache_read_percent"
