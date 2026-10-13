#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for personal/gitleaks-hook.sh and its global git registration.
#
# The hook is registered as a git config hook (`hook.gitleaks.command` +
# `hook.gitleaks.event = pre-commit`) in the private dotfiles .gitconfig.
# tests/fixtures/gitleaks-hook/hook.gitconfig is a byte-for-byte copy of that
# block (serialized by `git config --file`); one test asserts the fixture is
# identical to the dotfiles registration when the dotfiles repo is present,
# and every `git commit` test drives the REAL registered command string from
# the fixture through real git, so a wrapper that swallows the script's exit
# status (e.g. `|| true`) fails the blocking tests.
#
# Every script/git invocation runs under `env -i` with a temp HOME that
# contains spaces, GIT_CONFIG_GLOBAL pointing at a temp config, and a PATH of
# stub dir + pinned git + system dirs. Stub gitleaks records argv/cwd/env.
# Tests that need the real gitleaks binary skip when it is not installed.
#
# Synthetic secrets: generated per test at runtime (never committed), only
# ever written inside $BATS_TEST_TMPDIR, and never echoed by assertions.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../personal/gitleaks-hook.sh"
  SCRIPTS_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/gitleaks-hook/hook.gitconfig"
  DOTFILES_GITCONFIG="${GITLEAKS_HOOK_TEST_DOTFILES:-$HOME/code/dotfiles/git/.gitconfig}"
  REAL_GIT="${GITLEAKS_HOOK_TEST_GIT:-$(command -v git)}"
  REAL_GITLEAKS="$(command -v gitleaks 2>/dev/null || true)"

  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home with spaces"
  STUBS="$T/stubs"
  GITBIN="$T/gitbin"
  FIX="$T/fix"
  CALLS="$T/calls.log"
  GCFG="$T/global gitconfig"
  R="$T/my repo"
  mkdir -p "$FAKE_HOME/code" "$STUBS" "$GITBIN" "$FIX"
  : >"$CALLS"
  ln -s "$REAL_GIT" "$GITBIN/git"
  # $HOME/code/scripts -> this checkout, so the registered command resolves.
  ln -s "$SCRIPTS_ROOT" "$FAKE_HOME/code/scripts"

  {
    printf '[user]\n\tname = Test\n\temail = test@example.com\n'
    printf '[init]\n\tdefaultBranch = main\n'
    printf '[commit]\n\tgpgsign = false\n'
    cat "$FIXTURE"
  } >"$GCFG"

  write_gitleaks_stub
  TPATH="$STUBS:$GITBIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

teardown() {
  # Restore permissions a failed assertion may have left behind.
  /bin/chmod -RN "$BATS_TEST_TMPDIR" 2>/dev/null
  /bin/chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null
  return 0
}

# The shell text the registration must carry, exactly.
EXPECTED_COMMAND='h="$HOME/code/scripts/personal/gitleaks-hook.sh"; if [ ! -e "$h" ]; then echo "gitleaks hook: $h not found, skipping" >&2; exit 0; fi; if [ ! -x "$h" ]; then echo "gitleaks hook: $h not executable" >&2; exit 1; fi; exec "$h" --run'

write_gitleaks_stub() {
  cat >"$STUBS/gitleaks" <<'EOF'
#!/bin/bash
{
  printf 'argv:%s\n' "$*"
  printf 'pwd:%s\n' "$PWD"
  printf 'idx:%s\n' "${GIT_INDEX_FILE-unset}"
  printf 'cfg:%s|%s\n' "${GITLEAKS_CONFIG-unset}" "${GITLEAKS_CONFIG_TOML-unset}"
} >>"$CALLS"
if [[ "${1-}" == "version" ]]; then
  echo "8.30.1"
  exit 0
fi
[[ -x "$FIX/during" ]] && "$FIX/during"
exit "$(cat "$FIX/rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$STUBS/gitleaks"
}

# Feature-detect git config hooks (hook.<name>.command); skip if unsupported.
require_config_hooks() {
  local d="$T/probe"
  env -i PATH="$GITBIN:/usr/bin:/bin" HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
    "$REAL_GIT" init -q "$d" 2>/dev/null || skip "git init failed"
  local out
  # `|| true`: bats runs tests under `set -e`; an old git fails `hook run`
  # (or ignores hook.<name>.*) and must skip, not error.
  out="$(cd "$d" && env -i PATH="$GITBIN:/usr/bin:/bin" HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 \
    GIT_CONFIG_GLOBAL=/dev/null "$REAL_GIT" -c hook.probe.event=pre-commit \
    -c 'hook.probe.command=echo config-hooks-ok' hook run pre-commit 2>&1)" || true
  [[ "$out" == *config-hooks-ok* ]] || skip "$("$REAL_GIT" --version) lacks config-based hooks"
}

require_real_gitleaks() {
  [[ -n "$REAL_GITLEAKS" ]] || skip "gitleaks not installed"
  mkdir -p "$T/realbin"
  ln -sf "$REAL_GITLEAKS" "$T/realbin/gitleaks"
  TPATH="$T/realbin:$GITBIN:/usr/bin:/bin:/usr/sbin:/sbin"
}

