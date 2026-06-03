#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: gh-label-sync [--apply] skwid138/repo [skwid138/repo2 ...]

Converge GitHub labels on skwid138-owned repos to data/github-labels.yml.
Dry-run is the default; --apply is required for create/edit/rename/delete.

Options:
  --apply     Apply planned label mutations. Without this, only report actions.
  -h, --help  Show this help.

Environment:
  GH_LABEL_SYNC_MANIFEST  Override manifest path (default: ../data/github-labels.yml).

Output:
  JSON on stdout with top-level {"version":1,"repos":[...]}.
EOF
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

normalize_color() {
  local color="$1"
  color="${color#\#}"
  lower "$color"
}

bare_color() { normalize_color "$1"; }

json_string() {
  jq -Rn --arg s "$1" '$s'
}

desired_labels_jq() {
  jq -c '.axes | to_entries[] | .key as $axis | .value[] | {axis:$axis,name:.name,color:.color,description:.description}' "$MANIFEST_JSON"
}

add_error() {
  local errors_file="$1" message="$2"
  json_string "$message" >>"$errors_file"
}

add_action() {
  local actions_file="$1"
  local label="$2" axis="$3" action="$4" from="$5" to="$6" color="$7" reason="$8" applied="$9"

  jq -cn \
    --arg label "$label" \
    --arg axis "$axis" \
    --arg action "$action" \
    --arg from "$from" \
    --arg to "$to" \
    --arg color "$color" \
    --arg reason "$reason" \
    --argjson applied "$applied" \
    '{
      label: $label,
      axis: (if $axis == "" then null else $axis end),
      action: $action,
      from: (if $from == "" then null else $from end),
      to: (if $to == "" then null else $to end),
      color: (if $color == "" then null else $color end),
      reason: $reason,
      applied: $applied
    }' >>"$actions_file"
}

existing_display_name() {
  local labels_file="$1" wanted_norm="$2"
  jq -r --arg n "$wanted_norm" 'map(select((.name | ascii_downcase) == $n))[0].name // empty' "$labels_file"
}

existing_color() {
  local labels_file="$1" wanted_norm="$2"
  jq -r --arg n "$wanted_norm" 'map(select((.name | ascii_downcase) == $n))[0].color // ""' "$labels_file"
}

existing_description() {
  local labels_file="$1" wanted_norm="$2"
  jq -r --arg n "$wanted_norm" 'map(select((.name | ascii_downcase) == $n))[0].description // ""' "$labels_file"
}

planned_rename_target() {
  local actions_file="$1" wanted_norm="$2"
  jq -e --arg n "$wanted_norm" 'select(.action == "rename" and (.to | ascii_downcase) == $n)' "$actions_file" >/dev/null 2>&1
}

desired_meta_for_name() {
  local wanted_norm="$1"
  jq -c --arg n "$wanted_norm" '.axes | to_entries[] | .key as $axis | .value[] | select((.name | ascii_downcase) == $n) | {axis:$axis,name:.name,color:.color,description:.description}' "$MANIFEST_JSON"
}

validate_repo_slug() {
  local slug="$1" owner repo
  [[ -n "$slug" ]] || die_usage "repo slug is required"
  [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die_usage "invalid repo slug '$slug'; expected skwid138/repo"
  [[ "$slug" != *.git ]] || die_usage "invalid repo slug '$slug'; .git suffix is not allowed"
  owner="${slug%%/*}"
  repo="${slug#*/}"
  [[ "$owner" == "skwid138" ]] || die_usage "refusing repo '$slug'; owner must be skwid138"
  [[ -n "$repo" ]] || die_usage "repo name is required in '$slug'"
}

check_yq_flavor() {
  local version
  version="$(yq --version 2>&1)" || die_missing_dep "'yq' is required. Install mikefarah yq: brew install yq"
  case "$version" in
    *mikefarah* | *github.com/mikefarah/yq* | *mikefarah/yq*) return 0 ;;
    *) die_missing_dep "mikefarah yq v4 is required. Install: brew install yq" ;;
  esac
}

