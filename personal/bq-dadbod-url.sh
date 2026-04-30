#!/usr/bin/env bash
# bq-dadbod-url.sh — emit a vim-dadbod BigQuery connection URL.
#
# Used by dadbod-ui inside Neovim:
#   :DBUI                  → picks from g:dbs
#   g:dbs entries are populated from this script's output.
#
# Output format:  bigquery://<project>/<dataset>
#
# Resolves <project> by shelling out to gcp-project-map.sh (canonical SSOT),
# matching the same boundary discipline as bq.sh.
#
# Override hook (mainly for tests):
#   GCP_PROJECT_MAP   Path to gcp-project-map.sh.
#
# Exit codes (via lib/common.sh):
#   1 die, 2 die_usage, 3 die_missing_dep
set -uo pipefail
# shellcheck source=/Users/hunter/code/scripts/lib/common.sh
source "$HOME/code/scripts/lib/common.sh"

GCP_PROJECT_MAP="${GCP_PROJECT_MAP:-$HOME/code/wpromote/scripts/agent/gcp-project-map.sh}"

usage() {
  cat <<'EOF'
Usage: bq-dadbod-url.sh <env> <dataset>
       bq-dadbod-url.sh --help

Print a vim-dadbod BigQuery URL for <env> + <dataset>:
  bigquery://<project>/<dataset>

<env> is resolved to a BQ project ID via gcp-project-map.sh.

Examples:
  bq-dadbod-url.sh tst all_clients
  # → bigquery://prj-npd-plrs-tst-data-szm2/all_clients

  bq-dadbod-url.sh prd kraken_metadata
  # → bigquery://prj-prd-plrs-data-m5xx/kraken_metadata
EOF
}

ENV_NAME=""
DATASET=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die_usage "Unknown option: $1"
      ;;
    *)
      if [[ -z "$ENV_NAME" ]]; then
        ENV_NAME="$1"
      elif [[ -z "$DATASET" ]]; then
        DATASET="$1"
      else
        die_usage "Unexpected argument: $1"
      fi
      shift
      ;;
  esac
done

[[ -n "$ENV_NAME" ]] || {
  usage >&2
  die_usage "Missing <env>"
}
[[ -n "$DATASET" ]] || {
  usage >&2
  die_usage "Missing <dataset>"
}

[[ -x "$GCP_PROJECT_MAP" ]] || die_missing_dep \
  "gcp-project-map.sh not found or not executable: $GCP_PROJECT_MAP
Clone https://github.com/wpromote/scripts (or set GCP_PROJECT_MAP)."

PROJECT="$("$GCP_PROJECT_MAP" --bq "$ENV_NAME")" ||
  die "Failed to resolve BQ project for env '$ENV_NAME' (gcp-project-map exit $?)"
[[ -n "$PROJECT" ]] || die "Empty project ID returned for env '$ENV_NAME'"

printf 'bigquery://%s/%s\n' "$PROJECT" "$DATASET"
