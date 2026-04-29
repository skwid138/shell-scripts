#!/usr/bin/env bash
# Check OpenCode config for outdated dependencies and unpinned @latest references.
#
# Surfaces checked:
#   - ~/.config/opencode/package.json dependencies
#   - ~/.config/opencode/opencode.json `plugin: [...]` entries
#   - ~/.config/opencode/opencode.json `mcp.<name>.command` arrays (npm packages)
#
# Default output: human-readable table. Use --json for machine output.

# Guard `set -e` to allow library-mode sourcing (for tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
fi

# shellcheck source=../lib/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/common.sh"

# --- Pure helpers (testable) ----------------------------------------------------

# Strip JSONC comments (// and /* */) so jq can parse opencode.json variants.
# Naive but works for typical configs without // inside strings.
strip_jsonc() {
  perl -0pe 's{/\*.*?\*/}{}gs; s{(^|[^:"])//[^\n]*}{$1}g' "$1"
}

# Parse "name@version" strings — handles scoped packages (@scope/name@1.2.3).
# Outputs two lines: name, version (version may be "latest" or empty).
parse_pkg_ref() {
  local ref="$1"
  local name version
  if [[ "$ref" =~ ^(@[^/]+/[^@]+)@(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
  elif [[ "$ref" =~ ^(@[^/]+/[^@]+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    version=""
  elif [[ "$ref" =~ ^([^@]+)@(.+)$ ]]; then
    name="${BASH_REMATCH[1]}"
    version="${BASH_REMATCH[2]}"
  else
    name="$ref"
    version=""
  fi
  printf '%s\n%s\n' "$name" "$version"
}

# Decide if a token from an MCP command array looks like an npm package reference.
# Rejects: empty, flags (-x, --foo), URLs (http:, file:), absolute paths (/),
# command runners (npx, bunx, node, bun), and bare names with no version info.
# Accepts: tokens containing '@' that aren't URLs/paths.
is_npm_pkg_token() {
  local tok="$1"
  [[ -z "$tok" ]] && return 1
  [[ "$tok" =~ ^- ]] && return 1
  [[ "$tok" =~ ^(npx|bunx|node|bun)$ ]] && return 1
  [[ "$tok" =~ ^(https?:|file:|/) ]] && return 1
  [[ "$tok" == *"@"* ]] || return 1
  return 0
}

# Compute textual status for a dependency entry given current/latest/unpinned.
# Outputs one of: ok | OUTDATED | UNPINNED | UNKNOWN
status_for() {
  local current="$1"
  local latest="$2"
  local unpinned="$3"
  if [[ "$unpinned" == "true" ]]; then
    echo "UNPINNED"
  elif [[ -z "$latest" ]]; then
    echo "UNKNOWN"
  elif [[ "$current" == "$latest" ]]; then
    echo "ok"
  else
    echo "OUTDATED"
  fi
}

# If the script is being sourced (e.g. by bats), stop here.
if [[ "${BASH_SOURCE[0]}" != "${0}" ]]; then
  # shellcheck disable=SC2317  # `return` may fail outside sourced context; fallback intentional
  return 0 2>/dev/null || true
fi

# --- Main --------------------------------------------------------------------

OPENCODE_CONFIG_DIR="${OPENCODE_CONFIG_DIR:-$HOME/.config/opencode}"
NPM_VIEW_TIMEOUT="${OPENCODE_DEPS_NPM_TIMEOUT:-15}" # seconds per registry lookup

usage() {
  cat <<'EOF'
Usage: opencode-deps-check [options]

Check OpenCode config for outdated and unpinned dependencies.

Surfaces:
  - package.json dependencies
  - opencode.json `plugin` array entries (e.g. "name@version")
  - opencode.json MCP `command` arrays referencing npm packages
    (e.g. "npx -y pkg@version")

Options:
  --json           Machine-readable JSON output
  --human          Human-readable table (default)
  --config-dir DIR Path to opencode config dir (default: $HOME/.config/opencode)
  -h, --help       Show this help

Environment:
  OPENCODE_CONFIG_DIR        Override default config dir
  OPENCODE_DEPS_NPM_TIMEOUT  Per-package npm registry timeout (default: 15s)

Output (JSON shape):
  {
    "config_dir": "/path/to/.config/opencode",
    "checked_at": "ISO-8601",
    "deps": [
      {
        "package": "@scope/name",
        "current": "1.2.3",          // null if unpinned
        "latest": "1.2.4",            // null if registry lookup failed
        "outdated": true,             // null if unpinned or unknown
        "unpinned": false,
        "location": "package.json:dependencies"
      }
    ],
    "summary": {
      "total": N,
      "outdated": N,
      "unpinned": N,
      "up_to_date": N,
      "unknown": N
    }
  }

Exit codes:
  0  success (regardless of outdated/unpinned counts)
  1  invalid arguments / preflight failure / unrecoverable error

Examples:
  opencode-deps-check                # human table (default)
  opencode-deps-check --json         # JSON output
  opencode-deps-check --json | jq '.deps[] | select(.outdated)'
EOF
}

# --- Parse args ---
FORMAT="human"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --human)
      FORMAT="human"
      shift
      ;;
    --json)
      FORMAT="json"
      shift
      ;;
    --config-dir)
      [[ $# -ge 2 ]] || die "--config-dir requires an argument"
      OPENCODE_CONFIG_DIR="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      die "Unknown option: $1 (try --help)"
      ;;
    *)
      die "Unexpected argument: $1 (try --help)"
      ;;
  esac
done

# --- Preflight: required commands ---
require_cmd "node" "Install Node 24+ (recommended via nvm: nvm install --lts)"
require_cmd "npm" "npm ships with Node.js — reinstall Node if missing"
require_cmd "jq" "Install: brew install jq"
require_cmd "perl" "perl ships with macOS — if missing, install via brew"

# --- Preflight: paths ---
[[ -d "$OPENCODE_CONFIG_DIR" ]] ||
  die "OpenCode config dir not found: $OPENCODE_CONFIG_DIR"

PKG_JSON="$OPENCODE_CONFIG_DIR/package.json"
OC_JSON="$OPENCODE_CONFIG_DIR/opencode.json"

# At least one source must exist; otherwise nothing to do.
if [[ ! -f "$PKG_JSON" && ! -f "$OC_JSON" ]]; then
  die "Neither package.json nor opencode.json found under $OPENCODE_CONFIG_DIR"
fi

# Validate package.json JSON early
if [[ -f "$PKG_JSON" ]]; then
  jq empty "$PKG_JSON" 2>/dev/null ||
    die "package.json is not valid JSON: $PKG_JSON"
fi

# Validate opencode.json JSONC (after stripping comments)
oc_clean=""
if [[ -f "$OC_JSON" ]]; then
  if ! oc_clean="$(strip_jsonc "$OC_JSON")"; then
    die "Failed to strip comments from opencode.json: $OC_JSON"
  fi
  if ! echo "$oc_clean" | jq empty 2>/dev/null; then
    die "opencode.json is not valid JSON (after JSONC strip): $OC_JSON"
  fi
fi

# --- npm registry lookup with timeout ---
npm_latest_version() {
  local pkg="$1"
  # Use a wrapper command compatible with both BSD/macOS and GNU systems.
  # macOS doesn't have GNU `timeout` by default; prefer it when present, else
  # fall back to plain npm view (npm itself respects fetch-timeout configs).
  if command -v timeout >/dev/null 2>&1; then
    timeout "${NPM_VIEW_TIMEOUT}s" npm view "$pkg" version 2>/dev/null || echo ""
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout "${NPM_VIEW_TIMEOUT}s" npm view "$pkg" version 2>/dev/null || echo ""
  else
    npm view "$pkg" version 2>/dev/null || echo ""
  fi
}

# --- Collect dependency entries ---
# Each entry: TAB-separated name<TAB>version<TAB>location

entries=""

# 1. package.json dependencies
if [[ -f "$PKG_JSON" ]]; then
  while IFS=$'\t' read -r name version; do
    [[ -z "$name" ]] && continue
    entries+="${name}"$'\t'"${version}"$'\t'"package.json:dependencies"$'\n'
  done < <(jq -r '.dependencies // {} | to_entries[] | "\(.key)\t\(.value)"' "$PKG_JSON")
fi

# 2 & 3. opencode.json
if [[ -n "$oc_clean" ]]; then
  # plugin array
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    parsed="$(parse_pkg_ref "$ref")"
    name="$(echo "$parsed" | sed -n '1p')"
    version="$(echo "$parsed" | sed -n '2p')"
    entries+="${name}"$'\t'"${version}"$'\t'"opencode.json:plugin"$'\n'
  done < <(echo "$oc_clean" | jq -r '.plugin // [] | .[] | if type=="string" then . else .[0] end')

  # MCP commands
  while IFS=$'\t' read -r mcp_name token; do
    is_npm_pkg_token "$token" || continue
    parsed="$(parse_pkg_ref "$token")"
    name="$(echo "$parsed" | sed -n '1p')"
    version="$(echo "$parsed" | sed -n '2p')"
    [[ -z "$name" ]] && continue
    entries+="${name}"$'\t'"${version}"$'\t'"opencode.json:mcp.${mcp_name}.command"$'\n'
  done < <(echo "$oc_clean" | jq -r '.mcp // {} | to_entries[] | .key as $k | (.value.command // [])[] | "\($k)\t\(.)"')
fi

# --- Resolve latest versions ---

results_json="[]"
total=0
outdated_count=0
unpinned_count=0
up_to_date_count=0
unknown_count=0
lookup_failures=0

while IFS=$'\t' read -r name version location; do
  [[ -z "$name" ]] && continue
  total=$((total + 1))

  unpinned="false"
  current_json="null"
  if [[ -z "$version" || "$version" == "latest" ]]; then
    unpinned="true"
    unpinned_count=$((unpinned_count + 1))
  else
    current_json="\"$version\""
  fi

  latest="$(npm_latest_version "$name")"
  if [[ -z "$latest" ]]; then
    latest_json="null"
    outdated="null"
    lookup_failures=$((lookup_failures + 1))
    if [[ "$unpinned" != "true" ]]; then
      unknown_count=$((unknown_count + 1))
    fi
  else
    latest_json="\"$latest\""
    if [[ "$unpinned" == "true" ]]; then
      outdated="null"
    elif [[ "$version" == "$latest" ]]; then
      outdated="false"
      up_to_date_count=$((up_to_date_count + 1))
    else
      outdated="true"
      outdated_count=$((outdated_count + 1))
    fi
  fi

  unpinned_bool="false"
  [[ "$unpinned" == "true" ]] && unpinned_bool="true"

  entry="$(jq -n \
    --arg pkg "$name" \
    --argjson current "$current_json" \
    --argjson latest "$latest_json" \
    --argjson outdated "$outdated" \
    --argjson unpinned "$unpinned_bool" \
    --arg location "$location" \
    '{package: $pkg, current: $current, latest: $latest, outdated: $outdated, unpinned: $unpinned, location: $location}')"

  results_json="$(jq --argjson e "$entry" '. + [$e]' <<<"$results_json")"
done <<<"$entries"

# Warn (to stderr) if any registry lookups failed — does not affect exit code.
if [[ "$lookup_failures" -gt 0 ]]; then
  warn "$lookup_failures package(s) could not be resolved against the npm registry (timeout or network error)."
fi

# --- Output ---

checked_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

final_json="$(jq -n \
  --arg dir "$OPENCODE_CONFIG_DIR" \
  --arg ts "$checked_at" \
  --argjson deps "$results_json" \
  --argjson total "$total" \
  --argjson outdated "$outdated_count" \
  --argjson unpinned "$unpinned_count" \
  --argjson up_to_date "$up_to_date_count" \
  --argjson unknown "$unknown_count" \
  '{
    config_dir: $dir,
    checked_at: $ts,
    deps: $deps,
    summary: {
      total: $total,
      outdated: $outdated,
      unpinned: $unpinned,
      up_to_date: $up_to_date,
      unknown: $unknown
    }
  }')"

if [[ "$FORMAT" == "json" ]]; then
  echo "$final_json"
  exit 0
fi

# Human format: table
echo ""
echo "OpenCode dependency check — $checked_at"
echo "Config: $OPENCODE_CONFIG_DIR"
echo ""
printf "%-40s %-12s %-12s %-10s %s\n" "PACKAGE" "CURRENT" "LATEST" "STATUS" "LOCATION"
printf "%-40s %-12s %-12s %-10s %s\n" \
  "----------------------------------------" \
  "------------" "------------" "----------" \
  "----------------------------------------"

jq -r '.deps[] |
  [
    .package,
    (.current // "(unpinned)"),
    (.latest // "?"),
    (if .unpinned then "UNPINNED"
     elif .latest == null then "UNKNOWN"
     elif .outdated == true then "OUTDATED"
     elif .outdated == false then "ok"
     else "?" end),
    .location
  ] | @tsv' <<<"$final_json" | while IFS=$'\t' read -r pkg cur lat status loc; do
  color=""
  case "$status" in
    OUTDATED) color="${YELLOW}" ;;
    UNPINNED) color="${RED}" ;;
    UNKNOWN) color="${YELLOW}" ;;
    ok) color="${GREEN}" ;;
  esac
  printf "%-40s %-12s %-12s %b%-10s%b %s\n" "$pkg" "$cur" "$lat" "$color" "$status" "${NC}" "$loc"
done

echo ""
echo "Summary: ${total} total | ${outdated_count} outdated | ${unpinned_count} unpinned | ${up_to_date_count} up-to-date | ${unknown_count} unknown"
echo ""
