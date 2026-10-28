#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

setup() {
  BUILDER="$BATS_TEST_DIRNAME/../agent/jira-qa-results-build.sh"
  SCRIPT="$BATS_TEST_DIRNAME/../agent/jira-qa-results-publish.sh"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/jira-qa-results/complete.json"
  ENVELOPE="$BATS_TEST_TMPDIR/envelope.json"
  "$BUILDER" "$FIXTURE" >"$ENVELOPE"

  STUBDIR="$BATS_TEST_TMPDIR/stubs"
  mkdir -p "$STUBDIR"
  export PATH="$STUBDIR:$PATH"
  export ACLI_LOG="$BATS_TEST_TMPDIR/acli.log"
  export ACLI_ARGS="$BATS_TEST_TMPDIR/acli.args"
  export ACLI_BODY="$BATS_TEST_TMPDIR/acli.body"
  export ACLI_MODE="$BATS_TEST_TMPDIR/acli.mode"
  export ACLI_RESPONSE='{"results":[{"status":"SUCCESS","message":"Comment on work item TEST-123 has been successfully added","id":"TEST-123"}],"totalCount":1,"successCount":1}'
  export ACLI_EXIT_CODE=0
  cat >"$STUBDIR/acli" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$ACLI_LOG"
printf '%s\n' "$@" >"$ACLI_ARGS"
printf '%s' "${ACLI_STDERR-}" >&2
body_file=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--body-file" && $# -ge 2 ]]; then
    body_file="$2"
    shift 2
  else
    shift
  fi
done
if [[ -n "$body_file" ]]; then
  stat -f '%Lp' "$body_file" >"$ACLI_MODE" 2>/dev/null || stat -c '%a' "$body_file" >"$ACLI_MODE"
  cp "$body_file" "$ACLI_BODY"
fi
printf '%s\n' "$ACLI_RESPONSE"
exit "$ACLI_EXIT_CODE"
EOF
  chmod +x "$STUBDIR/acli"
}

