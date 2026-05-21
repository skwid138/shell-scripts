#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: permission-audit [--start DATE] [--end DATE] [--action ask|deny|all] [--agent AGENT] [--json|--human]

Audit opencode permission decisions from local log files.

Options:
  --start DATE        Start date, YYYY-MM-DD (default: today)
  --end DATE          End date, YYYY-MM-DD (default: today)
  --action ACTION     Permission decision filter: ask, deny, or all (default: ask)
  --agent AGENT       Filter by agent name (case-insensitive)
  --json              Emit JSON (default)
  --human             Emit a human-readable table
  -h, --help          Show this help

Environment:
  OPENCODE_LOG_DIR    Override the opencode log directory

Output:
  JSON object with keys: version, date_range, filters, summary, entries
EOF
}

is_valid_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

need_arg() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    die_usage "$flag requires an argument"
  fi
}

TODAY="${PERMISSION_AUDIT_TODAY:-$(date +%F)}"
START="$TODAY"
END="$TODAY"
ACTION="ask"
AGENT=""
FORMAT_FLAG="--json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --start)
      need_arg "$1" "${2:-}"
      START="$2"
      shift 2
      ;;
    --end)
      need_arg "$1" "${2:-}"
      END="$2"
      shift 2
      ;;
    --action)
      need_arg "$1" "${2:-}"
      ACTION="$2"
      shift 2
      ;;
    --agent)
      need_arg "$1" "${2:-}"
      AGENT="$2"
      shift 2
      ;;
    --json)
      FORMAT_FLAG="--json"
      shift
      ;;
    --human)
      FORMAT_FLAG="--human"
      shift
      ;;
    *)
      die_usage "Unknown option: $1"
      ;;
  esac
done

is_valid_date "$START" || die_usage "Invalid --start date: $START (expected YYYY-MM-DD)"
is_valid_date "$END" || die_usage "Invalid --end date: $END (expected YYYY-MM-DD)"
case "$ACTION" in
  ask | deny | all) ;;
  *) die_usage "Invalid --action: $ACTION (expected ask, deny, or all)" ;;
esac

require_cmd "python3"

SCRIPT_DIR="$(dirname "$0")"
PY_ARGS=("--start" "$START" "--end" "$END" "--action" "$ACTION")
if [[ -n "$AGENT" ]]; then
  PY_ARGS+=("--agent" "$AGENT")
fi
PY_ARGS+=("$FORMAT_FLAG")

python3 "$SCRIPT_DIR/permission_audit_core.py" "${PY_ARGS[@]}"
