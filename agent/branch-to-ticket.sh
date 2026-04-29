#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: branch-to-ticket [branch-name]

Extract a Jira ticket ID from a git branch name.
If no branch provided, uses the current git branch.

Examples:
  branch-to-ticket bixb_18835        → BIXB-18835
  branch-to-ticket bixb-18835-desc   → BIXB-18835
  branch-to-ticket feature/bixb_123  → BIXB-123
  branch-to-ticket                   → (uses current branch)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

ticket="$(detect_ticket_from_branch "${1:-}")" || die "Could not extract ticket ID from branch '${1:-$(detect_branch)}'"
echo "$ticket"
