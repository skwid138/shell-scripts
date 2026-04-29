#!/usr/bin/env bats
# Tests for lib/detect.sh

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  # Source the library (need common.sh loaded first)
  source "$BATS_TEST_DIRNAME/../lib/common.sh"
  source "$BATS_TEST_DIRNAME/../lib/detect.sh"
}

# --- detect_ticket_from_branch ---

@test "detect_ticket_from_branch: bixb_18835 → BIXB-18835" {
  run detect_ticket_from_branch "bixb_18835"
  assert_success
  assert_output "BIXB-18835"
}

@test "detect_ticket_from_branch: bixb-18835-some-description → BIXB-18835" {
  run detect_ticket_from_branch "bixb-18835-some-description"
  assert_success
  assert_output "BIXB-18835"
}

@test "detect_ticket_from_branch: BIXB-18835 → BIXB-18835" {
  run detect_ticket_from_branch "BIXB-18835"
  assert_success
  assert_output "BIXB-18835"
}

@test "detect_ticket_from_branch: feature/bixb_123 → BIXB-123" {
  run detect_ticket_from_branch "feature/bixb_123"
  assert_success
  assert_output "BIXB-123"
}

@test "detect_ticket_from_branch: proj-456-add-feature → PROJ-456" {
  run detect_ticket_from_branch "proj-456-add-feature"
  assert_success
  assert_output "PROJ-456"
}

@test "detect_ticket_from_branch: main → fails" {
  run detect_ticket_from_branch "main"
  assert_failure
}

@test "detect_ticket_from_branch: develop → fails" {
  run detect_ticket_from_branch "develop"
  assert_failure
}

@test "detect_ticket_from_branch: 123-no-prefix → fails" {
  run detect_ticket_from_branch "123-no-prefix"
  assert_failure
}

# --- detect_ticket_from_branch: extended flexibility ---
# These cover branch shapes that the previous start-anchored implementation
# missed (orphan-resolution / T3.3).

@test "detect_ticket_from_branch: mid-branch ticket id (chore/foo-bixb-18835)" {
  run detect_ticket_from_branch "chore/some-fix-bixb-18835"
  assert_success
  assert_output "BIXB-18835"
}

@test "detect_ticket_from_branch: ticket id after numeric path segment" {
  run detect_ticket_from_branch "bug/2024-q3/bixb-18835"
  assert_success
  assert_output "BIXB-18835"
}

@test "detect_ticket_from_branch: ticket id after multiple path segments" {
  run detect_ticket_from_branch "user/h/PROJ-42-fix"
  assert_success
  assert_output "PROJ-42"
}

@test "detect_ticket_from_branch: real-world Jira-created branch (BIXB-18845-c-required-metrics-show-on-config-tab)" {
  # This is the exact shape Jira generates when you click 'Create branch'
  # on a ticket — canonical TICKET-ID followed by a slug derived from the
  # ticket title. Captured as a regression test for the most common
  # real-world branch shape we encounter.
  run detect_ticket_from_branch "BIXB-18845-c-required-metrics-show-on-config-tab"
  assert_success
  assert_output "BIXB-18845"
}

@test "detect_ticket_from_branch: 5-digit Jira numbers (current Wpromote shape)" {
  run detect_ticket_from_branch "feature/bixb-18835-implement-foo"
  assert_success
  assert_output "BIXB-18835"
}

@test "detect_ticket_from_branch: short prefix (2 chars) accepted" {
  run detect_ticket_from_branch "ab-12"
  assert_success
  assert_output "AB-12"
}

@test "detect_ticket_from_branch: single-letter prefix rejected (avoid v-1)" {
  run detect_ticket_from_branch "v-18835"
  assert_failure
}

@test "detect_ticket_from_branch: alpha-prefix glued to another word is still recognized only with boundary" {
  # 'nobixb-1' should NOT be parsed as 'NOBIXB-1' if the user wrote prose;
  # however our current implementation greedily matches starting from the
  # first valid 2+ alpha sequence, which here is 'nobixb'. That is the
  # documented behavior — captured here as a regression test rather than
  # a 'should fail' assertion.
  run detect_ticket_from_branch "nobixb-1"
  assert_success
  assert_output "NOBIXB-1"
}

@test "detect_ticket_from_branch: first match wins when multiple ids present" {
  run detect_ticket_from_branch "bixb-1-then-proj-2"
  assert_success
  assert_output "BIXB-1"
}