validate_manifest() {
  local file="$1" invalid_target invalid_target_json

  jq -e '
    (.axes | type == "object") and
    (.migrations | type == "array") and
    (.keep | type == "array") and
    (.delete | type == "array")
  ' "$file" >/dev/null || die_usage "manifest must contain axes, migrations, keep, and delete"

  jq -e '
    [ .axes | to_entries[] | .value[] | select((.name|type != "string") or (.color|type != "string") or (.description|type != "string")) ] | length == 0
  ' "$file" >/dev/null || die_usage "manifest desired labels require name, color, and description strings"

  jq -e '
    [ .axes | to_entries[] | .value[] | select(.color | test("^#[0-9A-Fa-f]{6}$") | not) ] | length == 0
  ' "$file" >/dev/null || die_usage "manifest colors must be #rrggbb hex values"

  jq -e '
    def names: [.axes | to_entries[] | .value[] | .name | ascii_downcase];
    (names | length) == (names | unique | length)
  ' "$file" >/dev/null || die_usage "manifest has duplicate desired label names"

  jq -e '
    [ (.keep[], .delete[]) | select(type != "string") ] | length == 0
  ' "$file" >/dev/null || die_usage "manifest keep and delete entries must be strings"

  jq -e '
    [ .migrations[] | select((.old|type != "string") or (.new|type != "string") or ((.old|ascii_downcase) == (.new|ascii_downcase))) ] | length == 0
  ' "$file" >/dev/null || die_usage "manifest migrations must have distinct old/new strings"

  invalid_target_json="$(jq -c '
    [.axes | to_entries[] | .value[] | .name | ascii_downcase] as $desired |
    [.migrations[] | select((.new | ascii_downcase) as $new | ($desired | index($new) | not)) | .new][0] // null
  ' "$file")"
  if [[ "$invalid_target_json" != "null" ]]; then
    invalid_target="$(printf '%s' "$invalid_target_json" | jq -r '.')"
    die_usage "manifest migration target '$invalid_target' is not a defined desired label"
  fi

  jq -e '
    def desired: [.axes | to_entries[] | .value[] | .name | ascii_downcase];
    def keep: [.keep[] | ascii_downcase];
    def del: [.delete[] | ascii_downcase];
    ((desired + keep + del) | length) == ((desired + keep + del) | unique | length)
  ' "$file" >/dev/null || die_usage "manifest desired, keep, and delete sections must not overlap"

  jq -e '
    (.delete | map(ascii_downcase)) as $del |
    (.keep | map(ascii_downcase)) as $keep |
    ([.migrations[] | (.old, .new) | ascii_downcase]) as $mig |
    ([$del[] as $d | select(($keep + $mig) | index($d))] | length) == 0
  ' "$file" >/dev/null || die_usage "manifest delete entries must not overlap keep or migrations"

  jq -e '
    (.keep | map(ascii_downcase)) as $keep |
    ([.migrations[] | .old | ascii_downcase]) as $migration_old |
    ([$keep[] as $k | select($migration_old | index($k))] | length) == 0
  ' "$file" >/dev/null || die_usage "manifest keep entries must not also be migration sources"
}

load_manifest() {
  local manifest_path="$1"
  [[ -f "$manifest_path" ]] || die "manifest not found: $manifest_path (set GH_LABEL_SYNC_MANIFEST to override)"
  MANIFEST_JSON="$(mktemp)"
  TMP_FILES="$TMP_FILES $MANIFEST_JSON"
  if ! yq eval -o=json "$manifest_path" >"$MANIFEST_JSON" 2>"$YQ_ERR"; then
    die_usage "failed to parse manifest '$manifest_path': $(cat "$YQ_ERR")"
  fi
  validate_manifest "$MANIFEST_JSON"
}

graphql_response_clean() {
  local json="$1"
  printf '%s' "$json" | jq -e 'if has("errors") then (.errors | type == "array" and length == 0) else true end' >/dev/null 2>&1
}

