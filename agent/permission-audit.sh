#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: permission-audit [--start DATE] [--end DATE] [--source decisions|native] [--action allow|deny|all] [--agent AGENT] [--json|--human]

Audit opencode permission decisions from local log files.

Options:
  --start DATE        Start date, YYYY-MM-DD (default: today)
  --end DATE          End date, YYYY-MM-DD (default: today)
  --source SOURCE     Audit source: decisions or native (default: decisions)
  --action ACTION     Permission decision filter: allow, deny, or all (native uses ask in place of allow)
  --agent AGENT       Filter by agent name (case-insensitive)
  --json              Emit JSON (default)
  --human             Emit a human-readable table
  -h, --help          Show this help

Environment:
  OPENCODE_LOG_DIR        Override the opencode native log directory
  OPENCODE_DECISIONS_LOG  Override the durable decisions.log path

Output:
  JSON object with schema depending on --source. Decisions output is an interactive-prompt audit;
  static allow and deny rules that never prompt are not captured — not a comprehensive policy audit.
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
SOURCE="decisions"
ACTION=""
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
    --source)
      need_arg "$1" "${2:-}"
      SOURCE="$2"
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
case "$SOURCE" in
  decisions | native) ;;
  *) die_usage "Invalid --source: $SOURCE (expected decisions or native)" ;;
esac
if [[ -z "$ACTION" ]]; then
  if [[ "$SOURCE" == "native" ]]; then
    ACTION="ask"
  else
    ACTION="all"
  fi
fi
case "$ACTION" in
  ask | allow | deny | all) ;;
  *) die_usage "Invalid --action: $ACTION (expected ask, allow, deny, or all)" ;;
esac
if [[ "$SOURCE" == "native" && "$ACTION" == "allow" ]]; then
  die_usage "Invalid --action allow for source native"
fi
if [[ "$SOURCE" == "decisions" && "$ACTION" == "ask" ]]; then
  die_usage "Invalid --action ask for source decisions"
fi

require_cmd "python3"

SCRIPT_DIR="$(dirname "$0")"
PY_ARGS=("--start" "$START" "--end" "$END" "--source" "$SOURCE" "--action" "$ACTION")
if [[ -n "$AGENT" ]]; then
  PY_ARGS+=("--agent" "$AGENT")
fi
PY_ARGS+=("$FORMAT_FLAG")

python3 "$SCRIPT_DIR/permission_audit_core.py" "${PY_ARGS[@]}"
