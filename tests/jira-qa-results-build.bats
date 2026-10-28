#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../agent/jira-qa-results-build.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/jira-qa-results"
}

@test "builder --help prints usage without requiring input" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: jira-qa-results-build.sh INPUT.json"* ]]
}

@test "builder emits a versioned ADF preview envelope and digest" {
  run "$SCRIPT" "$FIXTURES/complete.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .version == 1 and
    .target_issue_key == "TEST-123" and
    .parent_story.key == "TEST-122" and
    .adf.version == 1 and
    .adf.type == "doc" and
    (.adf.content | type == "array") and
    (.body_digest | test("^[0-9a-f]{64}$")) and
    (.preview | contains("Agent-assisted manual QA")) and
    (.attachment_handoff | type == "array")
  ' >/dev/null
}

@test "builder accepts exactly one JSON document from stdin" {
  run "$SCRIPT" - <"$FIXTURES/complete.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.target_issue_key == "TEST-123"' >/dev/null
}

@test "builder rejects non-canonical result statuses without emitting a partial envelope" {
  jq '.acceptance_criteria[0].status = "Almost"' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/invalid.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/invalid.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" != *"Almost"* ]]
}

@test "builder never marks partially covered acceptance criteria as passed" {
  jq '.acceptance_criteria[0].coverage = "partial"' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/partial-pass.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/partial-pass.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects unresolved acceptance-criteria evidence references" {
  jq '.acceptance_criteria[0].evidence_ids = ["E-MISSING"]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/unresolved.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/unresolved.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder requires evidence for passed or failed acceptance criteria" {
  jq '.acceptance_criteria[0].evidence_ids = []' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/no-ac-evidence.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/no-ac-evidence.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects result rows whose environment/build pair is missing" {
  jq '.acceptance_criteria[0].build_id = "build-missing"' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/missing-build.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/missing-build.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects arbitrary ADF input instead of trusting caller-supplied content" {
  jq '. + {adf: {version: 1, type: "doc", content: [{type: "text", text: "/Users/example/secret.png"}]}}' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/untrusted-adf.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/untrusted-adf.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder refuses local filesystem paths in ADF-visible evidence text" {
  jq '.evidence[0].artifact = "/Users/example/private/screenshot.png"' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/local-path-in-evidence.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/local-path-in-evidence.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder refuses local paths embedded in otherwise readable report text" {
  jq '.evidence[0].artifact = "Local attachment at `/Users/example/screenshot.png`"' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/embedded-local-path.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/embedded-local-path.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects common POSIX, Windows, UNC, and relative file paths in artifact metadata" {
  pathlikes=(
    "/Volumes/private/evidence.png"
    "/mnt/data/evidence.png"
    'C:\Users\synthetic\evidence.png'
    '\\synthetic-server\share\evidence.png'
    "../evidence.png"
    "./evidence.png"
    "relative/evidence.png"
    "~/evidence.png"
    "file:///Volumes/private/evidence.png"
  )
  for pathlike in "${pathlikes[@]}"; do
    jq --arg artifact "$pathlike" '.evidence[0].artifact = $artifact' \
      "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/pathlike-artifact.json"
    run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/pathlike-artifact.json"
    [ "$status" -ne 0 ] || return 1
    [ -z "$output" ] || return 1
  done
}

@test "builder allows API routes in path fields and HTTPS artifact URLs" {
  jq '.evidence[0].path = "/api/synthetic-resource"
      | .evidence[0].artifact = "https://cdn.example.test/evidence/synthetic.png"' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/safe-route-url.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/safe-route-url.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("/api/synthetic-resource"))
      and ($text | contains("https://cdn.example.test/evidence/synthetic.png"))
  ' >/dev/null
}

@test "builder rejects file-like relative paths in the evidence path field" {
  pathlikes=("../private/evidence.png" "./evidence.png" "relative/evidence.png")
  for pathlike in "${pathlikes[@]}"; do
    jq --arg path "$pathlike" '.evidence[0].path = $path' \
      "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/relative-evidence-path.json"
    run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/relative-evidence-path.json"
    [ "$status" -ne 0 ] || return 1
    [ -z "$output" ] || return 1
  done
}

