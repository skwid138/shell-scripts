#!/usr/bin/env bash
# Auto-detection utilities: repo, branch, PR, ticket ID
# Source this file to use detect_* functions.

# Ensure common.sh is loaded
if [[ -z "${_LIB_COMMON_LOADED:-}" ]]; then
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

# Get current PR number for the branch
# Returns: PR number or exits 1 if no PR
detect_pr_number() {
  require_cmd "gh" "Install: brew install gh"
  gh pr view --json number --jq '.number' 2>/dev/null || return 1
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
