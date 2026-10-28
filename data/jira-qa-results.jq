def nonempty_string: type == "string" and length > 0;
def issue_key: type == "string" and test("^[A-Z][A-Z0-9]+-[1-9][0-9]*$");
def exact_keys($object; $expected):
  ($object | type) == "object" and
  ((($object | keys) - $expected) | length) == 0 and
  (($expected - ($object | keys)) | length) == 0;
def string_list: type == "array" and all(.[]; nonempty_string);
def result_status:
  . == "Passed" or . == "Failed" or . == "Blocked by data" or
  . == "Human double-check required" or . == "Not run" or . == "Inconclusive";
def evidence_provenance:
  . == "agent_browser" or . == "agent_api" or . == "synthetic_injected" or
  . == "static" or . == "ci_only" or . == "assumption" or . == "human_completed";
def collection_fields: [
  "environments", "acceptance_criteria", "subtask_tests", "evidence",
  "probes", "findings", "observations", "unresolved_requirements",
  "design_verification", "accessibility", "input_parsing", "attachments"
];
def all_record_ids($input): [
  $input.environments[].id,
  $input.acceptance_criteria[].id,
  $input.subtask_tests[].id,
  $input.evidence[].id,
  $input.probes[].id,
  $input.findings[].id,
  $input.observations[].id,
  $input.unresolved_requirements[].id,
  $input.design_verification[].id,
  $input.accessibility[].id,
  $input.input_parsing[].id,
  $input.attachments[].id
];
def resolves_environment($row; $input):
  any($input.environments[];
    .id == $row.environment_id and .build.id == $row.build_id);
def resolves_evidence($row; $input):
  all($row.evidence_ids[];
    . as $ref
    | any($input.evidence[];
        .id == $ref and .environment_id == $row.environment_id and .build_id == $row.build_id));
def outcome_rows_valid($rows; $input):
  all($rows[];
    (exact_keys(.; ["id", "label", "status", "notes", "environment_id", "build_id", "evidence_ids"]))
    and all([.id, .label, .status, .notes, .environment_id, .build_id][]; nonempty_string)
    and (.status | result_status)
    and (.evidence_ids | string_list)
    and ((.status != "Passed" and .status != "Failed") or (.evidence_ids | length) > 0)
    and resolves_environment(.; $input)
    and resolves_evidence(.; $input));
def title($parent): "Agent-assisted manual QA — \($parent.key): \($parent.summary)";
def without_http_urls: gsub("https?://[^[:space:]<>]+"; "");
def has_bare_relative_artifact_path:
  test("(?i)(^|[^[:alnum:]_/\\\\])([[:alnum:]_.-]+[/\\\\])+[[:alnum:]_.-]+\\.(png|jpg|jpeg|gif|webp|svg|pdf|json|txt|log|csv|zip|har|mp4)(?=$|[^[:alnum:]_.-])");
def has_local_path:
  without_http_urls as $text
  | ($text | test("/(Users|Volumes|mnt|private/var|tmp|var/folders|home|root|workspace|workspaces|Applications|Library|System)(/|$)"))
    or ($text | test("[A-Za-z]:[\\\\/][^[:space:]]+"))
    or ($text | contains("\\\\"))
    or ($text | test("//[^/[:space:]]+/[^/[:space:]]+"))
    or ($text | test("\\.\\.?[\\\\/][^[:space:]]+"))
    or ($text | test("~[/\\\\][^[:space:]]+"))
    or ($text | test("file://"))
    or ($text | has_bare_relative_artifact_path);
def safe_evidence_path:
  . as $path
  | nonempty_string
    and ($path | test("[[:cntrl:]]") | not)
    and ($path | has_local_path | not)
    and (
      ($path | test("^https?://[^[:space:]<>]+$"))
      or ($path | startswith("/") and (startswith("//") | not))
      or ($path | test("[/\\\\]") | not)
    );
def safe_artifact:
  . as $artifact
  | nonempty_string
    and ($artifact | without_http_urls | test("[/\\\\]") | not)
    and ($artifact | has_local_path | not);
def text_node($value): {type: "text", text: $value};
def paragraph($value): {type: "paragraph", content: [text_node($value)]};
def heading($level; $value):
  {type: "heading", attrs: {level: $level}, content: [text_node($value)]};
def expand($title; $content): {type: "expand", attrs: {title: $title}, content: $content};
def table_cell($type; $value): {type: $type, attrs: {}, content: [paragraph($value)]};
def data_table($headers; $rows): {
  type: "table",
  content: [
    {type: "tableRow", content: [$headers[] | table_cell("tableHeader"; .)]},
    ($rows[] | {type: "tableRow", content: [.[] | table_cell("tableCell"; .)]})
  ]
};
def labeled_values($label; $values):
  if ($values | length) == 0 then [paragraph("\($label): None recorded.")]
  else [$values[] | paragraph("\($label): \(.)")] end;
