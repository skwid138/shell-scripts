#!/usr/bin/env bash
# bq.sh — BigQuery wrapper that resolves project via gcp-project-map.sh.
#
# Why this exists:
#   The `bq` CLI requires --project_id on every invocation. Memorizing the
#   right project for "tst" vs "prd" vs "stg" data is friction. This script
#   accepts a friendly env name, resolves it to a project ID by shelling out
#   to ~/code/wpromote/scripts/agent/gcp-project-map.sh (the canonical
#   single-source-of-truth resolver), and runs bq with sensible defaults:
#     --use_legacy_sql=false  (Standard SQL)
#     --format=pretty         (human-readable output)
#
# Cross-repo coupling:
#   This is the public-layer (~/code/scripts) shelling out to the private
#   wpromote-layer resolver. The boundary is process-level: we exec a
#   sibling script, never source-couple. If the wpromote repo isn't cloned,
#   we exit 3 with a helpful pointer instead of crashing.
#
# Subcommands (mutually exclusive; default is raw SQL passthrough):
#   bq.sh --env <env> "<sql>"                            Run SQL.
#   bq.sh --env <env> --table-info <pat> --dataset <ds>  COLUMN_FIELD_PATHS query.
#   bq.sh --env <env> --last-modified <tbl> --dataset <ds>  __TABLES__ lookup.
#   bq.sh --env <env> --schema <tbl> --dataset <ds>      `bq show --schema`.
#   bq.sh --list-envs                                    Print known envs.
#
# Override hooks (mainly for tests):
#   GCP_PROJECT_MAP   Path to gcp-project-map.sh (defaults to wpromote location).
#   BQ_BIN            Path to bq binary (defaults to `bq` on PATH).
#
# Exit codes (via lib/common.sh):
#   1 die, 2 die_usage, 3 die_missing_dep, 4 die_unauthed, 5 die_upstream
set -uo pipefail
# shellcheck source=/Users/hunter/code/scripts/lib/common.sh
source "$HOME/code/scripts/lib/common.sh"

# Default location of the wpromote-layer project resolver. Test harnesses
# (and any future relocation) can override via GCP_PROJECT_MAP.
GCP_PROJECT_MAP="${GCP_PROJECT_MAP:-$HOME/code/wpromote/scripts/agent/gcp-project-map.sh}"
BQ_BIN="${BQ_BIN:-bq}"

usage() {
  cat <<'EOF'
Usage: bq.sh --env <env> [options] [SQL]
       bq.sh --list-envs
       bq.sh --help

Wraps `bq` so you don't have to remember project IDs. Resolves <env>
(e.g. dev, tst, stg, prd) to a BigQuery project ID via the canonical
gcp-project-map.sh resolver in ~/code/wpromote/scripts.

Modes (mutually exclusive; default is "run SQL"):
  --env ENV "SQL"                Run SQL with --use_legacy_sql=false.
  --env ENV --table-info PATTERN --dataset DS
                                 List columns matching PATTERN in DS via
                                 INFORMATION_SCHEMA.COLUMN_FIELD_PATHS.
  --env ENV --last-modified TBL --dataset DS
                                 Show last-modified time for TBL in DS via
                                 __TABLES__.
  --env ENV --schema TBL --dataset DS
                                 Print TBL's schema (`bq show --schema`).
  --list-envs                    List all known env values from the yaml.

Options:
  --env ENV          BQ env (dev | tst | stg | prd | ...).
  --dataset DS       BigQuery dataset (required for --table-info /
                     --last-modified / --schema).
  --format FMT       Output format passed to bq query (default: pretty).
                     Ignored by --schema (which uses `bq show`).
  -h, --help         Show this help.

Examples:
  bq.sh --env tst "SELECT 1"
  bq.sh --env tst --schema all_clients --dataset all_clients
  bq.sh --env prd --last-modified clients --dataset all_clients
  bq.sh --env dev --table-info '%client_id%' --dataset all_clients

Notes:
  - Requires ~/code/wpromote/scripts cloned (provides gcp-project-map.sh).
  - Requires `bq` (Google Cloud SDK) on PATH and `gcloud auth login`.
  - Aliased as `bqx` in shell/aliases.sh.
EOF
}

# --- Arg parsing -----------------------------------------------------------

