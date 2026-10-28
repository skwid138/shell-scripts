#!/usr/bin/env bash
# Preview or explicitly publish a reviewed, builder-produced Jira ADF comment.

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: jira-qa-results-publish.sh ENVELOPE.json [--key ISSUE-KEY] [--expected-digest SHA256] [--write]

Validate and preview a saved jira-qa-results builder envelope by default.
Publishing requires --write, one --key matching the envelope target, and one
--expected-digest matching the canonical ADF body digest.

Examples:
  jira-qa-results-publish.sh qa-results-envelope.json
  jira-qa-results-publish.sh qa-results-envelope.json --key TEST-123 \
    --expected-digest <reviewed-sha256> --write

Preview performs no authentication or Jira calls. --write makes one CLI call;
the CLI may have internal retry behavior this script cannot inspect.
EOF
}

input=""
key=""
expected_digest=""
write=false
seen_key=false
seen_digest=false
seen_write=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --key)
      [[ "$seen_key" == false && $# -ge 2 && -n "${2:-}" ]] || die_usage "--key must appear exactly once with a value"
      key="$2"
      seen_key=true
      shift 2
      ;;
    --expected-digest)
      [[ "$seen_digest" == false && $# -ge 2 && -n "${2:-}" ]] || die_usage "--expected-digest must appear exactly once with a value"
      expected_digest="$2"
      seen_digest=true
      shift 2
      ;;
    --write)
      [[ "$seen_write" == false ]] || die_usage "--write may appear only once"
      write=true
      seen_write=true
      shift
      ;;
    -*) die_usage "unknown option: $1 (see --help)" ;;
    *)
      [[ -z "$input" ]] || die_usage "provide exactly one envelope file (see --help)"
      input="$1"
      shift
      ;;
  esac
done

[[ -n "$input" ]] || die_usage "ENVELOPE.json is required (see --help)"
[[ -r "$input" && -f "$input" ]] || die_usage "envelope file is not readable"
if [[ "$write" == true ]]; then
  [[ "$seen_key" == true ]] || die_usage "--write requires --key"
  [[ "$seen_digest" == true ]] || die_usage "--write requires --expected-digest"
fi

require_cmd "jq"
require_cmd "shasum"

