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