ENV_NAME=""
DATASET=""
FORMAT="pretty"
MODE="" # "" | sql | table-info | last-modified | schema | list-envs
ARG=""  # value associated with the chosen mode (sql text, table name, pattern)

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --list-envs)
      [[ -z "$MODE" ]] || die_usage "--list-envs is mutually exclusive with other modes"
      MODE="list-envs"
      shift
      ;;
    --env)
      [[ $# -ge 2 ]] || die_usage "--env requires an argument"
      ENV_NAME="$2"
      shift 2
      ;;
    --dataset)
      [[ $# -ge 2 ]] || die_usage "--dataset requires an argument"
      DATASET="$2"
      shift 2
      ;;
    --format)
      [[ $# -ge 2 ]] || die_usage "--format requires an argument"
      FORMAT="$2"
      shift 2
      ;;
    --table-info)
      [[ $# -ge 2 ]] || die_usage "--table-info requires a PATTERN"
      [[ -z "$MODE" ]] || die_usage "Mode flags are mutually exclusive (--table-info / --last-modified / --schema)"
      MODE="table-info"
      ARG="$2"
      shift 2
      ;;
    --last-modified)
      [[ $# -ge 2 ]] || die_usage "--last-modified requires a TABLE"
      [[ -z "$MODE" ]] || die_usage "Mode flags are mutually exclusive"
      MODE="last-modified"
      ARG="$2"
      shift 2
      ;;
    --schema)
      [[ $# -ge 2 ]] || die_usage "--schema requires a TABLE"
      [[ -z "$MODE" ]] || die_usage "Mode flags are mutually exclusive"
      MODE="schema"
      ARG="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die_usage "Unknown option: $1"
      ;;
    *)
      # Positional = raw SQL.
      [[ -z "$MODE" ]] || die_usage "Unexpected positional after mode flag: $1"
      MODE="sql"
      ARG="$1"
      shift
      ;;
  esac
done

# --- Resolver preflight ----------------------------------------------------

[[ -x "$GCP_PROJECT_MAP" ]] || die_missing_dep \
  "gcp-project-map.sh not found or not executable: $GCP_PROJECT_MAP
Clone https://github.com/wpromote/scripts (or set GCP_PROJECT_MAP)."

# --- list-envs (no project resolution needed) -------------------------------

if [[ "$MODE" == "list-envs" ]]; then
  exec "$GCP_PROJECT_MAP" --list-envs
fi

# --- Validate args for env-bound modes --------------------------------------

[[ -n "$ENV_NAME" ]] || {
  usage >&2
  die_usage "Missing --env"
}

if [[ -z "$MODE" ]]; then
  usage >&2
  die_usage "No SQL or mode flag provided. Pass SQL, --table-info, --last-modified, --schema, or --list-envs."
fi

case "$MODE" in
  table-info | last-modified | schema)
    [[ -n "$DATASET" ]] || die_usage "--$MODE requires --dataset"
    ;;
esac

# --- Resolve project --------------------------------------------------------

PROJECT="$("$GCP_PROJECT_MAP" --bq "$ENV_NAME")" ||
  die "Failed to resolve BQ project for env '$ENV_NAME' (gcp-project-map exit $?)"
[[ -n "$PROJECT" ]] || die "Empty project ID returned for env '$ENV_NAME'"

# --- Tool preflight (after resolution so resolver-only modes don't need bq) ---

require_cmd "$BQ_BIN" "Install: brew install --cask google-cloud-sdk"

info "BQ env=$ENV_NAME project=$PROJECT mode=$MODE"

# --- Dispatch ---------------------------------------------------------------

run_query() {
  local sql="$1"
  "$BQ_BIN" --project_id="$PROJECT" query \
    --use_legacy_sql=false \
    --format="$FORMAT" \
    "$sql"
}

case "$MODE" in
  sql)
    run_query "$ARG"
    ;;
  table-info)
    # ARG is a LIKE pattern (column path). Schema lives in dataset's
    # INFORMATION_SCHEMA. Backticked dataset to allow hyphens.
    run_query "
      SELECT table_name, column_name, field_path, data_type
      FROM \`${PROJECT}.${DATASET}.INFORMATION_SCHEMA.COLUMN_FIELD_PATHS\`
      WHERE field_path LIKE '${ARG}'
      ORDER BY table_name, field_path
    "
    ;;
  last-modified)
    run_query "
      SELECT
        table_id,
        TIMESTAMP_MILLIS(last_modified_time) AS last_modified
      FROM \`${PROJECT}.${DATASET}.__TABLES__\`
      WHERE table_id = '${ARG}'
    "
    ;;
  schema)
    "$BQ_BIN" --project_id="$PROJECT" show --schema --format=prettyjson \
      "${PROJECT}:${DATASET}.${ARG}"
    ;;
  *)
    die "Internal error: unhandled mode '$MODE'"
    ;;
esac