@test "publisher --help prints usage without requiring an envelope" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: jira-qa-results-publish.sh ENVELOPE.json"* ]]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher preview validates and displays the saved envelope without calling acli" {
  run "$SCRIPT" "$ENVELOPE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .version == 1 and
    .mode == "preview" and
    .target_issue_key == "TEST-123" and
    .comment_id == null and
    .comment_reference == "unknown" and
    (.preview | contains("Agent-assisted manual QA")) and
    (.preview | contains("Environment\nEnvironment:"))
  ' >/dev/null
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects ADF nodes outside the builder's supported subset" {
  jq '.adf.content += [{type: "unsupported", content: []}]' "$ENVELOPE" >"$BATS_TEST_TMPDIR/unsupported.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/unsupported.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/unsupported.json" \
    >"$BATS_TEST_TMPDIR/re-digested-unsupported.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-unsupported.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher requires the canonical level-one report title" {
  jq '.adf.content[0].attrs.level = 2' "$ENVELOPE" >"$BATS_TEST_TMPDIR/level-two-title.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/level-two-title.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/level-two-title.json" \
    >"$BATS_TEST_TMPDIR/re-digested-level-two-title.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-level-two-title.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects a structurally valid but incomplete report envelope" {
  jq '.adf.content = .adf.content[:2]
      | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/incomplete-report.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/incomplete-report.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/incomplete-report.json" \
    >"$BATS_TEST_TMPDIR/re-digested-incomplete-report.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-incomplete-report.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects required expands in the wrong order" {
  jq '.adf.content[2:4] = [.adf.content[3], .adf.content[2]]
      | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/out-of-order-expands.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/out-of-order-expands.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/out-of-order-expands.json" \
    >"$BATS_TEST_TMPDIR/re-digested-out-of-order-expands.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-out-of-order-expands.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects flattened sections when the required expands are missing" {
  jq '.adf.content = [
        .adf.content[] as $block
        | if $block.type == "expand" then
            {type:"heading",attrs:{level:2},content:[{type:"text",text:$block.attrs.title}]},
            $block.content[]
          else $block end
      ]
      | .preview = ([.adf.content[] | .. | objects | select(.type == "text") | .text] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/flattened-report.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/flattened-report.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/flattened-report.json" \
    >"$BATS_TEST_TMPDIR/re-digested-flattened-report.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-flattened-report.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher includes expand titles in the report character limit" {
  text_chars="$(jq '[.adf.content[] | .. | objects | select(.type == "text") | .text | length] | add' "$ENVELOPE")"
  ac_text="$(jq -r '.adf.content[] | select(.type == "expand" and .attrs.title == "Acceptance criteria") | .content[0].content[1].content[0].content[0].text' "$ENVELOPE")"
  enlarged_text_chars=$((${#ac_text} + 32767 - text_chars))
  jq --argjson length "$enlarged_text_chars" '
    .adf.content |= map(
      if .type == "expand" and .attrs.title == "Acceptance criteria" then
        .content[0].content[1].content[0].content[0].text = ("x" * $length)
      else . end
    )
    | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))
  ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/expand-title-limit.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/expand-title-limit.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/expand-title-limit.json" \
    >"$BATS_TEST_TMPDIR/re-digested-expand-title-limit.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-expand-title-limit.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects an expand with a non-canonical title" {
  jq '.adf.content |= map(
        if .type == "expand" and .attrs.title == "Environment" then .attrs.title = "Context" else . end
      )
      | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/wrong-expand-title.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/wrong-expand-title.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/wrong-expand-title.json" \
    >"$BATS_TEST_TMPDIR/re-digested-wrong-expand-title.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-wrong-expand-title.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects heading nodes nested inside an expand" {
  jq '.adf.content |= map(
        if .type == "expand" and .attrs.title == "Environment" then
          .content += [{type:"heading",attrs:{level:2},content:[{type:"text",text:"Nested"}]}]
        else . end
      )
      | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/nested-expand-heading.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/nested-expand-heading.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/nested-expand-heading.json" \
    >"$BATS_TEST_TMPDIR/re-digested-nested-expand-heading.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-nested-expand-heading.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects a re-digested ADF body containing a local filesystem path" {
  jq '.adf.content += [{type:"paragraph",content:[{type:"text",text:"/Users/example/private/image.png"}]}]
      | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/local-path.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/local-path.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/local-path.json" \
    >"$BATS_TEST_TMPDIR/re-digested-local-path.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-local-path.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects common POSIX, Windows, UNC, and relative file paths in ADF text" {
  pathlikes=(
    "/Volumes/private/evidence.png"
    "/mnt/data/evidence.png"
    'C:\Users\synthetic\evidence.png'
    '\\synthetic-server\share\evidence.png'
    "../evidence.png"
    "./evidence.png"
    "~/evidence.png"
    "file:///Volumes/private/evidence.png"
  )
  for pathlike in "${pathlikes[@]}"; do
    jq --arg path "$pathlike" '.adf.content += [{type:"paragraph",content:[{type:"text",text:("Artifact location: " + $path)}]}]
        | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
      "$ENVELOPE" >"$BATS_TEST_TMPDIR/pathlike-adf.json"
    digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/pathlike-adf.json" | shasum -a 256 | cut -d ' ' -f 1)"
    jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/pathlike-adf.json" \
      >"$BATS_TEST_TMPDIR/re-digested-pathlike-adf.json"
    run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-pathlike-adf.json"
    [ "$status" -ne 0 ] || return 1
    [ -z "$output" ] || return 1
    [ ! -e "$ACLI_LOG" ] || return 1
  done
}

@test "publisher rejects bare relative artifact paths in freeform ADF text" {
  pathlikes=(
    '"screenshots/private.png"'
    "'reports/retained-data.json'"
    "archives/evidence.zip"
  )
  for pathlike in "${pathlikes[@]}"; do
    jq --arg path "$pathlike" '
      .adf.content += [{type:"paragraph",content:[{type:"text",text:("Retained path: (" + $path + ").")}]}]
      | .preview += "\nRetained path: (" + $path + ")."
    ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/bare-relative-artifact-path.json"
    digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/bare-relative-artifact-path.json" | shasum -a 256 | cut -d ' ' -f 1)"
    jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/bare-relative-artifact-path.json" \
      >"$BATS_TEST_TMPDIR/re-digested-bare-relative-artifact-path.json"
    run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-bare-relative-artifact-path.json" \
      --key TEST-123 --expected-digest "$digest" --write
    [ "$status" -ne 0 ] || return 1
    [ -z "$output" ] || return 1
    [ ! -e "$ACLI_LOG" ] || return 1
  done
}

@test "publisher preserves API routes URLs and ordinary slash prose in freeform ADF text" {
  jq '.adf.content += [{type:"paragraph",content:[{type:"text",text:
        "Route: /api/file.json; URL: https://example.test/reports/file.json; Environment/build: ENV-1/build-1; QA data/cleanup is ordinary prose."
      }]}]
      | .preview += "\nRoute: /api/file.json; URL: https://example.test/reports/file.json; Environment/build: ENV-1/build-1; QA data/cleanup is ordinary prose."' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/safe-freeform-paths.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/safe-freeform-paths.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/safe-freeform-paths.json" \
    >"$BATS_TEST_TMPDIR/re-digested-safe-freeform-paths.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-safe-freeform-paths.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .status == "preview_only"
      and (.preview | contains("/api/file.json"))
      and (.preview | contains("https://example.test/reports/file.json"))
      and (.preview | contains("ENV-1/build-1"))
      and (.preview | contains("QA data/cleanup is ordinary prose."))
  ' >/dev/null
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects path tokens split across adjacent text nodes in one paragraph" {
  pathpairs=(
    "reports/|retained-data.json"
    "/Users/example/|private.json"
    "../private/|retained-data.json"
  )
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  for pathpair in "${pathpairs[@]}"; do
    IFS='|' read -r first second <<<"$pathpair"
    jq --arg first "$first" --arg second "$second" '
      .adf.content += [{type:"paragraph",content:[{type:"text",text:$first},{type:"text",text:$second}]}]
      | .preview += "\n" + $first + $second
    ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/split-path.json"
    digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/split-path.json" | shasum -a 256 | cut -d ' ' -f 1)"
    jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/split-path.json" \
      >"$BATS_TEST_TMPDIR/re-digested-split-path.json"
    run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-split-path.json" \
      --key TEST-123 --expected-digest "$digest" --write
    [ "$status" -ne 0 ] || return 1
    [ -z "$output" ] || return 1
    [ ! -e "$ACLI_LOG" ] || return 1
  done
}