if ! envelope="$(jq -sc '
  def issue_key: type == "string" and test("^[A-Z][A-Z0-9]+-[1-9][0-9]*$");
  def nonempty_string: type == "string" and length > 0;
  def exact_keys($expected):
    type == "object" and
    ((keys - $expected) | length) == 0 and
    (($expected - keys) | length) == 0;
  def text_node:
    exact_keys(["text", "type"]) and .type == "text" and (.text | nonempty_string);
  def paragraph_node:
    exact_keys(["content", "type"]) and .type == "paragraph" and
    (.content | type == "array" and length > 0 and all(.[]; text_node));
  def heading_node:
    exact_keys(["attrs", "content", "type"]) and .type == "heading" and
    (.attrs | exact_keys(["level"]) and (.level == 1 or .level == 2)) and
    (.content | type == "array" and length == 1 and all(.[]; text_node));
  def table_cell_node:
    exact_keys(["attrs", "content", "type"]) and (.attrs | exact_keys([])) and
    (.type == "tableCell" or .type == "tableHeader") and
    (.content | type == "array" and length == 1 and all(.[]; paragraph_node));
  def table_row_node:
    exact_keys(["content", "type"]) and .type == "tableRow" and
    (.content | type == "array" and length > 0 and all(.[]; table_cell_node));
  def table_node:
    exact_keys(["content", "type"]) and .type == "table" and
    (.content | type == "array" and length > 0 and all(.[]; table_row_node));
  def cell_text: [.content[] | .. | objects | select(.type == "text") | .text] | join("");
  def table_header_texts: [.content[0].content[] | cell_text];
  def known_report_table:
    (table_header_texts) as $headers
    | any([
        ["AC identity/text", "Result", "Evidence IDs", "Environment/build"],
        ["Test ID", "Test", "Result", "Notes", "Evidence IDs", "Environment/build"],
        ["Evidence ID", "Provenance", "Action", "Method", "Path", "State", "Window/limits", "Artifact", "Environment/build"],
        ["Finding ID", "Summary", "Expected", "Actual", "Reproduction", "Severity", "Scope", "Evidence IDs", "Environment/build"],
        ["ID", "Observation", "Evidence IDs", "Environment/build"],
        ["ID", "Requirement", "Evidence IDs", "Environment/build"],
        ["ID", "Check", "Result", "Notes", "Evidence IDs", "Environment/build"],
        ["Attachment ID", "Caption", "State", "Viewport", "Environment/build"]
      ][]; . == $headers);
  def expand_node:
    exact_keys(["attrs", "content", "type"]) and .type == "expand" and
    (.attrs | exact_keys(["title"]) and (.title | nonempty_string)) and
    (.content | type == "array" and length > 0 and
      all(.[]; paragraph_node or (table_node and known_report_table)));
  def supported_doc:
    exact_keys(["content", "type", "version"]) and .type == "doc" and .version == 1 and
    (.content | type == "array" and length >= 2 and
      all(.[]; heading_node or paragraph_node or expand_node));
  def without_http_urls: gsub("https?://[^[:space:]<>]+"; "");
  def required_report_structure:
    . as $doc
    | [$doc.content[] | select(.type == "expand") | .attrs.title] as $sections
    | [$doc.content[] | select(.type == "heading") | .content[0].text] as $headings
    | ([$doc.content | to_entries[] | select(.value.type == "heading" and .value.content[0].text == "Not run") | .key][0]) as $not_run
    | ([$doc.content | to_entries[] | select(.value.type == "heading" and .value.content[0].text == "Needs human") | .key][0]) as $human
    | ([$doc.content | to_entries[] | select(.value.type == "heading" and .value.content[0].text == "QA data/cleanup") | .key][0]) as $cleanup
    | ($sections | length) >= 4
      and $sections[0:4] == ["Environment", "Acceptance criteria", "Subtask tests", "Evidence register"]
      and ($sections | length) == ($sections | unique | length)
      and all($sections[4:][];
        . as $section
        | ["Extra probes", "Defects and findings", "Observations", "Unresolved requirements",
           "Design verification", "Accessibility", "Input parsing", "Screenshots and attachments"]
          | index($section) != null)
      and $headings == [$doc.content[0].content[0].text, "Not run", "Needs human", "QA data/cleanup"]
      and $not_run != null and $human != null and $cleanup != null
      and 2 < $not_run and $not_run < $human and $human < $cleanup
      and all($doc.content[2:$not_run][]; .type == "expand")
      and ($doc.content[$not_run + 1:$human] | length) > 0
      and all($doc.content[$not_run + 1:$human][]; .type == "paragraph")
      and ($doc.content[$human + 1:$cleanup] | length) > 0
      and all($doc.content[$human + 1:$cleanup][]; .type == "paragraph")
      and ($doc.content[$cleanup + 1:] | length) > 0
      and all($doc.content[$cleanup + 1:][]; .type == "paragraph");
  def has_local_path:
    without_http_urls as $text
    | ($text | test("/(Users|Volumes|mnt|private/var|tmp|var/folders|home|root|workspace|workspaces|Applications|Library|System)(/|$)"))
      or ($text | test("[A-Za-z]:[\\\\/][^[:space:]]+"))
      or ($text | contains("\\\\"))
      or ($text | test("//[^/[:space:]]+/[^/[:space:]]+"))
      or ($text | test("\\.\\.?[\\\\/][^[:space:]]+"))
      or ($text | test("~[/\\\\][^[:space:]]+"))
      or ($text | test("file://"))
      or ($text | test("(?i)(^|[^[:alnum:]_/\\\\])([[:alnum:]_.-]+[/\\\\])+[[:alnum:]_.-]+\\.(png|jpg|jpeg|gif|webp|svg|pdf|json|txt|log|csv|zip|har|mp4)(?=$|[^[:alnum:]_.-])"));
  def safe_evidence_path:
    . as $path
    | type == "string" and length > 0
      and (test("[[:cntrl:]]") | not)
      and (has_local_path | not)
      and (
        (test("^https?://[^[:space:]<>]+$"))
        or (startswith("/") and (startswith("//") | not))
        or (test("[/\\\\]") | not)
      );
  def safe_artifact:
    . as $artifact
    | type == "string" and length > 0
      and ($artifact | without_http_urls | test("[/\\\\]") | not)
      and ($artifact | has_local_path | not);
  def paragraph_text: [.content[] | .. | objects | select(.type == "text") | .text] | join("");
  def evidence_register_table:
    . as $table
    | ($table.type == "table")
      and ($table.content | type == "array" and length > 0)
      and ($table | table_header_texts) == [
        "Evidence ID", "Provenance", "Action", "Method", "Path", "State",
        "Window/limits", "Artifact", "Environment/build"
      ];
  def evidence_register_valid:
    . as $doc
    | [$doc.content[] | select(.type == "expand") | .content[]
        | select(.type == "table" and evidence_register_table)] as $all_evidence_tables
    | [$doc.content[] | select(.type == "expand" and .attrs.title == "Evidence register")] as $sections
    | if ($sections | length) != 1 then false else
        $sections[0].content as $blocks
        | if ($blocks | length) != 1 then false
          elif $blocks[0].type == "paragraph" then
            ($all_evidence_tables | length) == 0 and ($blocks[0] | paragraph_text) == "No evidence was recorded."
          elif ($blocks[0] | evidence_register_table) then
            ($all_evidence_tables | length) == 1 and $all_evidence_tables[0] == $blocks[0] and
            all($blocks[0].content[1:][];
              (.content | length) == 9
              and (.content[4] | cell_text | safe_evidence_path)
              and (.content[7] | cell_text | safe_artifact))
          else false end
      end;
  def block_texts:
    . as $block
    | if $block.type == "heading" or $block.type == "paragraph" then
        [($block | paragraph_text)]
      elif $block.type == "expand" then
        [$block.attrs.title] + [
          $block.content[] |
          if .type == "paragraph" then paragraph_text
          elif .type == "table" then (.content[] | .content[] | cell_text)
          else empty end
        ]
      else [] end;
  def adf_texts: [.content[] | block_texts[]];
  def valid_handoff:
    . as $a
    | ($a | type == "object")
      and ((($a | keys) - ["id", "caption", "state", "viewport", "environment_id", "build_id", "local_path", "local_path_status"]) | length) == 0
      and all(["id", "caption", "state", "viewport", "environment_id", "build_id", "local_path_status"][];
        . as $key | ($a | has($key)))
      and all([$a.id, $a.caption, $a.state, $a.viewport, $a.environment_id, $a.build_id][];
        (type == "string" and length > 0))
      and ($a.id | test("^(SCREENSHOT|ATTACHMENT)-[0-9]{2}$"))
      and (
        ($a.local_path_status == "verified_existing"
          and ($a | has("local_path"))
          and ($a.local_path | type == "string" and startswith("/") and length > 1 and (test("[[:cntrl:]]") | not)))
        or
        ($a.local_path_status == "unavailable"
          and (($a | has("local_path") | not) or $a.local_path == null))
      );
  if length != 1 then error("expected one document") else .[0] end
  | if type != "object" then error("expected envelope object") else . end
  | . as $e
  | if ((keys - ["version", "target_issue_key", "parent_story", "adf", "preview", "attachment_handoff", "body_digest"]) | length) != 0
      or ((["version", "target_issue_key", "parent_story", "adf", "preview", "attachment_handoff", "body_digest"] - (keys)) | length) != 0
    then error("invalid envelope fields") else . end
  | if $e.version != 1
      or ($e.target_issue_key | issue_key | not)
      or ($e.parent_story | type) != "object"
      or ($e.parent_story | keys) != ["key", "summary"]
      or ($e.parent_story.key | issue_key | not)
      or ($e.parent_story.key == $e.target_issue_key)
      or ($e.parent_story.summary | type) != "string"
      or ($e.parent_story.summary | length) == 0
      or ($e.preview | type) != "string"
      or ($e.attachment_handoff | type) != "array"
      or ($e.body_digest | type) != "string"
      or ($e.body_digest | test("^[0-9a-f]{64}$") | not)
      or ($e.adf | supported_doc | not)
      or ($e.adf | required_report_structure | not)
      or ($e.adf | evidence_register_valid | not)
      or ($e.adf | adf_texts | join("") | length) > 32767
      or ($e.adf | adf_texts | any(.[]; has_local_path))
      or ($e.adf.content[0].type != "heading")
      or ($e.adf.content[0].attrs.level != 1)
      or ($e.adf.content[0].content[0].text != "Agent-assisted manual QA — \($e.parent_story.key): \($e.parent_story.summary)")
      or ($e.adf.content[1].type != "paragraph")
      or ($e.adf.content[1].content[0].text != "Agent assessment — not QA sign-off.")
      or (($e.adf | adf_texts | join("\n")) != $e.preview)
      or any($e.attachment_handoff[]; (valid_handoff | not))
      or (($e.attachment_handoff | map(.id) | length) != ($e.attachment_handoff | map(.id) | unique | length))
    then error("invalid envelope content") else $e end
 ' "$input" 2>/dev/null)"; then
  die "invalid preview envelope"