@test "builder rejects relative filesystem paths in freeform report text" {
  jq '.closers.qa_data_cleanup = ["Cleanup left incomplete at ../private/retained-data.json"]' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/relative-path-closer.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/relative-path-closer.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects bare relative artifact paths in freeform report text" {
  pathlikes=(
    "screenshots/private.png"
    '"screenshots/private.png"'
    "screenshots/private.jpg"
    "screenshots/private.jpeg"
    "reports/retained-data.json"
    "captures/browser.gif"
    "captures/browser.webp"
    "captures/browser.svg"
    "reports/retained-data.pdf"
    "reports/retained-data.txt"
    "exports/evidence.csv"
    "logs/session.log"
    "archives/results.zip"
    "traces/network.har"
    "recordings/check.mp4"
    'reports\private.PNG'
  )
  for pathlike in "${pathlikes[@]}"; do
    jq --arg path "$pathlike" '.closers.qa_data_cleanup = ["Retained artifact: (\($path))."]' \
      "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/bare-relative-artifact.json"
    run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/bare-relative-artifact.json"
    [ "$status" -ne 0 ] || return 1
    [ -z "$output" ] || return 1
  done
}

@test "builder preserves API routes URLs and ordinary slash prose in freeform text" {
  jq '.closers.qa_data_cleanup = [
        "Root-relative API route: /api/file.json",
        "Verified URL: https://example.test/reports/file.json",
        "Environment/build: ENV-1/build-1",
        "QA data/cleanup is ordinary prose."
      ]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/safe-freeform-paths.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/safe-freeform-paths.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .preview as $preview
    | ($preview | contains("/api/file.json"))
      and ($preview | contains("https://example.test/reports/file.json"))
      and ($preview | contains("ENV-1/build-1"))
      and ($preview | contains("QA data/cleanup is ordinary prose."))
  ' >/dev/null
}

@test "builder renders the required report sections and closers in ADF" {
  run "$SCRIPT" "$FIXTURES/complete.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .adf.content as $blocks
    | [$blocks[] | select(.type == "expand") | .attrs.title] as $expand_titles
    | [$blocks[] | select(.type == "heading") | .content[0].text] as $top_headings
    | [.adf.content[] | .. | objects | select(.type == "text") | .text] as $body_text
    | ($expand_titles | index("Environment")) as $environment
    | ($expand_titles | index("Acceptance criteria")) as $criteria
    | ($expand_titles | index("Subtask tests")) as $subtasks
    | ($expand_titles | index("Evidence register")) as $evidence
    | ($body_text | join("\n")) as $text
    | ($blocks[0].type == "heading")
      and ($blocks[0].content[0].text == "Agent-assisted manual QA — TEST-122: Synthetic QA example")
      and ($blocks[1].type == "paragraph")
      and ($blocks[1].content[0].text == "Agent assessment — not QA sign-off.")
      and ($environment != null and $criteria != null and $subtasks != null and $evidence != null)
      and ($environment < $criteria and $criteria < $subtasks and $subtasks < $evidence)
      and (any($blocks[]; .type == "expand" and .attrs.title == "Acceptance criteria"
        and any(.content[]; .type == "table" and .content[0].content[0].type == "tableHeader")))
      and (any($blocks[]; .type == "expand" and .attrs.title == "Evidence register"
        and any(.content[]; .type == "table" and .content[0].content[0].type == "tableHeader")))
      and ($top_headings[-3:] == ["Not run", "Needs human", "QA data/cleanup"])
      and ($text | contains("Synthetic criterion is visible."))
      and ($text | contains("Passed"))
      and (.preview | contains("Environment\nEnvironment:"))
  ' >/dev/null
}

@test "builder emits table header and cell nodes with empty attrs objects" {
  run "$SCRIPT" "$FIXTURES/complete.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "tableHeader" or .type == "tableCell")] as $cells
    | ($cells | length) > 0 and all($cells[]; .attrs == {})
  ' >/dev/null
}

@test "builder states when no acceptance criteria were supplied instead of implying a pass" {
  jq '.acceptance_criteria = []' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/no-ac.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/no-ac.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n")
      | contains("No acceptance criteria were supplied; none were invented.")
  ' >/dev/null
}