@test "publisher scans logical paragraphs inside expands and table cells" {
  jq '
    .adf.content |= map(
      if .type == "expand" and .attrs.title == "Environment" then
        .content[0].content = [
          {type:"text",text:"reports/"},
          {type:"text",text:"retained-data.json"}
        ]
      else . end
    )
    | .preview |= sub("Environment: Synthetic test environment"; "reports/retained-data.json")
  ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/nested-expand-split-path.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/nested-expand-split-path.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/nested-expand-split-path.json" \
    >"$BATS_TEST_TMPDIR/re-digested-nested-expand-split-path.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-nested-expand-split-path.json" \
    --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]

  jq '
    .adf.content |= map(
      if .type == "expand" and .attrs.title == "Acceptance criteria" then
        .content[0].content[1].content[0].content[0].content = [
          {type:"text",text:"reports/"},
          {type:"text",text:"retained-data.json"}
        ]
      else . end
    )
    | .preview |= sub("AC-1: Synthetic criterion is visible."; "reports/retained-data.json")
  ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/table-cell-split-path.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/table-cell-split-path.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/table-cell-split-path.json" \
    >"$BATS_TEST_TMPDIR/re-digested-table-cell-split-path.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-table-cell-split-path.json" \
    --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher concatenates benign adjacent paragraph text in its preview" {
  jq '.adf.content += [{type:"paragraph",content:[
        {type:"text",text:"Synthetic adjacent "},
        {type:"text",text:"paragraph text."}
      ]}]
      | .preview += "\nSynthetic adjacent paragraph text."' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/adjacent-benign-text.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/adjacent-benign-text.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/adjacent-benign-text.json" \
    >"$BATS_TEST_TMPDIR/re-digested-adjacent-benign-text.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-adjacent-benign-text.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .status == "preview_only"
      and (.preview | endswith("Synthetic adjacent paragraph text."))
      and ((.preview | contains("Synthetic adjacent \nparagraph text.")) | not)
  ' >/dev/null
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher does not join separate paragraphs or table cells when scanning paths" {
  jq '.adf.content += [
        {type:"paragraph",content:[{type:"text",text:"reports/"}]},
        {type:"paragraph",content:[{type:"text",text:"retained-data.json"}]}
      ]
      | .preview += "\nreports/\nretained-data.json"' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/separate-paragraph-path-pieces.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/separate-paragraph-path-pieces.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/separate-paragraph-path-pieces.json" \
    >"$BATS_TEST_TMPDIR/re-digested-separate-paragraph-path-pieces.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-separate-paragraph-path-pieces.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.status == "preview_only"' >/dev/null

  jq '
    .adf.content |= map(
      if .type == "expand" and .attrs.title == "Acceptance criteria" then
        .content[0].content[1].content[0].content[0].content[0].text = "reports/"
        | .content[0].content[1].content[1].content[0].content[0].text = "retained-data.json"
      else . end
    )
    | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))
  ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/separate-cell-path-pieces.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/separate-cell-path-pieces.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/separate-cell-path-pieces.json" \
    >"$BATS_TEST_TMPDIR/re-digested-separate-cell-path-pieces.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-separate-cell-path-pieces.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '.status == "preview_only"' >/dev/null
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher validates the evidence artifact column as marker or durable URL text" {
  jq '.adf.content |= map(
        if .type == "expand" and .attrs.title == "Evidence register" then
          .content |= map(
            if .type == "table" then .content[1].content[7].content[0].content[0].text = "relative/evidence.png" else . end
          )
        else . end
      )
    | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))
  ' "$ENVELOPE" >"$BATS_TEST_TMPDIR/pathlike-artifact-cell.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/pathlike-artifact-cell.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/pathlike-artifact-cell.json" \
    >"$BATS_TEST_TMPDIR/re-digested-pathlike-artifact-cell.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-pathlike-artifact-cell.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher allows route paths in Path cells and verified HTTPS artifact references" {
  jq '.adf.content |= map(
        if .type == "expand" and .attrs.title == "Evidence register" then
          .content |= map(
            if .type == "table" then
              .content[1].content[4].content[0].content[0].text = "/api/synthetic-resource"
              | .content[1].content[7].content[0].content[0].text = "https://cdn.example.test/evidence/synthetic.png"
            else . end
          )
        else . end
      )
      | .preview = ([.adf.content[] | (if .type == "expand" then [.attrs.title] else [] end)[], (.. | objects | select(.type == "text") | .text)] | join("\n"))' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/safe-path-and-url.json"
  digest="$(jq -cS '.adf' "$BATS_TEST_TMPDIR/safe-path-and-url.json" | shasum -a 256 | cut -d ' ' -f 1)"
  jq --arg digest "$digest" '.body_digest = $digest' "$BATS_TEST_TMPDIR/safe-path-and-url.json" \
    >"$BATS_TEST_TMPDIR/re-digested-safe-path-and-url.json"
  run "$SCRIPT" "$BATS_TEST_TMPDIR/re-digested-safe-path-and-url.json"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .status == "preview_only"
      and (.preview | contains("/api/synthetic-resource"))
      and (.preview | contains("https://cdn.example.test/evidence/synthetic.png"))
  ' >/dev/null
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects unrecognized attachment handoff fields" {
  jq '.attachment_handoff = [{
        id: "SCREENSHOT-01",
        caption: "Synthetic attachment",
        state: "Unavailable",
        viewport: "Unknown",
        environment_id: "ENV-1",
        build_id: "build-1",
        local_path_status: "unavailable",
        unexpected: "not part of the envelope contract"
      }]' "$ENVELOPE" >"$BATS_TEST_TMPDIR/extra-handoff.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/extra-handoff.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects an envelope whose saved digest does not bind its ADF" {
  jq '.body_digest = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$ENVELOPE" >"$BATS_TEST_TMPDIR/wrong-digest.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/wrong-digest.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher requires exactly one envelope JSON document" {
  cat "$ENVELOPE" "$ENVELOPE" >"$BATS_TEST_TMPDIR/two-envelopes.json"
  run --separate-stderr "$SCRIPT" "$BATS_TEST_TMPDIR/two-envelopes.json"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher treats multiple CLI JSON documents as uncertain" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE="$(printf '%s\n%s' \
    '{"results":[{"status":"SUCCESS","id":"TEST-123"}],"totalCount":1,"successCount":1}' \
    '{"results":[{"status":"SUCCESS","id":"TEST-123"}],"totalCount":1,"successCount":1}')"
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 5 ]
  printf '%s\n' "$output" | jq -e '.status == "uncertain" and .comment_id == null' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
}