# g <args...>: git in the test repo under the hermetic environment.
g() {
  (cd "$R" && env -i HOME="$FAKE_HOME" PATH="$TPATH" GIT_CONFIG_GLOBAL="$GCFG" \
    GIT_CONFIG_NOSYSTEM=1 CALLS="$CALLS" FIX="$FIX" GITLEAKS_HOOK_FALLBACK_PATH= \
    git "$@" </dev/null)
}

# run_hook <args...>: the script directly, from inside the test repo.
run_hook() {
  run --separate-stderr env -i HOME="$FAKE_HOME" PATH="$TPATH" GIT_CONFIG_GLOBAL="$GCFG" \
    GIT_CONFIG_NOSYSTEM=1 CALLS="$CALLS" FIX="$FIX" GITLEAKS_HOOK_FALLBACK_PATH= \
    "${EXTRA_ENV[@]}" /bin/bash -c 'cd "$1" && shift && exec /bin/bash "$@"' _ "${HOOK_CWD:-$R}" "$SCRIPT" "$@"
}
EXTRA_ENV=(TERM=dumb)

init_repo() {
  mkdir -p "$R"
  g init -q .
  echo "base" >"$R/base.txt"
  g add base.txt
  g commit -q --no-verify -m base
}

commit_count() { g rev-list --count HEAD; }

new_key() { printf 'AKIA%s' "$(LC_ALL=C tr -dc 'A-Z2-7' </dev/urandom | head -c 16)"; }

# assert_no_secret <haystack-name> <value>: fails without echoing the secret.
assert_no_secret() {
  if grep -qF -- "$KEY" <<<"$2"; then
    echo "synthetic secret leaked into $1" >&2
    return 1
  fi
}

# --- help / registration -----------------------------------------------------

@test "gitleaks-hook: --help exits 0 and documents --run and --status" {
  run /bin/bash "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: gitleaks-hook"
  assert_output --partial "--run"
  assert_output --partial "--status"
}

@test "gitleaks-hook: unknown argument is a usage error" {
  run /bin/bash "$SCRIPT" --bogus
  assert_failure 2
}

@test "gitleaks-hook: fixture registration round-trips to exactly the intended shell text" {
  run "$REAL_GIT" config --file "$FIXTURE" --get hook.gitleaks.command
  assert_success
  [[ "$output" == "$EXPECTED_COMMAND" ]]
  run "$REAL_GIT" config --file "$FIXTURE" --get-all hook.gitleaks.event
  assert_output "pre-commit"
  # Fail-open only when the script is missing: no status-swallowing.
  [[ "$EXPECTED_COMMAND" != *"|| true"* && "$EXPECTED_COMMAND" != *"; true"* ]]
}

@test "gitleaks-hook: /usr/bin/git parses the fixture to the same shell text" {
  [[ -x /usr/bin/git ]] || skip "no /usr/bin/git"
  /usr/bin/git --version >/dev/null 2>&1 || skip "/usr/bin/git is a stub (no CLT)"
  run /usr/bin/git config --file "$FIXTURE" --get hook.gitleaks.command
  assert_success
  [[ "$output" == "$EXPECTED_COMMAND" ]]
}

@test "gitleaks-hook: dotfiles .gitconfig registration is identical to the fixture" {
  [[ -f "$DOTFILES_GITCONFIG" ]] || skip "dotfiles .gitconfig not present"
  run "$REAL_GIT" config --file "$DOTFILES_GITCONFIG" --get hook.gitleaks.command
  assert_success
  [[ "$output" == "$EXPECTED_COMMAND" ]]
  run "$REAL_GIT" config --file "$DOTFILES_GITCONFIG" --get-all hook.gitleaks.event
  assert_output "pre-commit"
  # The raw serialized block is byte-identical too.
  run awk '/^\[hook "gitleaks"\]/{p=1; print; next} /^\[/{p=0} p' "$DOTFILES_GITCONFIG"
  assert_output "$(cat "$FIXTURE")"
}

# --- --run outcomes (stub gitleaks) ------------------------------------------

@test "gitleaks-hook: --run rc 0 exits 0 with no guidance" {
  init_repo
  echo 0 >"$FIX/rc"
  run_hook --run
  assert_success
  refute_output --partial "rotate"
  [[ "$stderr" != *"Rotate"* && "$stderr" != *"scan error"* ]]
}

@test "gitleaks-hook: --run invokes 'gitleaks git --pre-commit --staged' from the toplevel with exact flags" {
  init_repo
  mkdir -p "$R/sub dir"
  HOOK_CWD="$R/sub dir" run_hook --run
  assert_success
  run grep '^argv:' "$CALLS"
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 ."
  run grep '^pwd:' "$CALLS"
  assert_output "pwd:$(cd "$R" && pwd -P)"
}

@test "gitleaks-hook: --run unsets GITLEAKS_CONFIG/_TOML but preserves GIT_INDEX_FILE" {
  init_repo
  EXTRA_ENV=(GITLEAKS_CONFIG=/x/evil.toml GITLEAKS_CONFIG_TOML='title="x"' GIT_INDEX_FILE="$R/.git/alt-index")
  run_hook --run
  assert_success
  run grep -E '^(cfg|idx):' "$CALLS"
  assert_line "cfg:unset|unset"
  assert_line "idx:$R/.git/alt-index"
}