@test "builder rejects unrecognized evidence provenance" {
  jq '.evidence[0].provenance = "guessed_from_logs"' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/invalid-provenance.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/invalid-provenance.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects evidence fields with the wrong runtime type" {
  jq '.evidence[0].action = 7' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/wrong-evidence-type.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/wrong-evidence-type.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects non-string closer items" {
  jq '.closers.needs_human = [42]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/invalid-closer.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/invalid-closer.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder rejects titles beyond the documented character limit" {
  jq '.parent_story.summary = ("x" * 32768)' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/long-title.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/long-title.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder counts expand titles toward the report character limit" {
  run "$SCRIPT" "$FIXTURES/complete.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/base-envelope.json"
  text_chars="$(jq '[.adf.content[] | .. | objects | select(.type == "text") | .text | length] | add' "$BATS_TEST_TMPDIR/base-envelope.json")"
  ac_chars="$(jq -r '.acceptance_criteria[0].text | length' "$FIXTURES/complete.json")"
  enlarged_ac_chars=$((ac_chars + 32767 - text_chars))
  jq --argjson length "$enlarged_ac_chars" '.acceptance_criteria[0].text = ("x" * $length)' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/expand-title-limit.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/expand-title-limit.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder keeps attachment paths out of ADF and verifies existing handoff paths" {
  local_path="$BATS_TEST_TMPDIR/synthetic-attachment.txt"
  printf 'synthetic attachment placeholder\n' >"$local_path"
  jq --arg path "$local_path" '.attachments = [{
    id: "SCREENSHOT-01",
    caption: "Synthetic browser check, test environment, heading visible, 1280x800 viewport",
    state: "Heading visible",
    viewport: "1280x800",
    environment_id: "ENV-1",
    build_id: "build-1",
    local_path: $path
  }]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/with-attachment.json"

  run "$SCRIPT" "$BATS_TEST_TMPDIR/with-attachment.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg path "$local_path" '
    ([.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n")) as $text
    | ($text | contains("SCREENSHOT-01"))
      and ($text | contains("1280x800 viewport"))
      and (($text | contains($path)) | not)
      and .attachment_handoff[0].local_path == $path
      and .attachment_handoff[0].local_path_status == "verified_existing"
  ' >/dev/null
}

@test "builder marks missing attachment mappings unavailable and suppresses their paths" {
  local_path="$BATS_TEST_TMPDIR/missing-synthetic-attachment.png"
  jq --arg path "$local_path" '.attachments = [{
    id: "ATTACHMENT-01",
    caption: "Synthetic upload unavailable, test environment, state unknown, viewport unknown",
    state: "Unknown",
    viewport: "Unknown",
    environment_id: "ENV-1",
    build_id: "build-1",
    local_path: $path
  }]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/missing-attachment.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/missing-attachment.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e --arg path "$local_path" '
    ([.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n")) as $text
    | ($text | contains($path) | not)
      and .attachment_handoff[0].local_path_status == "unavailable"
      and (.attachment_handoff[0] | has("local_path") | not)
  ' >/dev/null
}

@test "builder rejects invalid statuses in subtask test results" {
  jq '.subtask_tests = [{
    id: "T-1",
    label: "Synthetic subtask check",
    status: "Almost",
    notes: "Steps unavailable; none were invented.",
    environment_id: "ENV-1",
    build_id: "build-1",
    evidence_ids: []
  }]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/invalid-subtask-status.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/invalid-subtask-status.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder reports defect expected/actual/repro and evidence separately" {
  jq '.findings = [{
    id: "DEF-1",
    summary: "Synthetic validation defect",
    expected: "Input is rejected",
    actual: "Input is accepted",
    reproduction: "Submit the synthetic invalid value",
    severity: "low",
    scope: "Synthetic environment only",
    environment_id: "ENV-1",
    build_id: "build-1",
    evidence_ids: ["E-1"]
  }]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/with-defect.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/with-defect.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("DEF-1"))
      and ($text | contains("Expected: Input is rejected"))
      and ($text | contains("Actual: Input is accepted"))
      and ($text | contains("Reproduction: Submit the synthetic invalid value"))
      and ($text | contains("Severity: low"))
      and ($text | contains("Scope: Synthetic environment only"))
      and ($text | contains("E-1"))
  ' >/dev/null
}

@test "builder includes the reviewed identity alias in the environment section" {
  jq '.environments[0].identity = "Synthetic operator alias"' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/identity.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/identity.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n")
      | contains("Identity: Synthetic operator alias")
  ' >/dev/null
}

@test "builder keeps approved human checks separate from completed human checks" {
  jq '.environments[0].approved_human_checks = ["Synthetic human check approved"]
      | .environments[0].completed_human_checks = ["Synthetic human check completed"]' \
    "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/human-approval.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/human-approval.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("Approved human check: Synthetic human check approved"))
      and ($text | contains("Completed human check: Synthetic human check completed"))
  ' >/dev/null
}