@test "publisher writes only bare ADF once after exact target and digest opt-in" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE='{"results":[{"status":"SUCCESS","id":"TEST-123"}],"totalCount":1,"successCount":1}'
  run "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | jq -e '
    .version == 1 and
    .mode == "write" and
    .status == "cli_reported_success" and
    .target_issue_key == "TEST-123" and
    .comment_id == null and
    .comment_reference == "unknown"
  ' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  [ "$(sed -n '1p' "$ACLI_ARGS")" = "jira" ]
  [ "$(sed -n '2p' "$ACLI_ARGS")" = "workitem" ]
  [ "$(sed -n '3p' "$ACLI_ARGS")" = "comment" ]
  [ "$(sed -n '4p' "$ACLI_ARGS")" = "create" ]
  [ "$(sed -n '5p' "$ACLI_ARGS")" = "--key" ]
  [ "$(sed -n '6p' "$ACLI_ARGS")" = "TEST-123" ]
  [ "$(sed -n '7p' "$ACLI_ARGS")" = "--body-file" ]
  body_path="$(sed -n '8p' "$ACLI_ARGS")"
  [ "$(sed -n '9p' "$ACLI_ARGS")" = "--json" ]
  [ "$(wc -l <"$ACLI_ARGS" | tr -d ' ')" -eq 9 ]
  jq -cS '.adf' "$ENVELOPE" >"$BATS_TEST_TMPDIR/expected-body.json"
  cmp -s "$BATS_TEST_TMPDIR/expected-body.json" "$ACLI_BODY"
  [ "$(cat "$ACLI_MODE")" = "600" ]
  [ ! -e "$body_path" ]
}