@test "gitleaks-hook: --run rc 10 blocks (exit 1) with rotation-first guidance" {
  init_repo
  echo 10 >"$FIX/rc"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"otate"* ]]
  [[ "$stderr" == *"gitleaks:allow"* ]]
  [[ "$stderr" == *".gitleaksignore"* ]]
  [[ "$stderr" == *"false positive"* ]]
  [[ "$stderr" == *"--no-verify"* && "$stderr" == *"other"* ]]
  [[ "$stderr" == *"git config hook.gitleaks.enabled false"* ]]
  [[ "$stderr" != *"scan error"* ]]
  # Rotation guidance comes before the allowlist guidance.
  local rot allow
  rot="$(grep -n -i 'rotate' <<<"$stderr" | head -n1 | cut -d: -f1)"
  allow="$(grep -n 'gitleaks:allow' <<<"$stderr" | head -n1 | cut -d: -f1)"
  [[ -n "$rot" && -n "$allow" && "$rot" -lt "$allow" ]]
}

@test "gitleaks-hook: --run rc 1 and rc 126 are scan errors (exit 1), never secret guidance" {
  init_repo
  local rc
  for rc in 1 126 2; do
    echo "$rc" >"$FIX/rc"
    run_hook --run
    assert_failure 1
    [[ "$stderr" == *"gitleaks scan error (not a finding), rc=$rc"* ]]
    [[ "$stderr" != *"gitleaks:allow"* && "$stderr" != *"otate"* && "$stderr" != *".gitleaksignore"* ]]
  done
}

@test "gitleaks-hook: --run with gitleaks missing warns on stderr and exits 0" {
  init_repo
  rm -f "$STUBS/gitleaks"
  run_hook --run
  assert_success
  [[ "$stderr" == *"gitleaks"*"not found"* ]]
}

@test "gitleaks-hook: --run appends the fallback PATH so GUI clients without brew on PATH still scan" {
  init_repo
  mkdir -p "$T/fallback"
  mv "$STUBS/gitleaks" "$T/fallback/gitleaks"
  echo 10 >"$FIX/rc"
  run --separate-stderr env -i HOME="$FAKE_HOME" PATH="$TPATH" CALLS="$CALLS" FIX="$FIX" \
    GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_NOSYSTEM=1 GITLEAKS_HOOK_FALLBACK_PATH="$T/fallback" \
    /bin/bash -c 'cd "$1" && exec /bin/bash "$2" --run' _ "$R" "$SCRIPT"
  assert_failure 1
  grep -q '^argv:git --pre-commit' "$CALLS"
}

@test "gitleaks-hook: --status shows hook config origin, gitleaks version, git path and version" {
  init_repo
  run_hook --status
  assert_success
  assert_output --partial "hook.gitleaks.command"
  assert_output --partial "hook.gitleaks.event pre-commit"
  assert_output --partial "file:$GCFG"
  assert_output --partial "8.30.1"
  assert_output --partial "$GITBIN/git"
  assert_output --regexp "git version [0-9]"
}

@test "gitleaks-hook: --run outside a git work tree is an error, not a pass" {
  mkdir -p "$T/notrepo"
  HOOK_CWD="$T/notrepo" run_hook --run
  assert_failure 1
}

# --- through real git commit, using the REAL registered command ---------------

@test "gitleaks-hook: git commit passes on 0 and blocks on 10, 1, and 126 (HOME and repo with spaces)" {
  require_config_hooks
  init_repo
  local before rc
  echo 0 >"$FIX/rc"
  echo one >"$R/a.txt"
  g add a.txt
  before="$(commit_count)"
  run g commit -q -m ok
  assert_success
  [[ "$(commit_count)" -eq $((before + 1)) ]]
  grep -q '^argv:git --pre-commit --staged' "$CALLS"

  for rc in 10 1 126; do
    echo "$rc" >"$FIX/rc"
    echo "change $rc" >>"$R/a.txt"
    g add a.txt
    before="$(commit_count)"
    run g commit -q -m "blocked $rc"
    assert_failure
    [[ "$(commit_count)" -eq "$before" ]]
  done
}

@test "gitleaks-hook: commit output for rc 10 carries guidance; rc 1 says scan error" {
  require_config_hooks
  init_repo
  echo x >"$R/a.txt"
  g add a.txt
  echo 10 >"$FIX/rc"
  run g commit -q -m x
  assert_failure
  assert_output --partial "gitleaks:allow"
  echo 1 >"$FIX/rc"
  run g commit -q -m x
  assert_failure
  assert_output --partial "gitleaks scan error (not a finding), rc=1"
  refute_output --partial "gitleaks:allow"
}

@test "gitleaks-hook: a missing script warns and the commit succeeds" {
  require_config_hooks
  init_repo
  rm "$FAKE_HOME/code/scripts"
  echo x >"$R/a.txt"
  g add a.txt
  local before
  before="$(commit_count)"
  run g commit -q -m x
  assert_success
  assert_output --partial "gitleaks hook: $FAKE_HOME/code/scripts/personal/gitleaks-hook.sh not found, skipping"
  [[ "$(commit_count)" -eq $((before + 1)) ]]
}

