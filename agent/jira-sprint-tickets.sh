#!/usr/bin/env bash
# jira-sprint-tickets — list Jira work items in a sprint for an assignee
#
# Builds a validated JQL query, runs a read-only `acli jira workitem search`,
# and normalizes the result into a versioned JSON envelope on stdout.

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: jira-sprint-tickets --project KEY [options]

List Jira work items in a sprint via the Atlassian CLI (read-only search).
Outputs exactly one JSON document to stdout.

Options:
      --project KEY       Jira project key (required; e.g. BIXB).
      --assignee VALUE    'currentUser()' (default) or an email / account ID.
      --sprint open|ID    'open' (default; all open sprints) or a numeric sprint ID.
      --status NAME       Filter by status name. Repeatable (combined with OR).
      --limit N           Return at most N tickets (positive integer).
                          Without --limit, all pages are fetched.
  -h, --help              Show this help.

Query:
  project = KEY AND assignee = A AND sprint S [AND status in ("..", "..")]
  ORDER BY created ASC
  Only the exact value 'currentUser()' is left unquoted; other assignees and
  status names are escaped JQL string literals. Control characters are rejected.

Output (stdout, exactly one JSON document; empty on any error):
  {"version":1, "jql":"...", "count":N, "limited":bool,
   "tickets":[{"key":"..","summary":"..","status":"..","type":".."}]}
  count is the number of tickets returned. limited is true when --limit was
  given (more matching tickets may exist). Missing fields are "".

Exit codes:
  0  success (including zero matching tickets)
  2  usage error (bad/missing option, invalid project/sprint/limit)
  3  missing dependency (acli or jq)
  4  acli not authenticated (run: acli auth login)
  5  acli search failed, or returned empty/malformed/unexpected output
     (acli's stderr is included; its exit code is not propagated)

Examples:
  jira-sprint-tickets --project BIXB
  jira-sprint-tickets --project BIXB --status 'Ready for Release' --status 'In QA Review'
  jira-sprint-tickets --project BIXB --assignee someone@example.com --sprint 4521 --limit 20
EOF
}

# require_value <flag> <remaining-arg-count> [value] — exit 2 if the flag's
# value is missing or empty. Callers then assign "$2" directly: capturing the
# value via command substitution would strip trailing newlines before the
# control-character check runs.
require_value() {
  if [[ "$2" -lt 2 || -z "${3:-}" ]]; then
    die_usage "$1 requires a non-empty value (see --help)"
  fi
}

# jql_string <value> — render a JQL string literal. JSON string escaping
# (backslash and double quote) matches JQL's; control characters are rejected
# during validation, so tojson never emits \uXXXX escapes here.
jql_string() {
  jq -rn --arg v "$1" '$v | tojson'
}

PROJECT=""
ASSIGNEE="currentUser()"
SPRINT="open"
STATUSES=()
LIMIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --project)
      require_value "$1" "$#" "${2:-}"
      PROJECT="$2"
      shift 2
      ;;
    --assignee)
      require_value "$1" "$#" "${2:-}"
      ASSIGNEE="$2"
      shift 2
      ;;
    --sprint)
      require_value "$1" "$#" "${2:-}"
      SPRINT="$2"
      shift 2
      ;;
    --status)
      require_value "$1" "$#" "${2:-}"
      STATUSES+=("$2")
      shift 2
      ;;
    --limit)
      require_value "$1" "$#" "${2:-}"
      LIMIT="$2"
      shift 2
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done

# --- validation (before any dependency check or search) ---
[[ -n "$PROJECT" ]] || die_usage "--project is required (see --help)"

for value in "$PROJECT" "$ASSIGNEE" "$SPRINT" "$LIMIT" ${STATUSES[@]+"${STATUSES[@]}"}; do
  if [[ "$value" =~ [[:cntrl:]] ]]; then
    die_usage "option values must not contain control characters"
  fi
done

[[ "$PROJECT" =~ ^[A-Z][A-Z0-9_]+$ ]] ||
  die_usage "--project must be a Jira project key matching ^[A-Z][A-Z0-9_]+\$ (got: $PROJECT)"

[[ "$SPRINT" == "open" || "$SPRINT" =~ ^[1-9][0-9]*$ ]] ||
  die_usage "--sprint must be 'open' or a numeric sprint ID (got: $SPRINT)"

[[ -z "$LIMIT" || "$LIMIT" =~ ^[1-9][0-9]*$ ]] ||
  die_usage "--limit must be a positive integer (got: $LIMIT)"

# --- preflight ---
require_cmd "jq"
require_auth "acli" "acli auth status" "acli auth login"

if [[ "$ASSIGNEE" == "currentUser()" ]]; then
  assignee_jql="currentUser()"
else
  assignee_jql="$(jql_string "$ASSIGNEE")"
fi

if [[ "$SPRINT" == "open" ]]; then
  sprint_jql="in openSprints()"
else
  sprint_jql="= ${SPRINT}"
fi

status_jql=""
if [[ ${#STATUSES[@]} -gt 0 ]]; then
  quoted=()
  for st in "${STATUSES[@]}"; do
    quoted+=("$(jql_string "$st")")
  done
  joined="$(printf '%s, ' "${quoted[@]}")"
  status_jql=" AND status in (${joined%, })"
fi

JQL="project = ${PROJECT} AND assignee = ${assignee_jql} AND sprint ${sprint_jql}${status_jql} ORDER BY created ASC"

if [[ -n "$LIMIT" ]]; then
  page_args=(--limit "$LIMIT")
  limited=true
else
  page_args=(--paginate)
  limited=false
fi

# --- search (read-only) ---
errfile="$(mktemp "${TMPDIR:-/tmp}/jira-sprint-tickets.XXXXXX")" ||
  die "could not create a temp file"
trap 'rm -f "$errfile"' EXIT

if ! raw="$(acli jira workitem search --jql "$JQL" --fields 'key,summary,status,issuetype' --json "${page_args[@]}" 2>"$errfile")"; then
  die_upstream "acli jira workitem search failed: $(cat "$errfile")"
fi

[[ -n "${raw//[[:space:]]/}" ]] ||
  die_upstream "acli jira workitem search returned empty output"

# Slurp so that multiple documents are detected; require exactly one top-level
# array of objects, then normalize. Output is buffered so stdout stays empty
# on any failure.
if ! envelope="$(jq -s --arg jql "$JQL" --argjson limited "$limited" '
  if length != 1 then error("expected one JSON document, got \(length)") else .[0] end
  | if type != "array" then error("expected a JSON array, got \(type)") else . end
  | if all(type == "object") then . else error("expected an array of objects") end
  | map({
      key: (.key // "" | tostring),
      summary: (.fields.summary // "" | tostring),
      status: (.fields.status.name // "" | tostring),
      type: (.fields.issuetype.name // "" | tostring)
    })
  | {version: 1, jql: $jql, count: length, limited: $limited, tickets: .}
' <<<"$raw" 2>"$errfile")"; then
  die_upstream "unexpected acli search output: $(cat "$errfile")"
fi

printf '%s\n' "$envelope"
