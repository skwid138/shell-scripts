#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: auto-ticket-context [branch-name]

Detect a Jira ticket from the current (or given) branch and fetch its data.
Combines branch-to-ticket detection with jira-fetch-ticket in one call.

Examples:
  auto-ticket-context                      → detect from current branch
  auto-ticket-context feature/PROJ-123-foo → use explicit branch
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

TICKET_ID="$(detect_ticket_from_branch "${1:-}")" || die "no ticket ID found in branch '${1:-$(detect_branch)}'"
exec "$(dirname "$0")/jira-fetch-ticket.sh" "$TICKET_ID"