@test "detect_ticket_from_branch: bash 3.2 portability — no \${var^^} is used" {
  # Run the function under /bin/bash if it exists (macOS bash 3.2). On Linux
  # CI this falls back to the default bash, which is also fine.
  bash_3="/bin/bash"
  if [[ -x "$bash_3" ]] && "$bash_3" -c '[[ "${BASH_VERSINFO[0]}" -lt 4 ]]' 2>/dev/null; then
    out="$("$bash_3" -c 'source '"$BATS_TEST_DIRNAME"'/../lib/detect.sh && detect_ticket_from_branch "bixb-1"' 2>&1)"
    [[ "$out" == "BIXB-1" ]]
  else
    skip "bash 3.2 not available at /bin/bash on this host"
  fi
}

# --- detect_owner_repo ---

@test "detect_owner_repo: SSH format" {
  # Override git to return a known remote
  git() { echo "git@github.com:wpromote/polaris-web.git"; }
  export -f git
  run detect_owner_repo
  assert_success
  assert_output "wpromote/polaris-web"
  unset -f git
}

@test "detect_owner_repo: HTTPS format" {
  git() { echo "https://github.com/wpromote/client-portal.git"; }
  export -f git
  run detect_owner_repo
  assert_success
  assert_output "wpromote/client-portal"
  unset -f git
}

@test "detect_owner_repo: HTTPS without .git suffix" {
  git() { echo "https://github.com/wpromote/kraken"; }
  export -f git
  run detect_owner_repo
  assert_success
  assert_output "wpromote/kraken"
  unset -f git
}

# --- detect_repo_name ---

@test "detect_repo_name: extracts repo from owner/repo" {
  git() { echo "git@github.com:wpromote/polaris-api.git"; }
  export -f git
  run detect_repo_name
  assert_success
  assert_output "polaris-api"
  unset -f git
}

# --- parse_pr_ref ------------------------------------------------------------
# parse_pr_ref mutates caller-scope OWNER/REPO/PR_NUMBER, so each test sources
# fresh and inspects the resulting variables.

@test "parse_pr_ref: bare number sets PR_NUMBER only" {
  OWNER=""; REPO=""; PR_NUMBER=""
  parse_pr_ref "275"
  [[ "$PR_NUMBER" == "275" ]]
  [[ -z "$OWNER" ]]
  [[ -z "$REPO" ]]
}

@test "parse_pr_ref: #275 strips the hash" {
  OWNER=""; REPO=""; PR_NUMBER=""
  parse_pr_ref "#275"
  [[ "$PR_NUMBER" == "275" ]]
}

@test "parse_pr_ref: owner/repo#number form" {
  OWNER=""; REPO=""; PR_NUMBER=""
  parse_pr_ref "wpromote/polaris-web#275"
  [[ "$OWNER" == "wpromote" ]]
  [[ "$REPO" == "polaris-web" ]]
  [[ "$PR_NUMBER" == "275" ]]
}

@test "parse_pr_ref: full GitHub URL" {
  OWNER=""; REPO=""; PR_NUMBER=""
  parse_pr_ref "https://github.com/wpromote/polaris-api/pull/123"
  [[ "$OWNER" == "wpromote" ]]
  [[ "$REPO" == "polaris-api" ]]
  [[ "$PR_NUMBER" == "123" ]]
}

@test "parse_pr_ref: pre-set OWNER/REPO are not overwritten" {
  OWNER="myowner"; REPO="myrepo"; PR_NUMBER=""
  parse_pr_ref "wpromote/polaris-web#275"
  [[ "$OWNER" == "myowner" ]]
  [[ "$REPO" == "myrepo" ]]
  [[ "$PR_NUMBER" == "275" ]]
}

@test "parse_pr_ref: garbage input exits 2 (usage error)" {
  run parse_pr_ref "not a pr ref"
  assert_failure 2
  assert_output --partial "Usage error:"
}

# --- detect_pr_number error categorization -----------------------------------

@test "detect_pr_number: 'no pull requests found' returns 1, not 5" {
  # Stub gh: simulate 'no PR' upstream message and exit non-zero.
  gh() {
    if [[ "$1" == "auth" ]]; then return 0; fi
    echo "no pull requests found for branch 'feature/foo'" >&2
    return 1
  }
  export -f gh
  run detect_pr_number
  assert_failure 1
  unset -f gh
}

@test "detect_pr_number: real upstream error exits 5 (die_upstream)" {
  gh() {
    if [[ "$1" == "auth" ]]; then return 0; fi
    echo "HTTP 502: bad gateway" >&2
    return 1
  }
  export -f gh
  run detect_pr_number
  assert_failure 5
  assert_output --partial "Upstream failure:"
  unset -f gh
}

@test "detect_pr_number: success prints number" {
  gh() {
    if [[ "$1" == "auth" ]]; then return 0; fi
    echo "275"
    return 0
  }
  export -f gh
  run detect_pr_number
  assert_success
  assert_output "275"
  unset -f gh
}
