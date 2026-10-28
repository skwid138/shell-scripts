#!/usr/bin/env bash
# Build a deterministic local preview of completed manual QA evidence.

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: jira-qa-results-build.sh INPUT.json

Build a version-1 local preview envelope from structured completed-QA evidence.
INPUT.json may be '-' to read one JSON document from stdin. The builder writes
only the envelope to stdout and never calls Jira or writes files.

Examples:
  jira-qa-results-build.sh qa-results.json
  jira-qa-results-build.sh - < qa-results.json
EOF
}

input=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -)
      [[ -z "$input" ]] || die_usage "provide exactly one input document (see --help)"
      input="-"
      shift
      ;;
    -*) die_usage "unknown option: $1 (see --help)" ;;
    *)
      [[ -z "$input" ]] || die_usage "provide exactly one input document (see --help)"
      input="$1"
      shift
      ;;
  esac
done

[[ -n "$input" ]] || die_usage "INPUT.json is required (see --help)"
[[ "$input" == "-" || -r "$input" ]] || die_usage "input file is not readable"

require_cmd "jq"
require_cmd "shasum"

filter="$(dirname "$0")/../data/jira-qa-results.jq"
if [[ "$input" == "-" ]]; then
  if ! rendered="$(jq -s -f "$filter" 2>/dev/null)"; then
    die "invalid QA report input"
  fi
else
  if ! rendered="$(jq -s -f "$filter" "$input" 2>/dev/null)"; then
    die "invalid QA report input"
  fi
fi

if ! attachment_records="$(jq -c '.attachment_handoff[] | select(.local_path != null)' <<<"$rendered" 2>/dev/null)"; then
  die "could not inspect attachment handoff"
fi
if [[ -n "$attachment_records" ]]; then
  while IFS= read -r attachment_record; do
    local_path="$(jq -r '.local_path' <<<"$attachment_record")"
    attachment_id="$(jq -r '.id' <<<"$attachment_record")"
    path_status="unavailable"
    if [[ -f "$local_path" ]]; then
      path_status="verified_existing"
    fi
    if ! rendered="$(jq -c --arg id "$attachment_id" --arg status "$path_status" '
      .attachment_handoff |= map(
        if .id == $id then
          .local_path_status = $status
          | if $status == "unavailable" then del(.local_path) else . end
        else . end
      )
    ' <<<"$rendered" 2>/dev/null)"; then
      die "could not validate attachment handoff"
    fi
  done <<<"$attachment_records"
fi

if ! adf_json="$(jq -cS '.adf' <<<"$rendered" 2>/dev/null)"; then
  die "could not canonicalize generated ADF"
fi
digest="$(printf '%s\n' "$adf_json" | shasum -a 256 | cut -d ' ' -f 1)" ||
  die "could not calculate the ADF digest"

if ! envelope="$(jq -cS --arg digest "$digest" '. + {body_digest: $digest}' <<<"$rendered" 2>/dev/null)"; then
  die "could not assemble preview envelope"
fi
printf '%s\n' "$envelope"