def environment_nodes($environment):
  [
    paragraph("Environment: \($environment.label)"),
    paragraph("Date/window: \($environment.date_window)"),
    paragraph("Scope: \($environment.scope)"),
    paragraph("URL: \($environment.url)"),
    paragraph("Identity: \($environment.identity)"),
    paragraph("Build: source=\($environment.build.source); id=\($environment.build.id); time=\($environment.build.time)"),
    labeled_values("Client deviation"; $environment.client_deviations)[],
    labeled_values("Approved agent check"; $environment.approved_agent_checks)[],
    labeled_values("Approved human check"; $environment.approved_human_checks)[],
    labeled_values("Completed human check"; $environment.completed_human_checks)[],
    labeled_values("Approved side effect"; $environment.approved_side_effects)[],
    paragraph("Approved cleanup scope: \($environment.cleanup_scope)")
  ];
def closer_nodes($label; $values):
  [heading(2; $label)] +
  (if ($values | length) == 0 then [paragraph("None recorded.")]
   else [$values[] | paragraph("• \(.)")] end);
def evidence_rows($items):
  [$items[] | [
    .id,
    .provenance,
    .action,
    .method,
    .path,
    .state,
    "\(.window); limits: \(.limits)",
    .artifact,
    "\(.environment_id)/\(.build_id)"
  ]];
def attachment_rows($items):
  [$items[] | [
    .id,
    .caption,
    .state,
    .viewport,
    "\(.environment_id)/\(.build_id)"
  ]];
def outcome_rows($items):
  [$items[] | [
    .id,
    .label,
    .status,
    .notes,
    (if (.evidence_ids | length) == 0 then "None cited" else (.evidence_ids | join(", ")) end),
    "\(.environment_id)/\(.build_id)"
  ]];
def finding_rows($items):
  [$items[] | [
    .id,
    .summary,
    "Expected: \(.expected)",
    "Actual: \(.actual)",
    "Reproduction: \(.reproduction)",
    "Severity: \(.severity)",
    "Scope: \(.scope)",
    (if (.evidence_ids | length) == 0 then "None cited" else (.evidence_ids | join(", ")) end),
    "\(.environment_id)/\(.build_id)"
  ]];
def detail_rows($items; $label):
  [$items[] | [
    .id,
    "\($label): \(.summary)",
    (if (.evidence_ids | length) == 0 then "None cited" else (.evidence_ids | join(", ")) end),
    "\(.environment_id)/\(.build_id)"
  ]];
def optional_outcome_nodes($label; $items):
  if ($items | length) == 0 then [] else [
    expand($label; [data_table(
      ["ID", "Check", "Result", "Notes", "Evidence IDs", "Environment/build"];
      outcome_rows($items)
    )])
  ] end;
def block_text_nodes:
  . as $block
  | (if $block.type == "expand" then [$block.attrs.title] else [] end)
    + [$block | .. | objects | select(.type == "text") | .text];
def adf_text_nodes($blocks): [$blocks[] | block_text_nodes[]];

if length != 1 then error("expected exactly one JSON document") else .[0] end
| if type != "object" then error("input must be an object") else . end
| . as $input
| if ((keys - [
      "version", "target_issue_key", "parent_story", "environments",
      "acceptance_criteria", "subtask_tests", "evidence", "probes", "findings",
      "observations", "unresolved_requirements", "design_verification",
      "accessibility", "input_parsing", "attachments", "closers"
    ]) | length) != 0
  then error("input contains unsupported fields") else . end
| if $input.version != 1 then error("unsupported input version") else . end
| if ($input.target_issue_key | issue_key) | not then error("invalid target issue key") else . end
| if (($input.parent_story | type) != "object"
      or ($input.parent_story.key | issue_key | not)
      or ($input.parent_story.summary | nonempty_string | not)
      or (exact_keys($input.parent_story; ["key", "summary"]) | not)
      or $input.parent_story.key == $input.target_issue_key)
  then error("invalid or non-distinct parent story") else . end
| if any(collection_fields[]; ($input[.] | type) != "array")
  then error("all report collections must be arrays") else . end
| if (($input.closers | type) != "object"
      or (exact_keys($input.closers; ["not_run", "needs_human", "qa_data_cleanup"]) | not)
      or ($input.closers.not_run | string_list | not)
      or ($input.closers.needs_human | string_list | not)
      or ($input.closers.qa_data_cleanup | string_list | not))
  then error("report closers must be arrays") else . end