fi

if ! canonical_adf="$(jq -cS '.adf' <<<"$envelope" 2>/dev/null)"; then
  die "could not canonicalize envelope ADF"
fi
computed_digest="$(printf '%s\n' "$canonical_adf" | shasum -a 256 | cut -d ' ' -f 1)" ||
  die "could not calculate the ADF digest"
stored_digest="$(jq -r '.body_digest' <<<"$envelope")"
[[ "$computed_digest" == "$stored_digest" ]] || die "envelope ADF digest does not match its body"

target="$(jq -r '.target_issue_key' <<<"$envelope")"
if [[ "$seen_key" == true ]]; then
  [[ "$key" =~ ^[A-Z][A-Z0-9]+-[1-9][0-9]*$ ]] || die_usage "--key must be a Jira issue key"
  [[ "$key" == "$target" ]] || die_usage "--key does not match the envelope target"
fi
if [[ "$seen_digest" == true ]]; then
  [[ "$expected_digest" =~ ^[0-9a-f]{64}$ ]] || die_usage "--expected-digest must be a lowercase SHA-256 digest"
  [[ "$expected_digest" == "$computed_digest" ]] || die_usage "--expected-digest does not match the envelope body"
fi

if [[ "$write" == true ]]; then
  require_cmd "acli"
  umask 077
  body_file="$(mktemp "${TMPDIR:-/tmp}/jira-qa-results-body.XXXXXX")" ||
    die "could not create secure ADF body file"
  stderr_file="$(mktemp "${TMPDIR:-/tmp}/jira-qa-results-stderr.XXXXXX")" || {
    rm -f "$body_file"
    die "could not create secure CLI stderr file"
  }
  trap 'rm -f "$body_file" "$stderr_file"' EXIT

  if ! jq -cS '{version: .adf.version, type: .adf.type, content: .adf.content}' \
    <<<"$envelope" >"$body_file" 2>/dev/null; then
    die "could not extract bare ADF body"
  fi

  cli_exit=0
  if cli_response="$(acli jira workitem comment create --key "$key" --body-file "$body_file" --json 2>"$stderr_file")"; then
    cli_exit=0
  else
    cli_exit=$?
  fi

  confirmed=false
  if [[ "$cli_exit" -eq 0 ]] && jq -se --arg target "$key" '
    if length != 1 then false else .[0] end
    | type == "object"
      and (.totalCount == 1)
      and (.successCount == 1)
      and (.results | type == "array" and length == 1)
      and (.results[0].status == "SUCCESS")
      and (.results[0].id == $target)
  ' <<<"$cli_response" >/dev/null 2>&1; then
    confirmed=true
  fi

  if [[ "$confirmed" == true ]]; then
    if ! result="$(jq -cnS --arg target "$key" --arg digest "$computed_digest" '
      {version:1, mode:"write", status:"cli_reported_success", target_issue_key:$target,
       body_digest:$digest, comment_id:null, comment_reference:"unknown",
       message:"CLI reported success; persistence and comment reference were not independently verified."}
    ' 2>/dev/null)"; then
      die "could not assemble publisher result"
    fi
    printf '%s\n' "$result"
    exit 0
  fi

  if ! result="$(jq -cnS --arg target "$key" --arg digest "$computed_digest" '
    {version:1, mode:"write", status:"uncertain", target_issue_key:$target,
     body_digest:$digest, comment_id:null, comment_reference:"unknown",
     message:"CLI did not confirm one matching comment; do not retry automatically."}
  ' 2>/dev/null)"; then
    die "could not assemble uncertain publisher result"
  fi
  printf '%s\n' "$result"
  exit 5
fi

handoff="$(jq -c '.attachment_handoff' <<<"$envelope")"
if ! result="$(jq -cnS \
  --arg target "$target" \
  --arg digest "$computed_digest" \
  --arg preview "$(jq -r '.preview' <<<"$envelope")" \
  --argjson handoff "$handoff" \
  '{version:1, mode:"preview", status:"preview_only", target_issue_key:$target,
    body_digest:$digest, comment_id:null, comment_reference:"unknown",
    preview:$preview, attachment_handoff:$handoff}' 2>/dev/null)"; then
  die "could not assemble publisher preview"
fi
printf '%s\n' "$result"