@test "gitleaks-hook: a present but non-executable script blocks the commit (no silent skip)" {
  require_config_hooks
  init_repo
  rm "$FAKE_HOME/code/scripts"
  mkdir -p "$FAKE_HOME/code/scripts/personal"
  cp "$SCRIPT" "$FAKE_HOME/code/scripts/personal/gitleaks-hook.sh"
  chmod 644 "$FAKE_HOME/code/scripts/personal/gitleaks-hook.sh"
  echo x >"$R/a.txt"
  g add a.txt
  local before
  before="$(commit_count)"
  run g commit -q -m x
  assert_failure
  assert_output --partial "gitleaks hook: $FAKE_HOME/code/scripts/personal/gitleaks-hook.sh not executable"
  refute_output --partial "skipping"
  [[ "$(commit_count)" -eq "$before" ]]
}

@test "gitleaks-hook: a dangling script symlink counts as missing (warns, commit succeeds)" {
  require_config_hooks
  init_repo
  rm "$FAKE_HOME/code/scripts"
  mkdir -p "$FAKE_HOME/code/scripts/personal"
  ln -s "$T/nowhere/gitleaks-hook.sh" "$FAKE_HOME/code/scripts/personal/gitleaks-hook.sh"
  echo x >"$R/a.txt"
  g add a.txt
  run g commit -q -m x
  assert_success
  assert_output --partial "not found, skipping"
}

@test "gitleaks-hook: an existing .git/hooks/pre-commit still runs" {
  require_config_hooks
  init_repo
  printf '#!/bin/sh\ntouch "%s"\n' "$T/legacy-ran" >"$R/.git/hooks/pre-commit"
  chmod +x "$R/.git/hooks/pre-commit"
  echo x >"$R/a.txt"
  g add a.txt
  run g commit -q -m x
  assert_success
  [[ -f "$T/legacy-ran" ]]
  grep -q '^argv:git --pre-commit' "$CALLS"
}

@test "gitleaks-hook: a core.hooksPath pre-commit still runs" {
  require_config_hooks
  init_repo
  mkdir -p "$R/.githooks"
  printf '#!/bin/sh\ntouch "%s"\n' "$T/hookspath-ran" >"$R/.githooks/pre-commit"
  chmod +x "$R/.githooks/pre-commit"
  g config core.hooksPath .githooks
  echo x >"$R/a.txt"
  g add a.txt
  run g commit -q -m x
  assert_success
  [[ -f "$T/hookspath-ran" ]]
  grep -q '^argv:git --pre-commit' "$CALLS"
}

@test "gitleaks-hook: --no-verify skips the hook" {
  require_config_hooks
  init_repo
  echo 10 >"$FIX/rc"
  echo x >"$R/a.txt"
  g add a.txt
  : >"$CALLS"
  run g commit -q --no-verify -m x
  assert_success
  run grep -c '^argv:' "$CALLS"
  assert_output "0"
}

@test "gitleaks-hook: per-repo opt-out hook.gitleaks.enabled=false disables it" {
  require_config_hooks
  init_repo
  echo 10 >"$FIX/rc"
  g config hook.gitleaks.enabled false
  echo x >"$R/a.txt"
  g add a.txt
  : >"$CALLS"
  run g commit -q -m x
  assert_success
  run grep -c '^argv:' "$CALLS"
  assert_output "0"
}

# --- index correctness with the real gitleaks binary -------------------------

@test "gitleaks-hook (real gitleaks): staged secret is blocked; worktree-only secret is allowed" {
  require_config_hooks
  require_real_gitleaks
  init_repo
  KEY="$(new_key)"
  printf 'aws_access_key_id = %s\n' "$KEY" >"$R/creds.txt"
  g add creds.txt
  local before
  before="$(commit_count)"
  run g commit -q -m leak
  assert_failure
  assert_no_secret "commit output" "$output"
  [[ "$(commit_count)" -eq "$before" ]]

  # Unstage it: the secret now exists only in the worktree.
  g rm -q --cached creds.txt
  echo safe >"$R/safe.txt"
  g add safe.txt
  run g commit -q -m safe
  assert_success
  assert_no_secret "commit output" "$output"
  run g show --name-only --format= HEAD
  assert_output "safe.txt"
}

@test "gitleaks-hook (real gitleaks): 'git commit fileA' uses a temp index, so fileB's staged secret is not scanned or committed" {
  require_config_hooks
  require_real_gitleaks
  init_repo
  KEY="$(new_key)"
  echo a0 >"$R/fileA.txt"
  echo b0 >"$R/fileB.txt"
  g add fileA.txt fileB.txt
  g commit -q --no-verify -m files
  printf 'aws_access_key_id = %s\n' "$KEY" >"$R/fileB.txt"
  g add fileB.txt
  echo a1 >"$R/fileA.txt"
  # Semantics: `git commit <paths>` builds a temporary index (HEAD + fileA)
  # and runs the hook with GIT_INDEX_FILE pointing at it. Only fileA is
  # committed, so the hook correctly allows it.
  run g commit -q -m "only A" fileA.txt
  assert_success
  assert_no_secret "commit output" "$output"
  run g show --name-only --format= HEAD
  assert_output "fileA.txt"
  # fileB's secret is still staged and is blocked on the next plain commit.
  run g diff --cached --name-only
  assert_output "fileB.txt"
  run g commit -q -m "now B"
  assert_failure
  assert_no_secret "commit output" "$output"
}