| if ($input.environments | length) == 0
  then error("at least one environment is required") else . end
| if any($input.environments[];
      (exact_keys(.; [
        "id", "label", "date_window", "scope", "url", "identity", "build",
        "client_deviations", "approved_agent_checks", "approved_human_checks", "completed_human_checks",
        "approved_side_effects", "cleanup_scope"
      ]) | not)
      or any([.id, .label, .date_window, .scope, .url, .identity, .cleanup_scope][]; (nonempty_string | not))
      or (exact_keys(.build; ["source", "id", "time"]) | not)
      or any([.build.source, .build.id, .build.time][]; (nonempty_string | not))
      or (.client_deviations | string_list | not)
      or (.approved_agent_checks | string_list | not)
      or (.approved_human_checks | string_list | not)
      or (.completed_human_checks | string_list | not)
      or (.approved_side_effects | string_list | not)
      or (.url != "unknown" and (.url | test("^https?://[^[:space:]<>]+$") | not)))
  then error("environment fields have invalid types or shape") else . end
| if (all_record_ids($input) | length) != (all_record_ids($input) | unique | length)
  then error("report record IDs must be unique") else . end
| if any($input.evidence[]; (.provenance | evidence_provenance | not))
  then error("evidence contains unrecognized provenance") else . end
| if any($input.evidence[];
      (exact_keys(.; [
        "id", "provenance", "action", "method", "path", "state", "window",
        "limits", "artifact", "environment_id", "build_id"
      ]) | not)
      or any([.id, .action, .method, .path, .state, .window, .limits, .artifact,
              .environment_id, .build_id][]; (nonempty_string | not))
      or (.path | safe_evidence_path | not)
      or (.artifact | safe_artifact | not)
      or (resolves_environment(.; $input) | not))
  then error("evidence fields have invalid types or shape") else . end
| if any($input.findings[];
      (exact_keys(.; [
        "id", "summary", "expected", "actual", "reproduction", "severity", "scope",
        "environment_id", "build_id", "evidence_ids"
      ]) | not)
      or any([.id, .summary, .expected, .actual, .reproduction, .severity, .scope,
              .environment_id, .build_id][]; (nonempty_string | not))
      or (.evidence_ids | string_list | not)
      or (.evidence_ids | length) == 0
      or (resolves_environment(.; $input) | not)
      or (resolves_evidence(.; $input) | not))
  then error("finding fields have invalid types or references") else . end
| if any(["observations", "unresolved_requirements"][];
      all($input[.][];
        exact_keys(.; ["id", "summary", "environment_id", "build_id", "evidence_ids"])
        and all([.id, .summary, .environment_id, .build_id][]; nonempty_string)
        and (.evidence_ids | string_list)
        and resolves_environment(.; $input)
        and resolves_evidence(.; $input)) | not)
  then error("observation or requirement fields have invalid types or references") else . end
| if any(["subtask_tests", "probes", "design_verification", "accessibility", "input_parsing"][];
      (outcome_rows_valid($input[.]; $input) | not))
  then error("check result fields have invalid types or references") else . end
| if any($input.attachments[];
      (exact_keys(.; [
        "id", "caption", "state", "viewport", "environment_id", "build_id", "local_path"
      ]) | not)
      or any([.id, .caption, .state, .viewport, .environment_id, .build_id, .local_path][];
        (type != "string"))
      or (.id | test("^(SCREENSHOT|ATTACHMENT)-[0-9]{2}$") | not)
      or (.caption | nonempty_string | not)
      or (.state | nonempty_string | not)
      or (.viewport | nonempty_string | not)
      or (.environment_id | nonempty_string | not)
      or (.build_id | nonempty_string | not)
      or (.local_path | test("[[:cntrl:]]"))
      or (.local_path != "" and (.local_path | startswith("/") | not))
      or (resolves_environment(.; $input) | not))
  then error("attachment fields have invalid types or shape") else . end
| if (($input.acceptance_criteria | type) != "array"
      or any($input.acceptance_criteria[];
        (exact_keys(.; ["id", "text", "coverage", "status", "environment_id", "build_id", "evidence_ids"]) | not)
        or any([.id, .text, .environment_id, .build_id][]; (nonempty_string | not))
        or (.status | result_status | not)
        or (.coverage != "complete" and .coverage != "partial")
        or (.coverage == "partial" and .status == "Passed")
        or (.evidence_ids | string_list | not)
        or ((.status == "Passed" or .status == "Failed") and (.evidence_ids | length) == 0)
        or (resolves_environment(.; $input) | not)
        or (resolves_evidence(.; $input) | not)))
  then error("acceptance criteria contain an invalid status or coverage") else . end