delete_guard() {
  local slug="$1" label="$2" owner repo discussions_json counts_json issues prs discussions discussions_err counts_err rc
  owner="${slug%%/*}"
  repo="${slug#*/}"
  DELETE_GUARD_STATUS="blocked"
  DELETE_GUARD_REASON="delete safety unknown"
  DELETE_GUARD_ISSUES="unknown"
  DELETE_GUARD_PRS="unknown"

  discussions_err="$(mktemp)"
  TMP_FILES="$TMP_FILES $discussions_err"
  discussions_json="$(gh api graphql -F owner="$owner" -F repo="$repo" -f query='query($owner:String!,$repo:String!){repository(owner:$owner,name:$repo){hasDiscussionsEnabled}}' 2>"$discussions_err")"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    DELETE_GUARD_REASON="could not determine Discussions status: $(cat "$discussions_err")"
    return 0
  fi
  if ! graphql_response_clean "$discussions_json"; then
    DELETE_GUARD_REASON="GraphQL returned errors; delete safety unknown"
    return 0
  fi
  discussions="$(printf '%s' "$discussions_json" | jq -r 'if .data.repository.hasDiscussionsEnabled == false then "false" elif .data.repository.hasDiscussionsEnabled == true then "true" else "unknown" end' 2>/dev/null || printf '%s' unknown)"
  if [[ "$discussions" != "false" ]]; then
    DELETE_GUARD_REASON="delete cannot be proven safe because Discussions are enabled or unknown"
    return 0
  fi

  counts_err="$(mktemp)"
  TMP_FILES="$TMP_FILES $counts_err"
  # totalCount includes all states (open+closed issues, open+merged PRs), which delete safety relies on.
  counts_json="$(gh api graphql -F owner="$owner" -F repo="$repo" -F name="$label" -f query='query($owner:String!,$repo:String!,$name:String!){repository(owner:$owner,name:$repo){label(name:$name){issues{totalCount} pullRequests{totalCount}}}}' 2>"$counts_err")"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    DELETE_GUARD_REASON="could not determine label associations: $(cat "$counts_err")"
    return 0
  fi
  if ! graphql_response_clean "$counts_json"; then
    DELETE_GUARD_REASON="GraphQL returned errors; delete safety unknown"
    return 0
  fi
  issues="$(printf '%s' "$counts_json" | jq -r '.data.repository.label.issues.totalCount // "unknown"' 2>/dev/null || printf '%s' unknown)"
  prs="$(printf '%s' "$counts_json" | jq -r '.data.repository.label.pullRequests.totalCount // "unknown"' 2>/dev/null || printf '%s' unknown)"
  DELETE_GUARD_ISSUES="$issues"
  DELETE_GUARD_PRS="$prs"
  if [[ "$issues" =~ ^[0-9]+$ && "$prs" =~ ^[0-9]+$ && "$issues" -eq 0 && "$prs" -eq 0 ]]; then
    DELETE_GUARD_STATUS="safe"
    DELETE_GUARD_REASON="zero issue/PR associations and Discussions disabled"
  else
    DELETE_GUARD_REASON="label has nonzero or unknown associations (issues=$issues, prs=$prs)"
  fi
}

mutation_failed() {
  local errors_file="$1" message="$2"
  add_error "$errors_file" "$message"
  HAD_ERRORS=1
}

plan_delete() {
  local slug="$1" labels_file="$2" actions_file="$3" errors_file="$4" name display reason out
  while IFS= read -r name; do
    display="$(existing_display_name "$labels_file" "$(lower "$name")")"
    if [[ -z "$display" ]]; then
      add_action "$actions_file" "$name" "" "skip" "" "" "" "delete candidate absent" false
      continue
    fi
    delete_guard "$slug" "$display"
    if [[ "$DELETE_GUARD_STATUS" == "safe" ]]; then
      reason="$DELETE_GUARD_REASON"
      if [[ "$APPLY" == "1" ]]; then
        if out="$(gh label delete "$display" -R "$slug" --yes 2>&1)"; then
          add_action "$actions_file" "$display" "" "delete" "" "" "" "$reason" true
        else
          add_action "$actions_file" "$display" "" "delete" "" "" "" "$reason" false
          mutation_failed "$errors_file" "delete '$display' failed: $out"
        fi
      else
        add_action "$actions_file" "$display" "" "would-delete" "" "" "" "$reason" false
      fi
    else
      add_action "$actions_file" "$display" "" "delete-blocked" "" "" "" "$DELETE_GUARD_REASON" false
    fi
  done < <(jq -r '.delete[]' "$MANIFEST_JSON")
}