@test "publisher reports nonzero CLI outcomes as uncertain without retrying or leaking stderr" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE='{"token":"synthetic-secret"}'
  export ACLI_STDERR='synthetic-secret from stderr'
  export ACLI_EXIT_CODE=7
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 5 ]
  [[ "$output" != *"synthetic-secret"* ]]
  [[ "$stderr" != *"synthetic-secret"* ]]
  printf '%s\n' "$output" | jq -e '
    .status == "uncertain" and
    .comment_id == null and
    .comment_reference == "unknown" and
    (.message | contains("do not retry automatically"))
  ' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  body_path="$(sed -n '8p' "$ACLI_ARGS")"
  [ ! -e "$body_path" ]
}

@test "publisher rejects a mismatched target or reviewed digest before invoking acli" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-124 --expected-digest "$digest" --write
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 \
    --expected-digest "0000000000000000000000000000000000000000000000000000000000000000" --write
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher rejects duplicate target flags before invoking acli" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --key TEST-123 \
    --expected-digest "$digest" --write
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [ ! -e "$ACLI_LOG" ]
}

@test "publisher treats malformed CLI JSON as uncertain and never retries" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE='not-json'
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 5 ]
  printf '%s\n' "$output" | jq -e '.status == "uncertain" and .comment_id == null' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  [[ "$output" != *"not-json"* ]]
}