| . as $input
| (title($input.parent_story)) as $title
| [$input.environments[] | environment_nodes(.)[]] as $environment_nodes
| ($input.acceptance_criteria | map([
    "\(.id): \(.text)",
    .status,
    (if (.evidence_ids | length) == 0 then "None cited" else (.evidence_ids | join(", ")) end),
    "\(.environment_id)/\(.build_id)"
  ])) as $acceptance_rows
| ($input.subtask_tests | map([
    .id,
    .label,
    .status,
    .notes,
    (if (.evidence_ids | length) == 0 then "None cited" else (.evidence_ids | join(", ")) end),
    "\(.environment_id)/\(.build_id)"
  ])) as $subtask_rows
| evidence_rows($input.evidence) as $evidence_table_rows
| finding_rows($input.findings) as $finding_table_rows
| detail_rows($input.observations; "Observation, no violation asserted") as $observation_table_rows
| detail_rows($input.unresolved_requirements; "Unresolved requirement") as $requirement_table_rows
| attachment_rows($input.attachments) as $attachment_table_rows
| (if ($acceptance_rows | length) == 0
   then [paragraph("No acceptance criteria were supplied; none were invented.")]
   else [data_table(["AC identity/text", "Result", "Evidence IDs", "Environment/build"]; $acceptance_rows)] end) as $acceptance_content
| (if ($subtask_rows | length) == 0
   then [paragraph("No QA-subtask test steps were provided; no steps were invented.")]
   else [data_table(["Test ID", "Test", "Result", "Notes", "Evidence IDs", "Environment/build"]; $subtask_rows)] end) as $subtask_content
| (if ($evidence_table_rows | length) == 0
   then [paragraph("No evidence was recorded.")]
   else [data_table(
     ["Evidence ID", "Provenance", "Action", "Method", "Path", "State", "Window/limits", "Artifact", "Environment/build"];
     $evidence_table_rows
   )] end) as $evidence_content
| (
    [
      heading(1; $title),
      paragraph("Agent assessment — not QA sign-off."),
      expand("Environment"; $environment_nodes),
      expand("Acceptance criteria"; $acceptance_content),
      expand("Subtask tests"; $subtask_content),
      expand("Evidence register"; $evidence_content)
    ] +
    (if ($finding_table_rows | length) == 0 then [] else [expand("Defects and findings"; [
      data_table(
        ["Finding ID", "Summary", "Expected", "Actual", "Reproduction", "Severity", "Scope", "Evidence IDs", "Environment/build"];
        $finding_table_rows
      )
    ])] end) +
    (if ($observation_table_rows | length) == 0 then [] else [expand("Observations"; [
      data_table(["ID", "Observation", "Evidence IDs", "Environment/build"]; $observation_table_rows)
    ])] end) +
    (if ($requirement_table_rows | length) == 0 then [] else [expand("Unresolved requirements"; [
      data_table(["ID", "Requirement", "Evidence IDs", "Environment/build"]; $requirement_table_rows)
    ])] end) +
    optional_outcome_nodes("Extra probes"; $input.probes) +
    optional_outcome_nodes("Design verification"; $input.design_verification) +
    optional_outcome_nodes("Accessibility"; $input.accessibility) +
    optional_outcome_nodes("Input parsing"; $input.input_parsing) +
    (if ($input.attachments | length) == 0 then [] else [expand("Screenshots and attachments"; [
      data_table(
        ["Attachment ID", "Caption", "State", "Viewport", "Environment/build"];
        $attachment_table_rows
      )
    ])] end) +
    closer_nodes("Not run"; $input.closers.not_run) +
    closer_nodes("Needs human"; $input.closers.needs_human) +
    closer_nodes("QA data/cleanup"; $input.closers.qa_data_cleanup)
  ) as $content
| adf_text_nodes($content) as $report_text_nodes
| if any($report_text_nodes[]; has_local_path)
  then error("local filesystem paths are not allowed in ADF text") else . end
| ($report_text_nodes | join("")) as $report_text
| if ($report_text | length) > 32767
  then error("report text exceeds the documented character limit") else . end
| {
    version: 1,
    target_issue_key: $input.target_issue_key,
    parent_story: $input.parent_story,
    adf: {version: 1, type: "doc", content: $content},
    preview: ($report_text_nodes | join("\n")),
    attachment_handoff: [
      $input.attachments[] | {
        id,
        caption,
        state,
        viewport,
        environment_id,
        build_id,
        local_path: (if .local_path == "" then null else .local_path end),
        local_path_status: (if .local_path == "" then "unavailable" else "checking" end)
      }
    ]
  }