association_summary() {
  local slug="$1" label="$2"
  delete_guard "$slug" "$label"
  printf 'issues=%s prs=%s' "$DELETE_GUARD_ISSUES" "$DELETE_GUARD_PRS"
}

plan_migrations() {
  local slug="$1" labels_file="$2" actions_file="$3" errors_file="$4"
  local migration old new old_display new_display new_norm meta axis color desc bare reason out old_counts new_counts
  while IFS= read -r migration; do
    old="$(printf '%s' "$migration" | jq -r '.old')"
    new="$(printf '%s' "$migration" | jq -r '.new')"
    old_display="$(existing_display_name "$labels_file" "$(lower "$old")")"
    new_norm="$(lower "$new")"
    new_display="$(existing_display_name "$labels_file" "$new_norm")"
    if [[ -n "$old_display" && -z "$new_display" ]]; then
      meta="$(desired_meta_for_name "$new_norm")"
      axis="$(printf '%s' "$meta" | jq -r '.axis')"
      color="$(printf '%s' "$meta" | jq -r '.color')"
      desc="$(printf '%s' "$meta" | jq -r '.description')"
      bare="$(bare_color "$color")"
      reason="rename legacy label in place to preserve associations"
      if [[ "$APPLY" == "1" ]]; then
        if out="$(gh label edit "$old_display" -R "$slug" --name "$new" --color "$bare" --description "$desc" 2>&1)"; then
          add_action "$actions_file" "$new" "$axis" "rename" "$old_display" "$new" "$color" "$reason" true
        else
          add_action "$actions_file" "$new" "$axis" "rename" "$old_display" "$new" "$color" "$reason" false
          mutation_failed "$errors_file" "rename '$old_display' to '$new' failed: $out"
        fi
      else
        add_action "$actions_file" "$new" "$axis" "rename" "$old_display" "$new" "$color" "$reason" false
      fi
    elif [[ -n "$old_display" && -n "$new_display" ]]; then
      old_counts="$(association_summary "$slug" "$old_display")"
      new_counts="$(association_summary "$slug" "$new_display")"
      reason="collision: legacy '$old_display' ($old_counts) and target '$new_display' ($new_counts) both exist; manual cleanup required"
      add_action "$actions_file" "$new" "" "collision" "$old_display" "$new_display" "" "$reason" false
    elif [[ -z "$old_display" && -n "$new_display" ]]; then
      add_action "$actions_file" "$new" "" "skip" "$old" "$new_display" "" "migration already applied" false
    fi
  done < <(jq -c '.migrations[]' "$MANIFEST_JSON")
}

plan_desired() {
  local slug="$1" labels_file="$2" actions_file="$3" errors_file="$4"
  local item axis name color desc norm display api_color api_desc bare reason out action applied
  while IFS= read -r item; do
    axis="$(printf '%s' "$item" | jq -r '.axis')"
    name="$(printf '%s' "$item" | jq -r '.name')"
    color="$(printf '%s' "$item" | jq -r '.color')"
    desc="$(printf '%s' "$item" | jq -r '.description')"
    norm="$(lower "$name")"
    if planned_rename_target "$actions_file" "$norm"; then
      add_action "$actions_file" "$name" "$axis" "skip" "" "$name" "$color" "covered by planned rename" false
      continue
    fi
    display="$(existing_display_name "$labels_file" "$norm")"
    bare="$(bare_color "$color")"
    if [[ -z "$display" ]]; then
      reason="desired label missing"
      if [[ "$APPLY" == "1" ]]; then
        if out="$(gh label create "$name" -R "$slug" --color "$bare" --description "$desc" 2>&1)"; then
          add_action "$actions_file" "$name" "$axis" "create" "" "$name" "$color" "$reason" true
        else
          add_action "$actions_file" "$name" "$axis" "create" "" "$name" "$color" "$reason" false
          mutation_failed "$errors_file" "create '$name' failed: $out"
        fi
      else
        add_action "$actions_file" "$name" "$axis" "create" "" "$name" "$color" "$reason" false
      fi
      continue
    fi

    api_color="$(existing_color "$labels_file" "$norm")"
    api_desc="$(existing_description "$labels_file" "$norm")"
    if [[ "$display" == "$name" && "$(normalize_color "$api_color")" == "$bare" && "$api_desc" == "$desc" ]]; then
      add_action "$actions_file" "$name" "$axis" "skip" "" "$display" "$color" "desired label already correct" false
    else
      reason="desired label color, description, or display casing differs"
      action="edit"
      applied=false
      if [[ "$APPLY" == "1" ]]; then
        if out="$(gh label edit "$display" -R "$slug" --name "$name" --color "$bare" --description "$desc" 2>&1)"; then
          applied=true
        else
          mutation_failed "$errors_file" "edit '$display' failed: $out"
        fi
      fi
      add_action "$actions_file" "$name" "$axis" "$action" "$display" "$name" "$color" "$reason" "$applied"
    fi
  done < <(desired_labels_jq)
}

