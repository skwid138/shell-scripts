#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib/detect.sh"

usage() {
  cat <<'EOF'
Usage: jira-fetch-ticket [options] TICKET-ID

Fetch Jira ticket data via the Atlassian CLI. Outputs JSON to stdout.

Arguments:
  TICKET-ID           Jira ticket key (e.g., BIXB-18835)

Options:
  --all               Include comments, links, and attachments
  --comments          Include comments only
  --links             Include linked issues only
  --json-fields       Fetch full JSON fields (slower, more data)
  -h, --help          Show this help

Output:
  JSON object with keys: ticket, description, fields
  With --all: adds comments, links, attachments

Examples:
  jira-fetch-ticket BIXB-18835
  jira-fetch-ticket --all BIXB-18835
  jira-fetch-ticket --comments --links BIXB-18835
EOF
}

# --- Parse arguments ---
TICKET_ID=""
FETCH_COMMENTS=0
FETCH_LINKS=0
FETCH_ATTACHMENTS=0
FETCH_JSON_FIELDS=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --all) FETCH_COMMENTS=1; FETCH_LINKS=1; FETCH_ATTACHMENTS=1; shift ;;
    --comments) FETCH_COMMENTS=1; shift ;;
    --links) FETCH_LINKS=1; shift ;;
    --attachments) FETCH_ATTACHMENTS=1; shift ;;
    --json-fields) FETCH_JSON_FIELDS=1; shift ;;
    *)
      if [[ -z "$TICKET_ID" && "$1" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
        TICKET_ID="${1^^}"
      elif [[ -z "$TICKET_ID" ]]; then
        # Try to extract from URL
        if [[ "$1" =~ atlassian\.net/browse/([A-Za-z]+-[0-9]+) ]]; then
          TICKET_ID="${BASH_REMATCH[1]^^}"
        else
          die "Cannot parse ticket ID from: $1"
        fi
      else
        die "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$TICKET_ID" ]] || die "TICKET-ID is required. Usage: jira-fetch-ticket BIXB-18835"

# --- Preflight ---
require_cmd "acli" "Install the Atlassian CLI: https://github.com/atlassian/acli"
require_auth "acli" "acli auth status" "acli auth login"

# --- Fetch ticket ---
info "Fetching ${TICKET_ID}..."

# Plain text view for readable description
plain_view="$(acli jira workitem view "$TICKET_ID" 2>&1)" \
  || die "Failed to fetch ${TICKET_ID}: $plain_view"

# Extract description (everything after the header fields)
description="$(echo "$plain_view" | sed -n '/^Description:/,$ p' | tail -n +2)"

# --- Fetch structured fields ---
fields="{}"
if [[ "$FETCH_JSON_FIELDS" -eq 1 ]]; then
  fields="$(acli jira workitem view "$TICKET_ID" --fields '*all' --json 2>/dev/null)" || fields="{}"
fi

# --- Optional: comments ---
comments="[]"
if [[ "$FETCH_COMMENTS" -eq 1 ]]; then
  raw_comments="$(acli jira workitem comment list --key "$TICKET_ID" 2>/dev/null)" || raw_comments=""
  if [[ -n "$raw_comments" ]]; then
    # Try to parse as JSON; if acli outputs plain text, wrap it
    if echo "$raw_comments" | jq empty 2>/dev/null; then
      comments="$raw_comments"
    else
      comments="$(echo "$raw_comments" | jq -Rs '[split("\n") | .[] | select(length > 0)]')"
    fi
  fi
fi

# --- Optional: links ---
links="[]"
if [[ "$FETCH_LINKS" -eq 1 ]]; then
  raw_links="$(acli jira workitem link list --key "$TICKET_ID" 2>/dev/null)" || raw_links=""
  if [[ -n "$raw_links" ]]; then
    if echo "$raw_links" | jq empty 2>/dev/null; then
      links="$raw_links"
    else
      links="$(echo "$raw_links" | jq -Rs '[split("\n") | .[] | select(length > 0)]')"
    fi
  fi
fi

# --- Optional: attachments ---
attachments="[]"
if [[ "$FETCH_ATTACHMENTS" -eq 1 ]]; then
  raw_attachments="$(acli jira workitem attachment list --key "$TICKET_ID" 2>/dev/null)" || raw_attachments=""
  if [[ -n "$raw_attachments" ]]; then
    if echo "$raw_attachments" | jq empty 2>/dev/null; then
      attachments="$raw_attachments"
    else
      attachments="$(echo "$raw_attachments" | jq -Rs '[split("\n") | .[] | select(length > 0)]')"
    fi
  fi
fi

# --- Assemble output ---
jq -n \
  --arg ticket_id "$TICKET_ID" \
  --arg plain_view "$plain_view" \
  --arg description "$description" \
  --argjson fields "$fields" \
  --argjson comments "$comments" \
  --argjson links "$links" \
  --argjson attachments "$attachments" \
  '{
    ticket_id: $ticket_id,
    plain_view: $plain_view,
    description: $description,
    fields: $fields,
    comments: $comments,
    links: $links,
    attachments: $attachments
  }'
