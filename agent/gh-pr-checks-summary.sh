#!/usr/bin/env bash
set -uo pipefail
# shellcheck source=../lib/detect.sh
source "$(dirname "$0")/../lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: gh-pr-checks-summary [options] [PR_REF]

Fetch GitHub PR check runs and summarize their state. Outputs JSON to
stdout by default, or a single status word with --status.

Arguments:
  PR_REF              PR number, owner/repo#number, or full URL
                      (default: current branch's open PR)

Options:
  --filter REGEX      Only include checks whose name matches REGEX
                      (case-insensitive). Useful for checking a specific
                      provider, e.g. --filter sonar.
  --status            Print a single status word instead of JSON. With
                      --filter, summarizes only the first matching check.
                      Without --filter, summarizes all checks combined.
                      Possible values:
                        passed       All matched checks completed successfully
                        failed       At least one matched check failed
                        running      At least one matched check is still running
                        not_found    --filter matched zero checks
                        unknown      Could not determine state
  -h, --help          Show this help

Output (default JSON shape):
  {
    "pr": 275,
    "repo": "wpromote/polaris-web",
    "checks": [
      {
        "name":          "SonarCloud Code Analysis",
        "bucket":        "pass",
        "state":         "SUCCESS",
        "workflow":      "...",
        "link":          "...",
        "summary_state": "passed|failed|running|other"
      },
      ...
    ],
    "summary": {
      "total":   N,
      "passed":  N,
      "failed":  N,
      "running": N,
      "other":   N
    }
  }

Note: `bucket` and `state` are the raw fields from `gh pr checks`.
`summary_state` is added by this script and collapses to one of:
passed | failed | running | other.

Exit codes:
  0   Success
  1   No PR found for current branch (when PR_REF omitted)
  2   Usage error
  3   Missing dependency
  4   Not authenticated
  5   Upstream failure (gh API error)

Examples:
  gh-pr-checks-summary                      # full JSON for current PR
  gh-pr-checks-summary --status             # combined status word
  gh-pr-checks-summary --filter sonar       # JSON of sonar* checks only
  gh-pr-checks-summary --filter sonar --status   # just: passed|failed|running|not_found
EOF
}

# --- Parse arguments ---
FILTER=""
STATUS_ONLY=0
PR_REF_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --filter | --name)
      [[ $# -ge 2 ]] || die_usage "Missing value for $1"
      FILTER="$2"
      shift 2
      ;;
    --status)
      STATUS_ONLY=1
      shift
      ;;
    *)
      if [[ -z "$PR_REF_ARG" ]]; then
        PR_REF_ARG="$1"
      else
        die_usage "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

# --- Preflight ---
require_cmd "gh" "Install: https://cli.github.com/"
require_cmd "jq" "Install: brew install jq"
require_auth "gh" "gh auth status" "gh auth login"

# --- Resolve PR_REF -> OWNER, REPO, PR_NUMBER ---
OWNER=""
REPO=""
PR_NUMBER=""

if [[ -n "$PR_REF_ARG" ]]; then
  parse_pr_ref "$PR_REF_ARG"
fi

if [[ -z "$OWNER" || -z "$REPO" ]]; then
  if owner_repo="$(detect_owner_repo 2>/dev/null)"; then
    OWNER="${OWNER:-${owner_repo%%/*}}"
    REPO="${REPO:-${owner_repo#*/}}"
  fi
fi

if [[ -z "$PR_NUMBER" ]]; then
  PR_NUMBER="$(detect_pr_number)" || die "No open PR for current branch. Specify a PR number."
fi

REPO_SLUG="${OWNER}/${REPO}"

# --- Fetch checks ---
# gh exit code is non-zero when checks haven't started yet OR on real failure;
# stderr disambiguates. We capture both and treat "no checks" as empty array.
checks_raw=""
checks_stderr=""
tmp_err="$(mktemp)"
trap 'rm -f "$tmp_err"' EXIT

if checks_raw="$(gh pr checks "$PR_NUMBER" --repo "$REPO_SLUG" \
  --json name,bucket,state,workflow,link 2>"$tmp_err")"; then
  : # success
else
  rc=$?
  checks_stderr="$(cat "$tmp_err")"
  # gh exits 8 specifically when checks are still pending; that's not a
  # failure for us — fetch with --required=false would have been better but
  # isn't necessary here. Re-issue without exit-on-pending behavior: just
  # accept whatever JSON gh produced even on rc=8.
  if [[ "$rc" -eq 8 ]] && [[ -n "$checks_raw" ]]; then
    : # checks pending; raw output already valid JSON
  # gh prints "no checks reported" / "no checks were run" when there
  # genuinely are no check runs; treat that as an empty list.
  elif echo "$checks_stderr" | grep -qiE "no checks (reported|found|on this|were run)"; then
    checks_raw="[]"
  else
    die_upstream "gh pr checks failed (rc=$rc): $checks_stderr"
  fi
fi

# Validate JSON; gh has been known to print warnings to stdout on edge paths.
if ! echo "$checks_raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
  checks_raw="[]"
fi

# --- Apply --filter (case-insensitive name match) ---
if [[ -n "$FILTER" ]]; then
  filtered="$(echo "$checks_raw" | jq --arg pat "$FILTER" \
    '[.[] | select(.name | test($pat; "i"))]')"
else
  filtered="$checks_raw"
fi

# --- Classify each check into state ---
# gh's `bucket` field is the canonical semantic grouping. Documented values:
#   pass | fail | pending | skipping | cancel | none
# We collapse to: passed | failed | running | other (skipping/cancel/none).
classified="$(echo "$filtered" | jq '
  [.[] | . + {
    summary_state: (
      (.bucket // "") as $b |
      if   $b == "pass"    then "passed"
      elif $b == "fail"    then "failed"
      elif $b == "pending" then "running"
      else                      "other"
      end
    )
  }]
')"

# --- Build summary counts ---
summary="$(echo "$classified" | jq '{
  total:   length,
  passed:  ([.[] | select(.summary_state == "passed")]  | length),
  failed:  ([.[] | select(.summary_state == "failed")]  | length),
  running: ([.[] | select(.summary_state == "running")] | length),
  other:   ([.[] | select(.summary_state == "other")]   | length)
}')"

# --- --status mode ---
if [[ "$STATUS_ONLY" -eq 1 ]]; then
  total=$(echo "$summary" | jq -r '.total')
  if [[ -n "$FILTER" && "$total" -eq 0 ]]; then
    echo "not_found"
    exit 0
  fi
  if [[ "$total" -eq 0 ]]; then
    # No filter, no checks at all.
    echo "not_found"
    exit 0
  fi

  failed=$(echo "$summary" | jq -r '.failed')
  running=$(echo "$summary" | jq -r '.running')
  passed=$(echo "$summary" | jq -r '.passed')

  if [[ "$failed" -gt 0 ]]; then
    echo "failed"
  elif [[ "$running" -gt 0 ]]; then
    echo "running"
  elif [[ "$passed" -gt 0 ]]; then
    echo "passed"
  else
    echo "unknown"
  fi
  exit 0
fi

# --- Default: full JSON ---
jq -n \
  --argjson pr "$PR_NUMBER" \
  --arg repo "$REPO_SLUG" \
  --argjson checks "$classified" \
  --argjson summary "$summary" \
  '{
    pr: $pr,
    repo: $repo,
    checks: $checks,
    summary: $summary
  }'
