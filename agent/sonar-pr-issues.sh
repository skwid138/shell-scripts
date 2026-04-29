#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: sonar-pr-issues [options] [PR_NUMBER]

Fetch SonarCloud issues for a pull request. Outputs JSON to stdout.

Arguments:
  PR_NUMBER           PR number (default: auto-detect from current branch)

Options:
  --project KEY       SonarCloud project key (default: auto-detect from repo)
  --severity LEVEL    Minimum severity: BLOCKER, CRITICAL, MAJOR, MINOR, INFO
  --format FORMAT     Output format: json (default), toon (raw CLI output)
  -h, --help          Show this help

Supported repos: client-portal, kraken, polaris-api, polaris-web

Examples:
  sonar-pr-issues                          # current branch PR
  sonar-pr-issues 275                      # specific PR
  sonar-pr-issues --severity MAJOR 275     # MAJOR+ only
  sonar-pr-issues --project wpromote_polaris-web --severity CRITICAL 280
EOF
}

# --- Project key lookup ---
# Note: keys MUST be quoted. Without quotes shfmt parses them as arithmetic
# expressions (treating '-' as subtraction), corrupting "client-portal" into
# "client - portal" and silently breaking lookups.
declare -A PROJECT_KEYS=(
  ["client-portal"]="wpromote_client-portal"
  ["kraken"]="wpromote_kraken"
  ["polaris-api"]="wpromote_polaris-api"
  ["polaris-web"]="wpromote_polaris-web"
)

SEVERITY_ORDER=("BLOCKER" "CRITICAL" "MAJOR" "MINOR" "INFO")

# Returns 0 if $1 >= $2 in severity
_severity_gte() {
  local target="$1" floor="$2"
  local i
  for i in "${!SEVERITY_ORDER[@]}"; do
    [[ "${SEVERITY_ORDER[$i]}" == "$target" ]] && local target_idx="$i"
    [[ "${SEVERITY_ORDER[$i]}" == "$floor" ]] && local floor_idx="$i"
  done
  [[ "${target_idx:-99}" -le "${floor_idx:-0}" ]]
}

# --- Parse arguments ---
PROJECT=""
PR_NUMBER=""
SEVERITY_FLOOR=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --severity)
      SEVERITY_FLOOR="${2^^}"
      shift 2
      ;;
    --format)
      FORMAT="$2"
      shift 2
      ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ && -z "$PR_NUMBER" ]]; then
        PR_NUMBER="$1"
      else
        die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

# --- Preflight ---
require_cmd "sonar" "Install: curl -o- https://raw.githubusercontent.com/SonarSource/sonarqube-cli/refs/heads/master/user-scripts/install.sh | bash"
require_auth "sonar" "sonar auth status" "sonar auth login -o wpromote --with-token <TOKEN>"

# Detect project key
if [[ -z "$PROJECT" ]]; then
  repo_name="$(detect_repo_name)"
  PROJECT="${PROJECT_KEYS[$repo_name]:-}"
  [[ -n "$PROJECT" ]] || die "Repo '$repo_name' has no SonarCloud project. Supported: ${!PROJECT_KEYS[*]}"
fi

# Detect PR number
if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER="$(detect_pr_number)" || die "No open PR for current branch. Provide a PR number."
fi

# --- Check CI status ---
# Delegated to agent/gh-pr-checks-summary.sh, which classifies bucket=pass/fail/
# pending into a single status word. Translate its vocabulary to ours:
#   passed   -> passed
#   failed   -> failed
#   running  -> running
#   not_found -> no_check_found
#   (anything else, including a script failure) -> unknown
ci_status="unknown"
checks_script="$(dirname "$0")/gh-pr-checks-summary.sh"
if [[ -x "$checks_script" ]]; then
  raw_status="$("$checks_script" --filter sonar --status "$PR_NUMBER" 2>/dev/null)" || raw_status=""
  case "$raw_status" in
    passed) ci_status="passed" ;;
    failed) ci_status="failed" ;;
    running) ci_status="running" ;;
    not_found) ci_status="no_check_found" ;;
    *) ci_status="unknown" ;;
  esac
fi

# --- Fetch issues (with pagination) ---
info "Fetching SonarCloud issues for ${PROJECT} PR #${PR_NUMBER}..."

all_issues="[]"
page=1
while true; do
  result="$(sonar list issues -p "$PROJECT" --pull-request "$PR_NUMBER" --format json --page "$page" 2>&1)" ||
    die "sonar CLI failed: $result"

  issues="$(echo "$result" | jq '.issues // []')"
  all_issues="$(echo "$all_issues $issues" | jq -s '.[0] + .[1]')"

  total="$(echo "$result" | jq '.paging.total // 0')"
  fetched="$(echo "$all_issues" | jq 'length')"

  [[ "$fetched" -lt "$total" ]] || break
  ((page++))
done

# --- Filter: only OPEN/CONFIRMED ---
all_issues="$(echo "$all_issues" | jq '[.[] | select(.issueStatus == "OPEN" or .issueStatus == "CONFIRMED")]')"

# --- Filter: severity floor ---
if [[ -n "$SEVERITY_FLOOR" ]]; then
  # Build jq filter for allowed severities
  allowed="[]"
  for sev in "${SEVERITY_ORDER[@]}"; do
    allowed="$(echo "$allowed" | jq --arg s "$sev" '. + [$s]')"
    [[ "$sev" == "$SEVERITY_FLOOR" ]] && break
  done
  all_issues="$(echo "$all_issues" | jq --argjson allowed "$allowed" '[.[] | select(.severity as $s | $allowed | index($s))]')"
fi

# --- Strip project key prefix from component paths ---
all_issues="$(echo "$all_issues" | jq --arg prefix "${PROJECT}:" '[.[] | .component = (.component | ltrimstr($prefix))]')"

# --- Output ---
if [[ "$FORMAT" == "toon" ]]; then
  # Re-fetch with toon format for display
  sonar list issues -p "$PROJECT" --pull-request "$PR_NUMBER" --format toon
else
  jq -n \
    --arg project "$PROJECT" \
    --argjson pr "$PR_NUMBER" \
    --arg ci_status "$ci_status" \
    --argjson issues "$all_issues" \
    '{
      project: $project,
      pr: $pr,
      ci_status: $ci_status,
      total: ($issues | length),
      issues: $issues
    }'
fi