@test "gitleaks-hook (real gitleaks): 'git commit -a' with a modified tracked file containing a secret is blocked" {
  require_config_hooks
  require_real_gitleaks
  init_repo
  KEY="$(new_key)"
  echo clean >"$R/tracked.txt"
  g add tracked.txt
  g commit -q --no-verify -m tracked
  printf 'aws_access_key_id = %s\n' "$KEY" >"$R/tracked.txt"
  local before
  before="$(commit_count)"
  # Nothing staged in the real index; -a stages into index.lock for the hook.
  run g commit -q -a -m "dash a"
  assert_failure
  assert_no_secret "commit output" "$output"
  [[ "$(commit_count)" -eq "$before" ]]
}

@test "gitleaks-hook (real gitleaks): --no-verify bypasses even a real staged secret" {
  require_config_hooks
  require_real_gitleaks
  init_repo
  KEY="$(new_key)"
  printf 'aws_access_key_id = %s\n' "$KEY" >"$R/creds.txt"
  g add creds.txt
  run g commit -q --no-verify -m bypass
  assert_success
}

@test "gitleaks-hook: blocking also works under /usr/bin/git" {
  [[ -x /usr/bin/git ]] && /usr/bin/git --version >/dev/null 2>&1 || skip "no usable /usr/bin/git"
  ln -sf /usr/bin/git "$GITBIN/git"
  REAL_GIT=/usr/bin/git
  require_config_hooks
  init_repo
  echo 10 >"$FIX/rc"
  echo x >"$R/a.txt"
  g add a.txt
  local before
  before="$(commit_count)"
  run g commit -q -m x
  assert_failure
  [[ "$(commit_count)" -eq "$before" ]]
}

# --- private, per-repo suppressions (lib/gitleaks-private.sh) -----------------
#
# Store: $HOME/.config/gitleaks-audit/repos/<rel>/{gitleaks.toml,gitleaksignore}
# where <rel> is the repo's path under ~/code. Test fixtures use synthetic
# paths only.

PR_REL="wp/my app"

# The store validator needs BSD stat and `ls -le` ACLs (macOS only); off macOS
# an existing store fails closed (tested below on Linux runners).
require_darwin() {
  [[ "$(uname -s)" == "Darwin" ]] || skip "private suppression validation is macOS-only"
}

# pstore <rel> [toml] [ignore]: a valid (700/600) private store entry.
pstore() {
  local base="$FAKE_HOME/.config/gitleaks-audit" d p
  d="$base/repos/$1"
  mkdir -p "$d"
  /bin/chmod 700 "$FAKE_HOME/.config" "$base" "$base/repos"
  p="$d"
  while [[ "$p" != "$base/repos" ]]; do
    /bin/chmod 700 "$p"
    p="$(dirname "$p")"
  done
  if [[ -n "${2-}" ]]; then
    printf '%s\n' "$2" >"$d/gitleaks.toml"
    /bin/chmod 600 "$d/gitleaks.toml"
  fi
  if [[ -n "${3-}" ]]; then
    printf '%s\n' "$3" >"$d/gitleaksignore"
    /bin/chmod 600 "$d/gitleaksignore"
  fi
}
pstore_dir() { printf '%s' "$FAKE_HOME/.config/gitleaks-audit/repos/$1"; }

# A repo under ~/code (the default $R is outside it).
init_code_repo() {
  R="$FAKE_HOME/code/$PR_REL"
  init_repo
}

SHAPES_TOML='[extend]
useDefault = true

[[allowlists]]
description = '"'"'design tokens: a JSON "key" member holding 40 lowercase hex'"'"'
targetRules = ['"'"'generic-api-key'"'"']
condition = "AND"
paths = ['"'"'^tools/themes/json/tokens\.json$'"'"']
regexTarget = "line"
regexes = ['"'"'^\n?[ \t]*"key": "[0-9a-f]{40}",?$'"'"']

[[allowlists]]
description = '"'"'schema field metadata data_key names'"'"'
targetRules = ['"'"'generic-api-key'"'"']
condition = "AND"
paths = ['"'"'^src/app(_dsp)?/schema/(models|sb_models)\.py$'"'"']
regexTarget = "line"
regexes = ['"'"'^\n? +(?:[a-z0-9_]+: [A-Za-z\[\]]+ = field\(metadata=\{"data_key": "[A-Za-z0-9]+"\}\)|(?:default=None, )?metadata=\{"data_key": "[A-Za-z0-9]+"\})$'"'"']'

argv_line() { grep '^argv:' "$CALLS" | tail -n1; }

@test "gitleaks-hook: validated private files of a repo under ~/code are passed as --config / --gitleaks-ignore-path" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML" "$(printf '%040d' 7):a.txt:jwt:1"
  run_hook --run
  assert_success
  run argv_line
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 --config $(pstore_dir "$PR_REL")/gitleaks.toml --gitleaks-ignore-path $(pstore_dir "$PR_REL")/gitleaksignore ."
}

