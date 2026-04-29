#!/usr/bin/env bash
# Auto-detection utilities: repo, branch, PR, ticket ID
# Source this file to use detect_* / parse_pr_ref functions.

# Ensure common.sh is loaded (re-source guard inside common.sh makes this cheap)
if [[ -z "${_LIB_COMMON_LOADED:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

# Get current git branch name
detect_branch() {
  git branch --show-current 2>/dev/null || die "Not in a git repository"
}

# Extract Jira ticket ID from branch name
# Supports: bixb_18835, bixb-18835-description, BIXB-18835, feature/bixb_18835
# Returns: BIXB-18835 (uppercase prefix, dash separator)
detect_ticket_from_branch() {
  local branch="${1:-$(detect_branch)}"

  # Strip common prefixes like feature/, bugfix/, etc.
  branch="${branch#*/}"

  # Pattern: prefix_number or prefix-number (at start of remaining string)
  if [[ "$branch" =~ ^([a-zA-Z]+)[_-]([0-9]+) ]]; then
    local prefix="${BASH_REMATCH[1]}"
    local number="${BASH_REMATCH[2]}"
    echo "${prefix^^}-${number}"
  else
    return 1
  fi
}

# Get current PR number for the branch.
# Exit codes (per project convention):
#   0   — PR found, number printed to stdout
#   1   — no open PR for current branch (expected condition; caller can decide)
#   3/4 — gh missing or unauthenticated (delegated to require_auth)
#   5   — gh API failure (auth was fine but call errored — surface to caller)
detect_pr_number() {
  require_auth "gh" "gh auth status" "gh auth login"

  local stderr_file
  stderr_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$stderr_file'" RETURN

  local out rc
  out="$(gh pr view --json number --jq '.number' 2>"$stderr_file")"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    printf '%s\n' "$out"
    return 0
  fi

  # gh returns non-zero for both "no PR found" and real errors.
  # Disambiguate by inspecting stderr.
  local stderr_content
  stderr_content="$(cat "$stderr_file")"
  if [[ "$stderr_content" == *"no pull requests found"* ]] ||
    [[ "$stderr_content" == *"no PR found"* ]] ||
    [[ "$stderr_content" == *"no open pull request"* ]]; then
    return 1
  fi

  # Real upstream failure — surface details and exit 5.
  die_upstream "gh pr view failed: ${stderr_content:-unknown error}"
}

# Get owner/repo from git remote origin
# Returns: "owner/repo" (e.g., "wpromote/polaris-web")
detect_owner_repo() {
  local remote
  remote="$(git remote get-url origin 2>/dev/null)" || die "No git remote 'origin' found"

  # Handle SSH: git@github.com:owner/repo.git
  # Handle HTTPS: https://github.com/owner/repo.git
  if [[ "$remote" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
  else
    die "Could not parse owner/repo from remote: $remote"
  fi
}

# Get just the repo name (without owner)
detect_repo_name() {
  local owner_repo
  owner_repo="$(detect_owner_repo)"
  echo "${owner_repo#*/}"
}

# Get just the owner (without repo)
detect_owner() {
  local owner_repo
  owner_repo="$(detect_owner_repo)"
  echo "${owner_repo%%/*}"
}

# Parse a PR reference string into OWNER, REPO, PR_NUMBER (caller-scoped vars).
#
# Accepted forms:
#   123                         -> sets PR_NUMBER only
#   #123                        -> sets PR_NUMBER only
#   owner/repo#123              -> sets OWNER, REPO, PR_NUMBER (existing values preserved)
#   https://github.com/o/r/pull/123  -> sets OWNER, REPO, PR_NUMBER (existing values preserved)
#
# Pre-existing OWNER / REPO in caller scope are NOT overwritten — flag-args win.
# PR_NUMBER is always set from the parsed ref.
#
# Exits 2 (usage) on unparseable input.
parse_pr_ref() {
  local ref="$1"
  if [[ "$ref" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    OWNER="${OWNER:-${BASH_REMATCH[1]}}"
    REPO="${REPO:-${BASH_REMATCH[2]}}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  elif [[ "$ref" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
    OWNER="${OWNER:-${BASH_REMATCH[1]}}"
    REPO="${REPO:-${BASH_REMATCH[2]}}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  elif [[ "${ref#\#}" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="${ref#\#}"
  else
    die_usage "Cannot parse PR reference: $ref"
  fi
}