@test "builder accepts exactly one top-level JSON document" {
  cat "$FIXTURES/complete.json" "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/two-documents.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/two-documents.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder digest binds canonical compact sorted ADF with one trailing newline" {
  run "$SCRIPT" "$FIXTURES/complete.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/envelope.json"
  digest="$(jq -r '.body_digest' "$BATS_TEST_TMPDIR/envelope.json")"
  expected="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/envelope.json" | shasum -a 256 | cut -d ' ' -f 1)"
  [ "$digest" = "$expected" ]
  [ "$(jq -s 'length' "$BATS_TEST_TMPDIR/envelope.json")" -eq 1 ]
}

@test "builder rejects duplicate IDs across report record collections" {
  jq '.evidence[0].id = "AC-1"' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/duplicate-id.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/duplicate-id.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder requires distinct QA target and parent story keys" {
  jq '.parent_story.key = .target_issue_key' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/same-target-parent.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/same-target-parent.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "builder separates observations from unresolved requirements" {
  jq '.observations = [{
        id: "OBS-1",
        summary: "Synthetic behavior was observed without asserting a violation",
        environment_id: "ENV-1",
        build_id: "build-1",
        evidence_ids: ["E-1"]
      }]
      | .unresolved_requirements = [{
        id: "REQ-1",
        summary: "Synthetic expected behavior remains unspecified",
        environment_id: "ENV-1",
        build_id: "build-1",
        evidence_ids: []
      }]' "$FIXTURES/complete.json" >"$BATS_TEST_TMPDIR/observations-requirements.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/observations-requirements.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("Observation, no violation asserted: Synthetic behavior was observed without asserting a violation"))
      and ($text | contains("Unresolved requirement: Synthetic expected behavior remains unspecified"))
  ' >/dev/null
}

@test "offline evaluation preserves partial human, CI-only, and design-inconclusive evidence" {
  run "$SCRIPT" "$FIXTURES/partial-human-ci.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | select(.type == "expand") | .attrs.title] as $titles
    | [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("Human double-check required"))
      and ($text | contains("ci_only"))
      and ($titles | index("Design verification") != null)
      and ($text | contains("Inconclusive"))
      and ($text | contains("Approved human check: Review the remaining synthetic criterion check"))
      and ($text | contains("Completed human check: Review the synthetic captured state"))
      and ($text | contains("Steps were not supplied; none were invented."))
  ' >/dev/null
}

@test "offline evaluation keeps blocked data, not-run, and auth-inconclusive distinct" {
  run "$SCRIPT" "$FIXTURES/not-run-blocked-data.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("Blocked by data"))
      and ($text | contains("Not run"))
      and ($text | contains("Inconclusive"))
      and ($text | contains("Authentication status was not checked"))
      and ($text | contains("ENV-UNKNOWN/unknown"))
  ' >/dev/null
}

@test "offline evaluation preserves mixed environments, findings, requirement conflict, cleanup, and attachment marker" {
  run "$SCRIPT" "$FIXTURES/mixed-findings-cleanup-attachment.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    . as $report
    | [$report.adf.content[] | select(.type == "expand") | .attrs.title] as $titles
    | [$report.adf.content[] | select(.type == "heading") | .content[0].text] as $top_headings
    | [.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n") as $text
    | ($text | contains("ENV-DEV/dev-8"))
      and ($text | contains("ENV-CI/ci-4"))
      and ($text | contains("static"))
      and ($titles | index("Defects and findings") != null)
      and ($titles | index("Observations") != null)
      and ($titles | index("Unresolved requirements") != null)
      and ($titles | index("Extra probes") != null)
      and ($titles | index("Accessibility") != null)
      and ($titles | index("Input parsing") != null)
      and ($titles | index("Screenshots and attachments") != null)
      and ($text | contains("403 conflicts with the route"))
      and ($text | contains("TEST-DATA-01 is retained"))
      and ($text | contains("SCREENSHOT-01"))
      and ($top_headings[-3:] == ["Not run", "Needs human", "QA data/cleanup"])
      and ($report.preview | contains("Screenshots and attachments"))
      and all($report.adf.content[] | select(.type == "expand");
        (.attrs.title | type == "string" and length > 0)
        and (.content | length > 0 and all(.[]; .type == "paragraph" or .type == "table")))
      and ($report.attachment_handoff[0].local_path_status == "unavailable")
  ' >/dev/null
}
