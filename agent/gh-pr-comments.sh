#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/../lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: gh-pr-comments [options] [PR_REF]

Fetch all review comments, threads, and review metadata from a GitHub PR.
Outputs structured JSON to stdout.

Arguments:
  PR_REF              PR number, owner/repo#number, or full URL
                      (default: current branch's open PR)

Options:
  --owner OWNER       Repository owner (default: auto-detect from git remote)
  --repo REPO         Repository name (default: auto-detect from git remote)
  --pr NUMBER         PR number (alternative to positional arg)
  --no-diff           Skip fetching the PR diff (faster)
  --no-commits        Skip fetching commit history
  -h, --help          Show this help

Output:
  JSON object with keys: metadata, reviews, threads, files, commits, diff

Examples:
  gh-pr-comments                     # current branch PR
  gh-pr-comments 123                 # PR #123 in current repo
  gh-pr-comments wpromote/polaris-web#275
  gh-pr-comments --pr 123 --owner wpromote --repo polaris-api
EOF
}

# Parse a PR reference into OWNER, REPO, PR_NUMBER
_parse_pr_ref() {
  local ref="$1"
  # Full URL: https://github.com/owner/repo/pull/123
  if [[ "$ref" =~ github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    OWNER="${OWNER:-${BASH_REMATCH[1]}}"
    REPO="${REPO:-${BASH_REMATCH[2]}}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  # owner/repo#number
  elif [[ "$ref" =~ ^([^/]+)/([^#]+)#([0-9]+)$ ]]; then
    OWNER="${OWNER:-${BASH_REMATCH[1]}}"
    REPO="${REPO:-${BASH_REMATCH[2]}}"
    PR_NUMBER="${BASH_REMATCH[3]}"
  # Just a number (strip leading #)
  elif [[ "${ref#\#}" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="${ref#\#}"
  else
    die "Cannot parse PR reference: $ref"
  fi
}

# --- Parse arguments ---
OWNER=""
REPO=""
PR_NUMBER=""
FETCH_DIFF=1
FETCH_COMMITS=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --owner) OWNER="$2"; shift 2 ;;
    --repo) REPO="$2"; shift 2 ;;
    --pr) PR_NUMBER="$2"; shift 2 ;;
    --no-diff) FETCH_DIFF=0; shift ;;
    --no-commits) FETCH_COMMITS=0; shift ;;
    *)
      if [[ -z "$PR_NUMBER" ]]; then
        _parse_pr_ref "$1"
      else
        die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

# --- Resolve defaults ---
require_auth "gh" "gh auth status" "gh auth login"

if [[ -z "$OWNER" || -z "$REPO" ]]; then
  local_owner_repo="$(detect_owner_repo 2>/dev/null)" || die "Cannot detect repo. Use --owner and --repo."
  OWNER="${OWNER:-${local_owner_repo%%/*}}"
  REPO="${REPO:-${local_owner_repo#*/}}"
fi

if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER="$(detect_pr_number)" || die "No open PR for current branch. Specify a PR number."
fi

REPO_SLUG="${OWNER}/${REPO}"

# --- Verify PR exists ---
gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json number,title >/dev/null 2>&1 \
  || die "Could not access PR #${PR_NUMBER} in ${REPO_SLUG}. Verify it exists and you have access."

# --- Fetch metadata ---
info "Fetching PR #${PR_NUMBER} from ${REPO_SLUG}..."
metadata="$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" \
  --json number,title,body,state,baseRefName,headRefName,author,mergeable,url)"

# --- Fetch reviews + threads via GraphQL ---

# Paginate reviews and threads separately for simplicity

_fetch_reviews() {
  local cursor=""
  local all="[]"
  while true; do
    local cursor_arg=()
    [[ -n "$cursor" ]] && cursor_arg=(-f "reviewCursor=$cursor")
    local result
    result="$(gh api graphql \
      -f query='query($owner: String!, $repo: String!, $number: Int!, $reviewCursor: String) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $number) {
            reviews(first: 100, after: $reviewCursor) {
              pageInfo { hasNextPage endCursor }
              nodes { author { login } state body createdAt url }
            }
          }
        }
      }' \
      -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" \
      "${cursor_arg[@]}" 2>&1)" || die "GraphQL reviews query failed: $result"

    local nodes
    nodes="$(echo "$result" | jq '.data.repository.pullRequest.reviews.nodes // []')"
    all="$(echo "$all $nodes" | jq -s '.[0] + .[1]')"

    local has_next
    has_next="$(echo "$result" | jq -r '.data.repository.pullRequest.reviews.pageInfo.hasNextPage')"
    [[ "$has_next" == "true" ]] || break
    cursor="$(echo "$result" | jq -r '.data.repository.pullRequest.reviews.pageInfo.endCursor')"
  done
  echo "$all"
}

_fetch_threads() {
  local cursor=""
  local all="[]"
  while true; do
    local cursor_arg=()
    [[ -n "$cursor" ]] && cursor_arg=(-f "threadCursor=$cursor")
    local result
    result="$(gh api graphql \
      -f query='query($owner: String!, $repo: String!, $number: Int!, $threadCursor: String) {
        repository(owner: $owner, name: $repo) {
          pullRequest(number: $number) {
            reviewThreads(first: 100, after: $threadCursor) {
              pageInfo { hasNextPage endCursor }
              nodes {
                isResolved
                isOutdated
                comments(first: 50) {
                  nodes { author { login } body path line originalLine createdAt url outdated }
                }
              }
            }
          }
        }
      }' \
      -f owner="$OWNER" -f repo="$REPO" -F number="$PR_NUMBER" \
      "${cursor_arg[@]}" 2>&1)" || die "GraphQL threads query failed: $result"

    local nodes
    nodes="$(echo "$result" | jq '.data.repository.pullRequest.reviewThreads.nodes // []')"
    all="$(echo "$all $nodes" | jq -s '.[0] + .[1]')"

    local has_next
    has_next="$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage')"
    [[ "$has_next" == "true" ]] || break
    cursor="$(echo "$result" | jq -r '.data.repository.pullRequest.reviewThreads.pageInfo.endCursor')"
  done
  echo "$all"
}

all_reviews="$(_fetch_reviews)"
all_threads="$(_fetch_threads)"

# --- Fetch files ---
files="$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json files --jq '[.files[].path]')"

# --- Fetch commits (optional) ---
commits="[]"
if [[ "$FETCH_COMMITS" -eq 1 ]]; then
  commits="$(gh pr view "$PR_NUMBER" --repo "$REPO_SLUG" --json commits \
    --jq '[.commits[] | {sha: .oid[0:8], message: .messageHeadline}]' 2>/dev/null)" || commits="[]"
fi

# --- Fetch diff (optional) ---
diff=""
if [[ "$FETCH_DIFF" -eq 1 ]]; then
  diff="$(gh pr diff "$PR_NUMBER" --repo "$REPO_SLUG" 2>/dev/null)" || diff=""
fi

# --- Assemble output ---
jq -n \
  --argjson metadata "$metadata" \
  --argjson reviews "$all_reviews" \
  --argjson threads "$all_threads" \
  --argjson files "$files" \
  --argjson commits "$commits" \
  --arg diff "$diff" \
  '{
    metadata: $metadata,
    reviews: $reviews,
    threads: $threads,
    files: $files,
    commits: $commits,
    diff: $diff
  }'