@test "publisher treats empty successful CLI stdout as uncertain without retry" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE=""
  export ACLI_EXIT_CODE=0
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 5 ]
  printf '%s\n' "$output" | jq -e '
    .status == "uncertain" and
    .comment_id == null and
    .comment_reference == "unknown" and
    (.message | contains("do not retry automatically"))
  ' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  [[ "$output" != *"results"* ]]
}

@test "publisher treats a success-shaped response with missing status as uncertain" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE='{"results":[{"message":"synthetic-secret marker","id":"TEST-123"}],"totalCount":1,"successCount":1}'
  export ACLI_STDERR='synthetic-secret from stderr'
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 5 ]
  [[ "$output" != *"synthetic-secret"* ]]
  [[ "$stderr" != *"synthetic-secret"* ]]
  printf '%s\n' "$output" | jq -e '
    .status == "uncertain" and
    .comment_id == null and
    .comment_reference == "unknown" and
    (.message | contains("do not retry automatically"))
  ' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  body_path="$(sed -n '8p' "$ACLI_ARGS")"
  [ ! -e "$body_path" ]
}

@test "publisher treats a FAILED response with otherwise valid counts as uncertain" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  export ACLI_RESPONSE='{"results":[{"status":"FAILED","message":"synthetic-failed-secret marker","id":"TEST-123"}],"totalCount":1,"successCount":1}'
  export ACLI_STDERR='synthetic-failed-secret from stderr'
  run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
  [ "$status" -eq 5 ]
  [[ "$output" != *"synthetic-failed-secret"* ]]
  [[ "$stderr" != *"synthetic-failed-secret"* ]]
  printf '%s\n' "$output" | jq -e '
    .status == "uncertain" and
    .comment_id == null and
    .comment_reference == "unknown" and
    (.message | contains("do not retry automatically"))
  ' >/dev/null
  [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  body_path="$(sed -n '8p' "$ACLI_ARGS")"
  [ ! -e "$body_path" ]
}

@test "publisher rejects multiple, partial, and mismatched create results" {
  digest="$(jq -r '.body_digest' "$ENVELOPE")"
  responses=(
    '{"results":[{"status":"SUCCESS","id":"TEST-123"},{"status":"SUCCESS","id":"TEST-123"}],"totalCount":2,"successCount":2}'
    '{"results":[{"status":"SUCCESS","id":"TEST-123"}],"totalCount":2,"successCount":1}'
    '{"results":[{"status":"SUCCESS","id":"TEST-124"}],"totalCount":1,"successCount":1}'
  )
  for response in "${responses[@]}"; do
    rm -f "$ACLI_LOG"
    export ACLI_RESPONSE="$response"
    run --separate-stderr "$SCRIPT" "$ENVELOPE" --key TEST-123 --expected-digest "$digest" --write
    [ "$status" -eq 5 ]
    printf '%s\n' "$output" | jq -e '.status == "uncertain" and .comment_id == null' >/dev/null
    [ "$(wc -l <"$ACLI_LOG" | tr -d ' ')" -eq 1 ]
  done
}