@test "gitleaks-hook: only private files that exist are passed; no store means the original argv" {
  require_darwin
  init_code_repo
  run_hook --run
  run argv_line
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 ."
  pstore "$PR_REL"
  run_hook --run
  run argv_line
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 ."
  pstore "$PR_REL" "" "$(printf '%040d' 7):a.txt:jwt:1"
  run_hook --run
  run argv_line
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 --gitleaks-ignore-path $(pstore_dir "$PR_REL")/gitleaksignore ."
  # Another repo's store is never used.
  rm -f "$(pstore_dir "$PR_REL")/gitleaksignore"
  pstore "wp/other" "$SHAPES_TOML"
  run_hook --run
  run argv_line
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 ."
}

@test "gitleaks-hook: an unsafe private store blocks (exit 1) with a store error, never secret guidance, and does not scan" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  /bin/chmod g+w "$(pstore_dir "$PR_REL")/gitleaks.toml"
  : >"$CALLS"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"private suppression store error"* ]]
  [[ "$stderr" == *"writable"* ]]
  [[ "$stderr" != *"otate"* && "$stderr" != *"gitleaks:allow"* ]]
  run grep -c '^argv:' "$CALLS"
  assert_output "0"
  # A grammar violation blocks the same way.
  /bin/chmod 600 "$(pstore_dir "$PR_REL")/gitleaks.toml"
  pstore "$PR_REL" "" "deadbeef:a.txt:jwt:1"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"gitleaksignore"* ]]
}

@test "gitleaks-hook: an unsafe store blocks a real git commit" {
  require_darwin
  require_config_hooks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  /bin/chmod o+w "$FAKE_HOME/.config"
  echo x >"$R/a.txt"
  g add a.txt
  local before
  before="$(commit_count)"
  run g commit -q -m x
  assert_failure
  assert_output --partial "private suppression store error"
  [[ "$(commit_count)" -eq "$before" ]]
}

@test "gitleaks-hook: a repo outside ~/code never consults the store, even a broken one" {
  require_darwin
  init_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  /bin/chmod 777 "$FAKE_HOME/.config/gitleaks-audit"
  run_hook --run
  assert_success
  run argv_line
  assert_output "argv:git --pre-commit --staged --redact=100 --no-banner --exit-code=10 ."
}

@test "gitleaks-hook: a repo .gitleaks.toml (untracked or only in the index) plus a private gitleaks.toml is a collision error" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  echo 'title = "repo"' >"$R/.gitleaks.toml"
  : >"$CALLS"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *".gitleaks.toml"* ]]
  run grep -c '^argv:' "$CALLS"
  assert_output "0"
  g add .gitleaks.toml
  rm "$R/.gitleaks.toml"
  run_hook --run
  assert_failure 1
  # A private gitleaksignore alone is fine next to a repo config.
  g rm -q --cached .gitleaks.toml
  echo 'title = "repo"' >"$R/.gitleaks.toml"
  rm "$(pstore_dir "$PR_REL")/gitleaks.toml"
  pstore "$PR_REL" "" "$(printf '%040d' 7):a.txt:jwt:1"
  run_hook --run
  assert_success
}

@test "gitleaks-hook: a linked worktree uses its main repo's private store" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  g worktree add -q "$FAKE_HOME/code/wp/app-wt" -b wt
  HOOK_CWD="$FAKE_HOME/code/wp/app-wt" run_hook --run
  assert_success
  run argv_line
  assert_output --partial "--config $(pstore_dir "$PR_REL")/gitleaks.toml ."
  run grep '^pwd:' "$CALLS"
  assert_line "pwd:$(cd "$FAKE_HOME/code/wp/app-wt" && pwd -P)"
}

@test "gitleaks-hook: finding guidance's details command carries the private flags" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML" "$(printf '%040d' 7):a.txt:jwt:1"
  echo 10 >"$FIX/rc"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"gitleaks git --pre-commit --staged --redact=100 --verbose --config "*"gitleaks.toml --gitleaks-ignore-path "*"gitleaksignore ."* ]]
  [[ "$stderr" == *"private"* ]]
}

@test "gitleaks-hook: --status reports the private store state for the current repo" {
  require_darwin
  init_code_repo
  run_hook --status
  assert_success
  assert_output --partial "private suppressions: none"
  pstore "$PR_REL" "$SHAPES_TOML"
  run_hook --status
  assert_output --partial "private suppressions: $PR_REL: gitleaks.toml"
  /bin/chmod g+w "$(pstore_dir "$PR_REL")/gitleaks.toml"
  run_hook --status
  assert_success
  assert_output --partial "private suppressions: ERROR"
}

# --- private suppressions with the real gitleaks binary ----------------------

# A fixed 40-hex id, derived at runtime (no literal in this public file);
# random hex sometimes falls under generic-api-key's entropy threshold.
hex40() { printf 'plan-f-fixture-1' | shasum | cut -c1-40; }
alnum() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }
# Fixed data_key names: synthetic, and verified to trip generic-api-key
# (random letter runs often fall under its entropy/stopword filters). The
# control halves of the tests prove they still fire.
DK1=fixtureColumnKqzVw7d
DK2=fixtureColumnPmxRt9d
DK3=fixtureColumnBvzQs4d