process_repo() {
  local slug="$1" labels_file actions_file errors_file out count repo_obj list_err rc
  labels_file="$(mktemp)"
  actions_file="$(mktemp)"
  errors_file="$(mktemp)"
  list_err="$(mktemp)"
  TMP_FILES="$TMP_FILES $labels_file $actions_file $errors_file $list_err"

  out="$(gh label list -R "$slug" --json name,color,description --limit 1000 2>"$list_err")"
  rc=$?
  if [[ "$rc" -ne 0 ]]; then
    add_error "$errors_file" "gh label list failed: $(cat "$list_err")"
    HAD_ERRORS=1
  elif ! printf '%s' "$out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    add_error "$errors_file" "gh label list returned unexpected non-array output"
    HAD_ERRORS=1
  else
    printf '%s' "$out" >"$labels_file"
    count="$(jq 'length' "$labels_file")"
    if [[ "$count" == "1000" ]]; then
      warn "${slug}: gh label list returned exactly 1000 labels; results may be truncated"
    fi
    plan_delete "$slug" "$labels_file" "$actions_file" "$errors_file"
    plan_migrations "$slug" "$labels_file" "$actions_file" "$errors_file"
    plan_desired "$slug" "$labels_file" "$actions_file" "$errors_file"
  fi

  repo_obj="$(jq -n \
    --arg repo "$slug" \
    --slurpfile actions "$actions_file" \
    --slurpfile errors "$errors_file" \
    '{repo:$repo, actions:$actions, errors:$errors}')"
  printf '%s\n' "$repo_obj" >>"$REPOS_FILE"
}

cleanup() {
  local f
  for f in $TMP_FILES; do
    [[ -n "$f" && -e "$f" ]] && rm -f "$f"
  done
}

main() {
  APPLY=0
  REPOS=()
  TMP_FILES=""
  HAD_ERRORS=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --apply)
        APPLY=1
        shift
        ;;
      -*)
        die_usage "unknown option: $1"
        ;;
      *)
        REPOS+=("$1")
        shift
        ;;
    esac
  done

  [[ "${#REPOS[@]}" -gt 0 ]] || die_usage "at least one skwid138/repo argument is required"

  local repo manifest_path final_json
  for repo in "${REPOS[@]}"; do
    validate_repo_slug "$repo"
  done

  YQ_ERR="$(mktemp)"
  REPOS_FILE="$(mktemp)"
  TMP_FILES="$TMP_FILES $YQ_ERR $REPOS_FILE"
  trap cleanup EXIT

  require_cmd "jq"
  require_cmd "gh"
  require_cmd "yq" "Install mikefarah yq: brew install yq"
  require_auth "gh" "gh auth status" "gh auth login"
  check_yq_flavor

  manifest_path="${GH_LABEL_SYNC_MANIFEST:-$(dirname "$0")/../data/github-labels.yml}"
  load_manifest "$manifest_path"

  for repo in "${REPOS[@]}"; do
    process_repo "$repo"
  done

  if ! final_json="$(jq -s '{version: 1, repos: .}' "$REPOS_FILE")"; then
    die_upstream "failed to assemble result JSON"
  fi
  printf '%s\n' "$final_json"
  [[ "$HAD_ERRORS" == "0" ]] || die_upstream "one or more repos or label mutations failed; see errors[] in JSON output"
}

main "$@"
