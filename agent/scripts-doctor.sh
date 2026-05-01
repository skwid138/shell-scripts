#!/usr/bin/env bash
# scripts-doctor — health-check the shell-scripts ecosystem.
#
# Audits both ~/code/scripts (public layer) and ~/code/wpromote/scripts
# (Wpromote layer) for invariants the rest of the project assumes.
#
# Per-script checks (applied to agent/ and personal/):
#   - has a matching tests/<basename>.bats suite
#   - accepts --help and exits 0
#   - uses 'set -uo pipefail' (NOT '-e')
#   - sources lib/common.sh (or lib/detect.sh, which loads it transitively)
#
# Repo-level checks:
#   - required & recommended tooling installed
#   - CI workflow exists and pins actions/checkout to a major version
#
# Why agent/ and personal/ but not shell/ or lib/:
#   - shell/  — sourced by ~/.zshrc (init scripts, aliases). Not invoked
#               directly; --help is meaningless.
#   - lib/    — sourced by other scripts (helpers like die_*, require_cmd).
#               Not invoked directly; --help is meaningless.
#   - agent/  — user-facing CLIs invoked by humans / opencode. Full audit.
#   - personal/ — user-facing CLIs (treated first-class). Full audit, with
#                 a temporary LEGACY_PERSONAL_ALLOWLIST for scripts that
#                 predate the policy (pending Phase 10 of NEOVIM-TMUX-PLAN).
#
# Exits 0 if all checks pass, 1 otherwise.
# Outputs JSON to stdout when --json is set, human-readable text otherwise.
#
# The script is read-only and safe to invoke at any time.

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts-doctor [options]

Audit both shell-scripts repos for project-wide invariants.

Options:
  --json              Output structured JSON instead of text.
  --repo PATH         Audit a single repo path (defaults to both known repos).
                      Can be passed multiple times.
  --skip-make         Skip 'make check' delegation (faster; default behavior).
                      Reserved for future when --with-make is added.
  -h, --help          Show this help.

Output:
  Text mode (default): grouped checks with pass/fail, summary line, exit code.
  JSON mode: {version: 1, checks: [...], summary: {...}, ok: bool}.

Exit codes:
  0   All checks passed.
  1   One or more checks failed.
  3   Missing dependency (this script needs jq for JSON mode).

Examples:
  scripts-doctor
  scripts-doctor --json | jq '.summary'
  scripts-doctor --repo ~/code/scripts
EOF
}

# --- arg parsing ---

JSON=0
REPOS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --json)
      JSON=1
      shift
      ;;
    --repo)
      [[ -n "${2-}" ]] || die_usage "--repo needs a path"
      REPOS+=("$2")
      shift 2
      ;;
    --skip-make)
      shift
      ;;
    -*)
      die_usage "unknown flag: $1"
      ;;
    *)
      die_usage "unexpected argument: $1"
      ;;
  esac
done

# Default: audit both known repos that exist.
if [[ ${#REPOS[@]} -eq 0 ]]; then
  for candidate in "$HOME/code/scripts" "$HOME/code/wpromote/scripts"; do
    if [[ -d "$candidate" ]]; then
      REPOS+=("$candidate")
    fi
  done
fi

[[ ${#REPOS[@]} -gt 0 ]] || die "No repos to check (passed paths don't exist)."

# --- preflight ---

if [[ "$JSON" -eq 1 ]]; then
  require_cmd "jq"
fi

# --- check accumulator ---
# Each check appends a JSON object to CHECKS_JSON_FILE (one per line).
# Format: {"repo":"...","name":"...","status":"pass|fail|warn","detail":"..."}

CHECKS_JSON_FILE="$(mktemp)"
trap 'rm -f "$CHECKS_JSON_FILE"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

record() {
  local repo="$1" name="$2" status="$3" detail="${4:-}"
  case "$status" in
    pass) PASS_COUNT=$((PASS_COUNT + 1)) ;;
    fail) FAIL_COUNT=$((FAIL_COUNT + 1)) ;;
    warn) WARN_COUNT=$((WARN_COUNT + 1)) ;;
  esac
  if [[ "$JSON" -eq 1 ]]; then
    jq -n --arg repo "$repo" --arg name "$name" --arg status "$status" --arg detail "$detail" \
      '{repo: $repo, name: $name, status: $status, detail: $detail}' \
      >>"$CHECKS_JSON_FILE"
  else
    local symbol
    case "$status" in
      pass) symbol="✓" ;;
      fail) symbol="✗" ;;
      warn) symbol="!" ;;
    esac
    if [[ -n "$detail" ]]; then
      printf '  %s %-50s %s\n' "$symbol" "$name" "$detail"
    else
      printf '  %s %s\n' "$symbol" "$name"
    fi
  fi
}

