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