# Every synthetic value written by a test is remembered so none can leak.
SECRETS=()
remember() { SECRETS+=("$1"); }
assert_no_secrets() {
  local s
  for s in ${SECRETS[@]+"${SECRETS[@]}"}; do
    if grep -qF -- "$s" <<<"$output$stderr"; then
      echo "synthetic secret leaked into hook output" >&2
      return 1
    fi
  done
}

# stage <path> <content>: write and stage one file in $R.
stage() {
  mkdir -p "$(dirname "$R/$1")"
  printf '%s\n' "$2" >"$R/$1"
  g add -- "$1"
}

# hook_blocks / hook_allows: run the real hook on the staged index.
hook_blocks() {
  run_hook --run
  assert_no_secrets
  [[ "$status" -eq 1 && "$stderr" == *"potential secret(s) in the changes being committed"* &&
    "$stderr" != *"scan error"* && "$stderr" != *"private suppression store error"* ]] || {
    echo "expected the hook to block on a finding, not an error (status=$status)" >&2
    return 1
  }
}
hook_allows() {
  run_hook --run
  assert_no_secrets
  [[ "$status" -eq 0 ]] || {
    echo "expected the hook to allow (status=$status)" >&2
    return 1
  }
}

reset_index() { g reset -q; }

@test "gitleaks-hook (real gitleaks): each content shape is suppressed only with the private store (control: blocked without)" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  local h store
  h="$(hex40)"
  remember "$h"
  remember "$DK1"
  remember "$DK2"
  remember "$DK3"
  store="$(pstore_dir "$PR_REL")"
  local -a cases=(
    "tools/themes/json/tokens.json|{
  \"color\": {
        \"key\": \"$h\",
        \"name\": \"primary\"
  }
}"
    "src/app/schema/models.py|class M:
    clicks_14d: Optional[Decimal] = field(metadata={\"data_key\": \"$DK1\"})"
    "src/app_dsp/schema/sb_models.py|class M:
    other: int = field(
        metadata={\"data_key\": \"$DK2\"}
    )"
    "src/app/schema/models.py|class M:
    third: int = field(
        default=None, metadata={\"data_key\": \"$DK3\"}
    )"
  )
  local c
  for c in "${cases[@]}"; do
    rm -rf "$store"
    stage "${c%%|*}" "${c#*|}"
    hook_blocks
    pstore "$PR_REL" "$SHAPES_TOML"
    hook_allows
    reset_index
    rm -f "$R/${c%%|*}"
  done
}

@test "gitleaks-hook (real gitleaks): default rules still fire with a private config" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  KEY="$(new_key)"
  remember "$KEY"
  stage creds.txt "aws_access_key_id = $KEY"
  hook_blocks
}

@test "gitleaks-hook (real gitleaks): another rule in an allowed path, and a non-matching line in an allowed file, still fire" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  KEY="$(new_key)"
  remember "$KEY"
  stage tools/themes/json/tokens.json "{\"aws\": \"$KEY\"}"
  hook_blocks
  reset_index
  local a
  a="$(alnum 32)"
  remember "$a"
  stage tools/themes/json/tokens.json "{
        \"api_key\": \"$a\",
}"
  hook_blocks
  reset_index
  # The allowed member shape, but not alone on its line.
  local h
  h="$(hex40)"
  remember "$h"
  stage tools/themes/json/tokens.json "{\"key\": \"$h\"}"
  hook_blocks
}

@test "gitleaks-hook (real gitleaks): a second credential on an allowed-shape line still fires (both shapes)" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  local h a
  h="$(hex40)" a="$(alnum 32)"
  remember "$h"
  remember "$a"
  remember "$DK1"
  stage tools/themes/json/tokens.json "{
        \"key\": \"$h\", \"api_key\": \"$a\",
}"
  hook_blocks
  reset_index
  stage src/app/schema/models.py "class M:
    clicks: int = field(metadata={\"data_key\": \"$DK1\"}); api_key = \"$a\""
  hook_blocks
}

@test "gitleaks-hook (real gitleaks): a near-miss file name is not covered by the allowlist" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  local h f
  h="$(hex40)"
  remember "$h"
  # Control: the exact allowed file name is suppressed.
  stage tools/themes/json/tokens.json "{
        \"key\": \"$h\",
}"
  hook_allows
  reset_index
  rm -f "$R/tools/themes/json/tokens.json"
  for f in tools/themes/json/tokens.json.bak xtools/themes/json/tokens.json tools/themes/json/tokensXjson tools/themes/json/sub/tokens.json; do
    stage "$f" "{
        \"key\": \"$h\",
}"
    hook_blocks
    reset_index
  done
}

@test "gitleaks-hook (real gitleaks): the repo .gitleaksignore still suppresses alongside a private config" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  KEY="$(new_key)"
  remember "$KEY"
  stage creds.txt "aws_access_key_id = $KEY"
  hook_blocks
  echo "creds.txt:aws-access-token:1" >"$R/.gitleaksignore"
  hook_allows
}