# --- check: tooling ---

check_tooling() {
  [[ "$JSON" -eq 0 ]] && echo "tooling:"
  local cmd
  for cmd in bash shellcheck shfmt jq git; do
    if command -v "$cmd" >/dev/null 2>&1; then
      record "_global" "tool: $cmd" "pass" "$(command -v "$cmd")"
    else
      record "_global" "tool: $cmd" "fail" "not on PATH (required)"
    fi
  done
  for cmd in gh acli gcloud gitleaks; do
    if command -v "$cmd" >/dev/null 2>&1; then
      record "_global" "tool: $cmd" "pass" "$(command -v "$cmd")"
    else
      record "_global" "tool: $cmd" "warn" "not on PATH (recommended)"
    fi
  done
  # bash version: warn if /bin/bash is 3.x (project policy is to support
  # it, so this is informational, not failing).
  local bash_ver
  bash_ver="$(/bin/bash -c 'echo "$BASH_VERSION"' 2>/dev/null || echo "unknown")"
  case "$bash_ver" in
    3.*) record "_global" "/bin/bash version" "warn" "$bash_ver (project supports this; agent scripts should be portable)" ;;
    [4-9].*) record "_global" "/bin/bash version" "pass" "$bash_ver" ;;
    *) record "_global" "/bin/bash version" "warn" "$bash_ver (unrecognized)" ;;
  esac
}

# --- per-script checks ---

check_script_help() {
  local repo="$1" script="$2" name
  name="$(basename "$script")"
  if "$script" --help >/dev/null 2>&1; then
    record "$repo" "$name: --help exits 0" "pass"
  else
    record "$repo" "$name: --help exits 0" "fail" "rc=$?"
  fi
}

check_script_strict_mode() {
  local repo="$1" script="$2" name
  name="$(basename "$script")"
  # Forbidden: any 'set' line whose flags include '-e' (alone or combined,
  # like '-euo pipefail'). Search anywhere (some scripts conditionally
  # apply set inside an if-block, so anchoring to BOL would miss them).
  if grep -qE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$script" 2>/dev/null; then
    record "$repo" "$name: no 'set -e'" "fail" "uses 'set -e…' (CONVENTIONS forbids)"
  elif grep -qE '^[[:space:]]*set[[:space:]]+-uo[[:space:]]+pipefail' "$script" 2>/dev/null; then
    record "$repo" "$name: strict mode" "pass" "set -uo pipefail"
  else
    record "$repo" "$name: strict mode" "warn" "no 'set -uo pipefail' line found"
  fi
}

check_script_sources_common() {
  local repo="$1" script="$2" name
  name="$(basename "$script")"
  # Accept either an explicit 'source .../lib/common.sh' OR a 'source
  # .../lib/detect.sh' (which transitively loads common.sh via the
  # load-guard in common.sh). Both give the script access to the die_*
  # family.
  if grep -qE 'source.*lib/(common|detect)\.sh' "$script"; then
    record "$repo" "$name: sources lib (common/detect)" "pass"
  else
    record "$repo" "$name: sources lib (common/detect)" "warn" "no lib/common.sh or lib/detect.sh source line (no die_* helpers)"
  fi
}

check_script_has_test() {
  local repo="$1" script="$2" name base test_file
  name="$(basename "$script")"
  base="${name%.sh}"
  test_file="$repo/tests/$base.bats"
  if [[ -f "$test_file" ]]; then
    record "$repo" "$name: has bats suite" "pass" "$test_file"
  else
    record "$repo" "$name: has bats suite" "fail" "expected $test_file"
  fi
}

# --- per-repo orchestration ---

# Legacy personal/ scripts that predate the per-script invariant policy.
# Listed by basename (with .sh). Failures on these scripts are downgraded
# to a single warn ("legacy personal script") so they don't break CI but
# stay visible.
#
# Currently empty: all previously-listed legacy personal/ scripts have been
# brought up to standard as of Phase 10 of NEOVIM-TMUX-PLAN. The
# is_legacy_personal() helper and the warn-branch logic in check_repo()
# remain in place defensively in case future legacy entries need to be
# tolerated temporarily.
#
# When a script needs to be added back here (e.g. a hand-written one-off
# imported into personal/), list its basename below. When it is brought up
# to standard (--help exits 0, 'set -uo pipefail', sources lib/common.sh,
# has bats suite), remove its entry so it's audited fully going forward.
LEGACY_PERSONAL_ALLOWLIST=()

