#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: gh-current-pr [--json]

Get the PR number for the current branch.

Options:
  --json    Output full PR metadata as JSON (number, url, head, base)
  -h        Show this help

Examples:
  gh-current-pr          → 275
  gh-current-pr --json   → {"number":275,"url":"...","headRefName":"...","baseRefName":"..."}
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

require_auth "gh" "gh auth status" "gh auth login"

if [[ "${1:-}" == "--json" ]]; then
  gh pr view --json number,url,headRefName,baseRefName 2>/dev/null \
    || die "No open PR found for current branch '$(detect_branch)'"
else
  detect_pr_number || die "No open PR found for current branch '$(detect_branch)'"
fi