@test "gitleaks-hook (real gitleaks): store identity - linked worktree shares, submodule is separate, outside ~/code has none" {
  require_darwin
  require_real_gitleaks
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  local h
  h="$(hex40)"
  remember "$h"
  local content="{
        \"key\": \"$h\",
}"
  # Linked worktree: the main repo's store applies.
  g worktree add -q "$FAKE_HOME/code/wp/app-wt" -b wt
  local main_r="$R"
  R="$FAKE_HOME/code/wp/app-wt"
  stage tools/themes/json/tokens.json "$content"
  HOOK_CWD="$R" hook_allows
  # Submodule: its own identity, so the superproject's store does not apply.
  R="$main_r"
  mkdir -p "$T/subsrc"
  (cd "$T/subsrc" && env -i HOME="$FAKE_HOME" PATH="$TPATH" GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_NOSYSTEM=1 \
    git init -q . && env -i HOME="$FAKE_HOME" PATH="$TPATH" GIT_CONFIG_GLOBAL="$GCFG" GIT_CONFIG_NOSYSTEM=1 \
    git commit -q --no-verify --allow-empty -m init)
  g -c protocol.file.allow=always submodule -q add "$T/subsrc" mods/sub
  R="$main_r/mods/sub"
  stage tools/themes/json/tokens.json "$content"
  HOOK_CWD="$R" hook_blocks
  pstore "$PR_REL/mods/sub" "$SHAPES_TOML"
  HOOK_CWD="$R" hook_allows
  # Outside ~/code: no private lookup at all.
  R="$T/outside repo"
  init_repo
  stage tools/themes/json/tokens.json "$content"
  hook_blocks
}

@test "gitleaks-hook: a store that stops validating during the scan blocks (re-validated after gitleaks returns)" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  printf '#!/bin/bash\n/bin/chmod g+w "%s"\n' "$(pstore_dir "$PR_REL")/gitleaks.toml" >"$FIX/during"
  chmod +x "$FIX/during"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"private suppression store"*"changed during the scan"* ]]
  [[ "$stderr" == *"writable"* ]]
  # A private file appearing mid-scan (the scan ran without it) blocks too.
  /bin/chmod 600 "$(pstore_dir "$PR_REL")/gitleaks.toml"
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >"%s"\n/bin/chmod 600 "%s"\n' \
    "$(printf '%040d' 7):a.txt:jwt:1" "$(pstore_dir "$PR_REL")/gitleaksignore" "$(pstore_dir "$PR_REL")/gitleaksignore" >"$FIX/during"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"changed during the scan"* ]]
  # Without a mid-scan change the same store passes.
  rm -f "$FIX/during" "$(pstore_dir "$PR_REL")/gitleaksignore"
  run_hook --run
  assert_success
}

@test "gitleaks-hook: off macOS an existing private store blocks with a macOS-only error (Linux runners)" {
  [[ "$(uname -s)" != "Darwin" ]] || skip "Linux-only; covered on macOS via an OSTYPE override in tests/gitleaks-private.bats"
  init_code_repo
  mkdir -p "$FAKE_HOME/.config/gitleaks-audit/repos/$PR_REL"
  chmod 700 "$FAKE_HOME/.config" "$FAKE_HOME/.config/gitleaks-audit"
  : >"$CALLS"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"require macOS"* ]]
  run grep -c '^argv:' "$CALLS"
  assert_output "0"
  # Repos outside ~/code are unaffected.
  R="$T/outside repo"
  init_repo
  run_hook --run
  assert_success
}

@test "gitleaks-hook: a same-path content change of a private file during the scan blocks (content hashes compared)" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML" "$(printf '%040d' 7):a.txt:jwt:1"
  # Still valid afterwards, same paths: only the content differs.
  printf '#!/bin/bash\necho "# edited mid-scan" >>"%s"\n' "$(pstore_dir "$PR_REL")/gitleaks.toml" >"$FIX/during"
  chmod +x "$FIX/during"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"changed during the scan"* ]]
  printf '#!/bin/bash\necho "# edited mid-scan" >>"%s"\n' "$(pstore_dir "$PR_REL")/gitleaksignore" >"$FIX/during"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"changed during the scan"* ]]
  rm -f "$FIX/during"
  run_hook --run
  assert_success
}

@test "gitleaks-hook: an md5 failure before or after the scan blocks with a 'could not hash' message" {
  require_darwin
  init_code_repo
  pstore "$PR_REL" "$SHAPES_TOML"
  printf '#!/bin/bash\nexit 1\n' >"$T/bad-md5"
  chmod +x "$T/bad-md5"
  EXTRA_ENV=(GITLEAKS_MD5="$T/bad-md5")
  : >"$CALLS"
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"could not hash the private files"* ]]
  run grep -c '^argv:' "$CALLS"
  assert_output "0"
  # Works before the scan, fails after it: still "could not hash", not "changed".
  cat >"$T/flaky-md5" <<EOF
#!/bin/bash
if [[ -e "$T/md5.used" ]]; then exit 1; fi
: >"$T/md5.used"
exec /sbin/md5 "\$@"
EOF
  chmod +x "$T/flaky-md5"
  EXTRA_ENV=(GITLEAKS_MD5="$T/flaky-md5")
  run_hook --run
  assert_failure 1
  [[ "$stderr" == *"could not hash the private files after the scan"* ]]
  [[ "$stderr" != *"content differs"* ]]
}