is_legacy_personal() {
  local name="$1" entry
  # bash 3.2 (the system /bin/bash on macOS) errors on "${arr[@]}" expansion of
  # an empty array under `set -u`. The `${arr[@]+...}` parameter-expansion form
  # is the portable idiom: it expands to nothing when the array is empty/unset
  # and to the array contents otherwise. Fixed in bash 4.4+ but we target 3.2.
  for entry in ${LEGACY_PERSONAL_ALLOWLIST[@]+"${LEGACY_PERSONAL_ALLOWLIST[@]}"}; do
    [[ "$name" == "$entry" ]] && return 0
  done
  return 1
}

check_repo() {
  local repo="$1"
  if [[ "$JSON" -eq 0 ]]; then
    echo
    echo "$repo:"
  fi

  if [[ ! -d "$repo/agent" ]]; then
    record "$repo" "agent/ directory" "warn" "no agent/ dir; skipping per-script checks"
    return
  fi
  record "$repo" "agent/ directory" "pass"

  # CI workflow invariant.
  local ci="$repo/.github/workflows/ci.yml"
  if [[ -f "$ci" ]]; then
    record "$repo" "CI workflow exists" "pass"
    if grep -qE 'actions/checkout@v[0-9]+' "$ci"; then
      record "$repo" "CI pins actions/checkout" "pass" "$(grep -oE 'actions/checkout@v[0-9]+' "$ci" | head -1)"
    else
      record "$repo" "CI pins actions/checkout" "fail" "no actions/checkout@vN pin found"
    fi
  else
    record "$repo" "CI workflow exists" "fail" "no $ci"
  fi

  # Per-script checks for agent/ — full standard, no allowlist.
  local script
  for script in "$repo/agent"/*.sh; do
    [[ -f "$script" ]] || continue
    check_script_help "$repo" "$script"
    check_script_strict_mode "$repo" "$script"
    check_script_sources_common "$repo" "$script"
    check_script_has_test "$repo" "$script"
  done

  # Per-script checks for personal/ — same invariants apply (this repo
  # treats personal/ as first-class), but legacy scripts are temporarily
  # exempt via LEGACY_PERSONAL_ALLOWLIST. Recurses into subdirectories
  # because some personal/ scripts live in subdirs (docker_rollback/, etc.).
  if [[ -d "$repo/personal" ]]; then
    while IFS= read -r script; do
      [[ -f "$script" ]] || continue
      local name
      name="$(basename "$script")"
      if is_legacy_personal "$name"; then
        record "$repo" "$name (personal, legacy)" "warn" \
          "legacy personal script — refactor pending Phase 10 of NEOVIM-TMUX-PLAN"
        continue
      fi
      check_script_help "$repo" "$script"
      check_script_strict_mode "$repo" "$script"
      check_script_sources_common "$repo" "$script"
      check_script_has_test "$repo" "$script"
    done < <(find "$repo/personal" -name '*.sh' -type f 2>/dev/null)
  fi
}

# --- run ---

if [[ "$JSON" -eq 0 ]]; then
  echo "scripts-doctor: auditing ${#REPOS[@]} repo(s)"
  echo
fi

check_tooling
for repo in "${REPOS[@]}"; do
  check_repo "$repo"
done

# --- output / summary ---

OK="true"
[[ "$FAIL_COUNT" -gt 0 ]] && OK="false"

if [[ "$JSON" -eq 1 ]]; then
  jq -n \
    --slurpfile checks "$CHECKS_JSON_FILE" \
    --argjson pass "$PASS_COUNT" \
    --argjson fail "$FAIL_COUNT" \
    --argjson warn "$WARN_COUNT" \
    --argjson ok "$OK" \
    '{version: 1, ok: $ok, summary: {pass: $pass, fail: $fail, warn: $warn}, checks: $checks}'
else
  echo
  echo "summary: $PASS_COUNT pass, $FAIL_COUNT fail, $WARN_COUNT warn"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    echo "result: FAIL"
  else
    echo "result: OK"
  fi
fi

[[ "$FAIL_COUNT" -eq 0 ]] || exit 1
