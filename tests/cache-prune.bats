#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# CLI tests for personal/cache-prune.sh.
#
# Every test runs the script under `env -i` with HOME redirected to a temp
# dir and PATH replaced (via CACHE_PRUNE_BASE_PATH) by a stub dir plus system
# dirs, so no real docker/orb/uv/pnpm/npm/launchctl/osascript is reachable.
# Every stub appends its full argv to $CALLS; assertions classify those argv
# lines independently of the script's own allowlist.
#
# macOS-only: the script parses Docker timestamps with BSD `/bin/date -j`
# and installs a launchd agent. Skipped on Linux CI runners.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  [[ "$(uname -s)" == "Darwin" ]] || skip "cache-prune is macOS-only (BSD date, launchd)"

  SCRIPT="$BATS_TEST_DIRNAME/../personal/cache-prune.sh"
  T="$BATS_TEST_TMPDIR"
  FAKE_HOME="$T/home"
  STUBS="$T/stubs"
  FIX="$T/fix"
  CALLS="$T/calls.log"
  mkdir -p "$FAKE_HOME" "$STUBS" "$FIX"
  : >"$CALLS"
  : >"$FIX/images.txt"
  : >"$FIX/containers.txt"

  # Controlled clock: 2026-10-08T00:00:00Z.
  NOW="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%S' '2026-10-08T00:00:00' +%s)"
  TIMEOUT=30
  NODE_VER="24.15.0"

  write_default_stubs
  install_node "$NODE_VER"
  set_nvm_default "$NODE_VER"
}

# --- stub plumbing -----------------------------------------------------------

# make_stub <path> <body...>: executable bash stub that records argv first.
make_stub() {
  local path="$1" name
  shift
  name="$(basename "$path")"
  {
    printf '#!/bin/bash\n'
    printf 'printf "%%s\\n" "%s $*" >>"$CALLS"\n' "$name"
    printf '%s\n' "$@"
  } >"$path"
  chmod +x "$path"
}

write_default_stubs() {
  make_stub "$STUBS/orb" \
    'if [[ "${1-}" == "status" ]]; then echo Running; exit "$(cat "$FIX/orb_rc" 2>/dev/null || echo 0)"; fi' \
    'exit 0'
  write_docker_stub
  make_stub "$STUBS/uv" \
    'case "$*" in' \
    '  "cache dir") [[ -f "$FIX/break_log_on_uv_dir" ]] && chmod 000 "$HOME/Library/Logs/cache-prune.log"; echo "$HOME/.cache/uv" ;;' \
    '  "cache prune") exit "$(cat "$FIX/uv_prune_rc" 2>/dev/null || echo 0)" ;;' \
    'esac' 'exit 0'
  make_stub "$STUBS/python3" 'echo "Package index page cache size: 1 MB"' 'exit "$(cat "$FIX/pip_rc" 2>/dev/null || echo 0)"'
  make_stub "$STUBS/poetry" 'echo "PyPI"' 'exit 0'
  make_stub "$STUBS/rustup" 'if [[ -f "$FIX/rustup_sleep" ]]; then sleep "$(cat "$FIX/rustup_sleep")"; fi' 'echo "stable-aarch64-apple-darwin (default)"' 'exit 0'
  make_stub "$STUBS/xcrun" 'exit 1'
  make_stub "$STUBS/osascript" 'exit 0'
  make_stub "$STUBS/launchctl" \
    'case "${1-}" in' \
    '  print) exit "$(cat "$FIX/launchctl_print_rc" 2>/dev/null || echo 113)" ;;' \
    '  bootstrap) exit "$(cat "$FIX/launchctl_bootstrap_rc" 2>/dev/null || echo 0)" ;;' \
    '  bootout) exit "$(cat "$FIX/launchctl_bootout_rc" 2>/dev/null || echo 0)" ;;' \
    'esac' 'exit 0'
}

# Docker stub backed by two fixture tables that use the same pipe-delimited
# layout the script's --format templates produce:
#   images.txt:     Id|Created|Size|tag1 tag2 |ndigests|compose-project|compose-service
#   containers.txt: Id|ImageId|State|FinishedAt|/name|compose-project|compose-service
# fail_<key> files force a failure of that inventory call.
write_docker_stub() {
  cat >"$STUBS/docker" <<'EOF'
#!/bin/bash
printf '%s\n' "docker $*" >>"$CALLS"
[[ "${1-}" == "--context" ]] && shift 2
fail() { [[ -f "$FIX/fail_$1" ]] && { echo "Error: forced $1 failure" >&2; exit 1; }; }
pick() { # print fixture rows whose first field matches one of the ID args
  local table="$1" id found
  shift
  for id in "$@"; do
    found="$(awk -F'|' -v id="$id" '$1 == id' "$table")"
    [[ -n "$found" ]] || { echo "Error: No such object: $id" >&2; exit 1; }
    printf '%s\n' "$found"
  done
}
args=("$@")
nonflag_ids() { local a; for a in "$@"; do [[ "$a" == sha256:* || "$a" =~ ^[0-9a-f]{64}$ ]] && printf '%s\n' "$a"; done; }
case "$1 ${2-}" in
  "ps -aq") fail ps; awk -F'|' 'NF{print $1}' "$FIX/containers.txt" ;;
  "container inspect") fail container_inspect; ids=(); while IFS= read -r i; do ids+=("$i"); done < <(nonflag_ids "$@"); pick "$FIX/containers.txt" "${ids[@]}" ;;
  "image ls")
    fail image_ls
    if [[ "$*" == *"dangling=true"* ]]; then
      awk -F'|' 'NF && $4 == "" {print $1}' "$FIX/images.txt"
    else
      # One row per tag x digest, like `docker image ls --digests` duplication.
      awk -F'|' 'NF && $4 != "" { n = split($4, t, " "); d = ($5 > 0 ? $5 : 1); for (i = 1; i <= n; i++) for (j = 1; j <= d; j++) print $1 }' "$FIX/images.txt"
    fi ;;
  "image inspect")
    if [[ "${3-}" == "--format" && "${4-}" == "{{.Id}}" ]]; then
      # Pre-rm re-resolution of a single tag. $FIX/reresolve ("tag|answer")
      # overrides; answer FAIL makes the lookup error.
      [[ -f "$FIX/break_log_on_reresolve" ]] && chmod 000 "$HOME/Library/Logs/cache-prune.log"
      ans="$(awk -F'|' -v t="$5" '$1 == t {print $2}' "$FIX/reresolve" 2>/dev/null)"
      [[ "$ans" == "FAIL" ]] && { echo "Error: No such image: $5" >&2; exit 1; }
      [[ -n "$ans" ]] || ans="$(awk -F'|' -v t="$5" '{ n = split($4, a, " "); for (i = 1; i <= n; i++) if (a[i] == t) print $1 }' "$FIX/images.txt")"
      [[ -n "$ans" ]] || { echo "Error: No such image: $5" >&2; exit 1; }
      echo "$ans"
      exit 0
    fi
    [[ -f "$FIX/break_log_on_image_inspect" ]] && chmod 000 "$HOME/Library/Logs/cache-prune.log"
    fail image_inspect; ids=(); while IFS= read -r i; do ids+=("$i"); done < <(nonflag_ids "$@"); pick "$FIX/images.txt" "${ids[@]}" ;;
  "image rm")
    # Untag in the fixture; drop the row when no tags remain unless
    # rm_leaves_dangling (then the image lingers untagged = dangling).
    awk -F'|' -v OFS='|' -v t="${3-}" -v keep="$([[ -f "$FIX/rm_leaves_dangling" ]] && echo 1)" '{
      if (NF > 1) { n = split($4, a, " "); r = ""; for (i = 1; i <= n; i++) if (a[i] != t) r = r a[i] " "; if ($4 != "" && r == "") { if (keep != "1") next; $5 = 0 }; $4 = r }
      print }' "$FIX/images.txt" >"$FIX/images.tmp" && mv "$FIX/images.tmp" "$FIX/images.txt"
    echo "Untagged: ${3-}" ;;
  "image prune") echo "Total reclaimed space: 0B" ;;
  "builder prune") echo "Total:	0B" ;;
  "system df") printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\nImages 1 1 1GB 0B (0%%)\n' ;;
  "buildx du")
    if [[ -f "$FIX/buildx_du.txt" ]]; then cat "$FIX/buildx_du.txt"; else printf 'ID RECLAIMABLE SIZE LAST ACCESSED\nabc true 1.5GB* 3 months ago\ndef true 500MB 2 months ago\n'; fi ;;
esac
exit 0
EOF
  chmod +x "$STUBS/docker"
}

install_node() {
  local ver="$1" bin="$FAKE_HOME/.nvm/versions/node/v$1/bin"
  mkdir -p "$bin"
  make_stub "$bin/npm" \
    'printf "%s\n" "npm-path $0" >>"$CALLS"' \
    'case "$*" in "config get cache") echo "$HOME/.npm" ;; "cache verify") exit "$(cat "$FIX/npm_verify_rc" 2>/dev/null || echo 0)" ;; esac' \
    'exit 0'
  make_stub "$bin/pnpm" \
    'printf "%s\n" "pnpm-path $0" >>"$CALLS"' \
    'printf "%s\n" "pnpm-env DOWNLOAD_PROMPT=${COREPACK_ENABLE_DOWNLOAD_PROMPT-unset} NETWORK=${COREPACK_ENABLE_NETWORK-unset} PROJECT_SPEC=${COREPACK_ENABLE_PROJECT_SPEC-unset} DEFAULT_TO_LATEST=${COREPACK_DEFAULT_TO_LATEST-unset} PWD=$PWD" >>"$CALLS"' \
    'case "$*" in "store path") echo "$HOME/Library/pnpm/store/v10" ;; esac' \
    'exit 0'
}

set_nvm_default() {
  mkdir -p "$FAKE_HOME/.nvm/alias"
  printf '%s\n' "$1" >"$FAKE_HOME/.nvm/alias/default"
}

# run_prune [args...]: minimal env, /bin/bash (3.2), no stdin.
run_prune() {
  run env -i HOME="$FAKE_HOME" CALLS="$CALLS" FIX="$FIX" \
    CACHE_PRUNE_BASE_PATH="$STUBS:/usr/bin:/bin:/usr/sbin:/sbin" \
    CACHE_PRUNE_NOW="$NOW" CACHE_PRUNE_TIMEOUT="$TIMEOUT" \
    /bin/bash "$SCRIPT" "$@" </dev/null
}

# ISO-8601 UTC timestamp N days before NOW (with fractional seconds).
days_ago() {
  /bin/date -j -u -r "$((NOW - $1 * 86400))" '+%Y-%m-%dT%H:%M:%S.123456789Z'
}

# Independent mutation classifier: prints any recorded argv that mutates.
mutating_calls() {
  grep -E '^docker .* (image rm|rmi|image prune|builder prune|system prune|volume [a-z]+|container (rm|prune|stop|kill))( |$)|^docker --context [^ ]+ (rm|stop|kill)( |$)|^uv cache (prune|clean)|^pnpm store prune|^npm cache (verify|clean)|^launchctl (bootstrap|bootout|enable|kickstart)' "$CALLS" || true
}

# --- help / usage ------------------------------------------------------------

@test "cache-prune: --help exits 0 and documents modes" {
  run_prune --help
  assert_success
  assert_output --partial "Usage: cache-prune"
  assert_output --partial "--apply"
  assert_output --partial "--install"
  assert_output --partial "--uninstall"
}

# --- dry-run safety ----------------------------------------------------------

@test "cache-prune: dry-run inventories docker but makes zero mutating calls" {
  printf '%s\n' "sha256:$(printf 'a%.0s' {1..64})|$(days_ago 200)|1000|hello-world:latest |1||" >"$FIX/images.txt"
  run_prune
  assert_success
  assert_output --partial "hello-world:latest"
  assert_output --partial "dry-run"
  grep -q '^docker --context orbstack image inspect' "$CALLS"
  run mutating_calls
  assert_output ""
}

@test "cache-prune: every docker call is pinned to --context orbstack and preceded by orb status" {
  printf '%s\n' "sha256:$(printf 'a%.0s' {1..64})|$(days_ago 200)|1000|hello-world:latest |1||" >"$FIX/images.txt"
  run_prune --apply --no-notify
  run grep -c '^docker ' "$CALLS"
  local docker_n="$output"
  [[ "$docker_n" -gt 0 ]]
  run grep -vc '^docker --context orbstack ' <(grep '^docker ' "$CALLS")
  assert_output "0"
  # Each docker call is immediately preceded by an `orb status` gate.
  run awk '/^docker /{ if (prev != "orb status") bad++ } { prev = $0 } END { print bad + 0 }' "$CALLS"
  assert_output "0"
  # Bare `orb` (no subcommand) is never run.
  run grep -cx 'orb ' "$CALLS"
  assert_output "0"
}

# --- OrbStack gate -----------------------------------------------------------

@test "cache-prune: orb status exit 1 or 2 means zero docker calls" {
  printf '%s\n' "sha256:$(printf 'a%.0s' {1..64})|$(days_ago 200)|1000|hello-world:latest |1||" >"$FIX/images.txt"
  local rc
  for rc in 1 2; do
    : >"$CALLS"
    echo "$rc" >"$FIX/orb_rc"
    run_prune --apply --no-notify
    run grep -c '^docker' "$CALLS"
    assert_output "0"
    run grep -c '^orb status' "$CALLS"
    assert_output "1"
  done
}

@test "cache-prune: missing orb means zero docker calls but other steps still run" {
  rm -f "$STUBS/orb"
  run_prune --apply --no-notify
  assert_output --partial "orb not found"
  run grep -c '^docker' "$CALLS"
  assert_output "0"
  grep -q '^uv cache prune$' "$CALLS"
}

# --- tagged image policy -----------------------------------------------------

# Distinct leading digits so 12-char short IDs and ID-prefix keep entries differ.
id_of() { printf 'sha256:%02d%062d' "$1" 0; }
short_of() { printf '%02d%010d' "$1" 0; }
cid_of() { printf 'c%02d%061d' "$1" 0; }

write_policy_fixture() {
  local old
  old="$(days_ago 200)"
  {
    printf '%s\n' "$(id_of 1)|$old|100|postgres:18.4 |1|polaris|postgres"     # running container
    printf '%s\n' "$(id_of 2)|$old|100|redis:6 |1|polaris|redis"              # stopped container
    printf '%s\n' "$(id_of 3)|$old|100|golang:1.25 golang:1.25-bookworm |1||" # one alias keep-listed
    printf '%s\n' "$(id_of 4)|$old|100|polaris-api:latest |0|polaris|api"     # no RepoDigests
    printf '%s\n' "$(id_of 5)|not-a-date|100|weird:1 |1||"                    # malformed Created
    printf '%s\n' "$(id_of 6)|$(days_ago 90)|100|boundary:90 |1||"            # exactly 90d
    printf '%s\n' "$(id_of 7)|$(days_ago 91)|100|old:91 |1||"                 # 91d -> removed
    printf '%s\n' "$(id_of 8)|$old|100|dup:a dup:b |2||"                      # duplicate digest rows
    printf '%s\n' "$(id_of 9)|$old|100|pinned:1 |1||"                         # keep-listed by ID prefix
    printf '%s\n' "$(id_of 10)|$(days_ago 40)|100||0|polaris|api"             # dangling > 30d
    printf '%s\n' "$(id_of 11)|$(days_ago 10)|100||0|polaris|web"             # dangling < 30d
  } >"$FIX/images.txt"
  {
    printf '%s\n' "$(cid_of 1)|$(id_of 1)|running|0001-01-01T00:00:00Z|/polaris-postgres-1|polaris|postgres"
    printf '%s\n' "$(cid_of 2)|$(id_of 2)|exited|$(days_ago 3)|/polaris-redis-1|polaris|redis"
  } >"$FIX/containers.txt"
  mkdir -p "$FAKE_HOME/.config/cache-prune"
  printf '%s\n' "# keep these" "golang:1.25" "$(short_of 9)" >"$FAKE_HOME/.config/cache-prune/keep-images"
}

@test "cache-prune: --apply removes exactly the eligible tags, one rm per tag, never forced" {
  write_policy_fixture
  run_prune --apply --no-notify
  assert_success
  run grep -E '^docker .* (image rm|rmi)( |$)' "$CALLS"
  assert_output "$(printf '%s\n' \
    'docker --context orbstack image rm old:91' \
    'docker --context orbstack image rm dup:a' \
    'docker --context orbstack image rm dup:b')"
  run grep -E -- '(^docker .*(image rm|rmi).*( -f| --force))' "$CALLS"
  assert_output ""
}

@test "cache-prune: dry-run explains every tagged image's eligibility" {
  write_policy_fixture
  run_prune
  assert_success
  assert_line --regexp '^  no .*postgres:18\.4 .*in use by polaris-postgres-1\(running\)'
  assert_line --regexp '^  no .*redis:6 .*in use by polaris-redis-1\(exited\)'
  assert_line --regexp '^  no .*golang:1\.25 golang:1\.25-bookworm .*keep-listed'
  assert_line --regexp '^  no .*polaris-api:latest .*no RepoDigests'
  assert_line --regexp '^  no .*weird:1 .*unparseable Created'
  assert_line --regexp '^  no .*boundary:90 .*age 90d <= 90d'
  assert_line --regexp '^  yes .*old:91 .*all criteria met'
  assert_line --regexp '^  yes .*dup:a dup:b .*all criteria met'
  assert_line --regexp '^  no .*pinned:1 .*keep-listed'
  run mutating_calls
  assert_output ""
}

@test "cache-prune: dry-run lists every dangling image older than 30d with labels and size" {
  write_policy_fixture
  run_prune
  assert_success
  assert_line --regexp "^  $(short_of 10) +$(days_ago 40) +polaris/api +100B"
  refute_output --partial "$(days_ago 10)"
  assert_output --partial "1 dangling images older than 30d"
}

@test "cache-prune: prune commands use -f and until=720h, never -a, never volumes or containers" {
  write_policy_fixture
  run_prune --apply --no-notify
  grep -qx 'docker --context orbstack image prune -f --filter until=720h' "$CALLS"
  grep -qx 'docker --context orbstack builder prune -f --filter until=720h' "$CALLS"
  run grep -E -- '( -a( |$)| --all( |$)| volume | system prune|^docker --context orbstack (rm|stop|kill|container (rm|prune|stop|kill)) )' "$CALLS"
  assert_output ""
}

@test "cache-prune: inventory failures fail closed (no tagged removals) but prunes still run" {
  local key
  for key in ps container_inspect image_ls image_inspect; do
    write_policy_fixture
    : >"$CALLS"
    rm -f "$FIX"/fail_*
    touch "$FIX/fail_$key"
    run_prune --apply --no-notify
    assert_failure 1
    assert_output --partial "fail-closed"
    run grep -cE '^docker .* image rm ' "$CALLS"
    assert_output "0"
    grep -qx 'docker --context orbstack builder prune -f --filter until=720h' "$CALLS"
  done
}

# --- nvm default resolution --------------------------------------------------

# Which node bin did npm run from? (stub records "npm-path <abs path>")
npm_bin_used() { sed -n 's#^npm-path .*/versions/node/\(v[^/]*\)/bin/npm$#\1#p' "$CALLS" | sort -u; }

@test "cache-prune: nvm default exact version selects that bin" {
  install_node 24.2.0
  set_nvm_default "24.15.0"
  run_prune --apply --no-notify
  run npm_bin_used
  assert_output "v24.15.0"
}

@test "cache-prune: nvm partial versions match whole components and pick the highest" {
  install_node 24.2.0
  install_node 24.9.1
  install_node 240.0.0
  set_nvm_default "24"
  run_prune --apply --no-notify
  run npm_bin_used
  assert_output "v24.15.0"

  : >"$CALLS"
  set_nvm_default "v24.9"
  run_prune --apply --no-notify
  run npm_bin_used
  assert_output "v24.9.1"
}

@test "cache-prune: nvm alias chain is followed (default -> lts/* -> lts/krypton -> 24)" {
  install_node 22.1.0
  mkdir -p "$FAKE_HOME/.nvm/alias/lts"
  echo "lts/krypton" >"$FAKE_HOME/.nvm/alias/lts/*"
  echo "24" >"$FAKE_HOME/.nvm/alias/lts/krypton"
  set_nvm_default "lts/*"
  run_prune --apply --no-notify
  run npm_bin_used
  assert_output "v24.15.0"
}

@test "cache-prune: nvm alias cycle or missing default skips npm/pnpm but docker and uv still run" {
  local setup_case
  for setup_case in cycle missing unsupported; do
    printf '%s\n' "$(printf 'sha256:%064d' 1)|$(days_ago 200)|1000|hello-world:latest |1||" >"$FIX/images.txt"
    : >"$CALLS"
    case "$setup_case" in
      cycle)
        echo "b" >"$FAKE_HOME/.nvm/alias/a"
        echo "a" >"$FAKE_HOME/.nvm/alias/b"
        set_nvm_default "a"
        ;;
      missing) rm -f "$FAKE_HOME/.nvm/alias/default" ;;
      unsupported) set_nvm_default "system" ;;
    esac
    run_prune --apply --no-notify
    case "$setup_case" in
      cycle) assert_output --partial "alias cycle at 'a'" ;;
      missing) assert_output --partial "alias 'default' not found" ;;
      unsupported) assert_output --partial "unsupported or empty alias 'system'" ;;
    esac
    assert_output --partial "[skip] npm: nvm default node unresolved"
    run grep -cE '^(npm|pnpm)' "$CALLS"
    assert_output "0"
    grep -q '^uv cache prune$' "$CALLS"
    grep -q '^docker --context orbstack image rm hello-world:latest$' "$CALLS"
  done
}

# --- Corepack / failure isolation --------------------------------------------

# cwd is $HOME (writable; pnpm writes a probe file into cwd, so read-only `/`
# fails with EROFS), never the caller's project directory.
@test "cache-prune: pnpm runs with Corepack offline env from a neutral cwd" {
  run_prune --apply --no-notify
  run grep '^pnpm-env' "$CALLS"
  assert_line "pnpm-env DOWNLOAD_PROMPT=0 NETWORK=0 PROJECT_SPEC=0 DEFAULT_TO_LATEST=0 PWD=$FAKE_HOME"
  grep -q '^pnpm store prune$' "$CALLS"
}

@test "cache-prune: pnpm unavailable offline is a logged failure, no prune, other steps continue" {
  local bin="$FAKE_HOME/.nvm/versions/node/v$NODE_VER/bin"
  make_stub "$bin/pnpm" 'echo "Usage Error: network access disabled by COREPACK_ENABLE_NETWORK" >&2' 'exit 1'
  run_prune --apply --no-notify
  assert_failure 1
  assert_output --partial "[fail] pnpm: pnpm store path exited 1"
  run grep -c '^pnpm store prune' "$CALLS"
  assert_output "0"
  grep -q '^npm cache verify$' "$CALLS"
  grep -q '^docker --context orbstack builder prune' "$CALLS"
}

@test "cache-prune: one failing step does not stop later steps and the exit is nonzero" {
  echo 1 >"$FIX/uv_prune_rc"
  echo 1 >"$FIX/npm_verify_rc"
  run_prune --apply --no-notify
  assert_failure 1
  assert_output --partial "[fail] uv: uv cache prune exited 1"
  assert_output --partial "[fail] npm: npm cache verify exited 1"
  grep -q '^pnpm store prune$' "$CALLS"
  grep -q '^docker --context orbstack image prune -f --filter until=720h$' "$CALLS"
  assert_output --partial "finished with 2 failed/timed-out step(s)"
}

# --- report-only -------------------------------------------------------------

@test "cache-prune: report-only section covers pip, poetry, npx, nvm, rustup, simulators, Library/Caches" {
  mkdir -p "$FAKE_HOME/.npm/_npx/abc" "$FAKE_HOME/Library/Caches/big" "$FAKE_HOME/Library/Caches/small"
  head -c 300000 /dev/zero >"$FAKE_HOME/Library/Caches/big/blob"
  head -c 1000 /dev/zero >"$FAKE_HOME/Library/Caches/small/blob"
  install_node 22.1.0
  run_prune
  assert_success
  assert_output --partial "== Report only"
  assert_output --partial "[success] report:pip"
  assert_output --partial "[success] report:poetry"
  assert_output --partial "[success] report:npx"
  assert_output --partial "v22.1.0"
  assert_output --partial "v24.15.0 (default)"
  assert_output --partial "[success] report:rustup"
  assert_output --partial "report:simulators"
  assert_line --regexp '^ +[0-9.]+ (KB|MB) +big$'
  run grep -E '^(python3|poetry|rustup|xcrun) ' "$CALLS"
  assert_line "python3 -m pip cache info"
  assert_line "poetry cache list"
  assert_line "rustup toolchain list"
  run mutating_calls
  assert_output ""
}

@test "cache-prune: rustup is found in ~/.cargo/bin when not on PATH" {
  rm -f "$STUBS/rustup"
  mkdir -p "$FAKE_HOME/.cargo/bin"
  make_stub "$FAKE_HOME/.cargo/bin/rustup" 'echo "stable-aarch64-apple-darwin (default)"'
  run_prune
  assert_success
  assert_output --partial "[success] report:rustup"
  assert_output --partial "stable-aarch64-apple-darwin (default)"
}

@test "cache-prune: unreadable Library/Caches entries mark the listing incomplete" {
  mkdir -p "$FAKE_HOME/Library/Caches/locked/inner"
  chmod 000 "$FAKE_HOME/Library/Caches/locked"
  run_prune
  chmod 755 "$FAKE_HOME/Library/Caches/locked"
  assert_output --partial "incomplete"
}

@test "cache-prune: runs under /bin/bash 3.2 with an empty environment and no stdin" {
  [[ "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}')" == "3" ]] || skip "/bin/bash is not 3.x on this host"
  run_prune
  assert_success
  assert_output --partial "bash 3.2"
}

# --- watchdog ----------------------------------------------------------------

@test "cache-prune: a hung report command is killed by the watchdog and reported as timeout" {
  echo 30 >"$FIX/rustup_sleep"
  TIMEOUT=2
  local start=$SECONDS
  run_prune
  assert_failure 1
  assert_output --partial "[timeout] report:rustup"
  [[ $((SECONDS - start)) -lt 15 ]]
}

@test "cache-prune: fast commands do not wait for the watchdog timer" {
  TIMEOUT=60
  local start=$SECONDS
  run_prune
  assert_success
  [[ $((SECONDS - start)) -lt 20 ]]
}

@test "cache-prune: a failing report command is reported as fail, not success" {
  echo 1 >"$FIX/pip_rc"
  run_prune
  assert_failure 1
  assert_output --partial "[fail] report:pip"
  refute_output --partial "[success] report:pip"
}

# --- lock --------------------------------------------------------------------

LOCK() { printf '%s' "$FAKE_HOME/Library/Caches/cache-prune.lock"; }

write_lock_owner() { # <pid> <host>
  mkdir -p "$(LOCK)"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$1" "$2" "$NOW" >"$(LOCK)/owner"
}

@test "cache-prune: a live lock holder makes a second run skip with exit 75 and touch nothing" {
  sleep 60 &
  local holder=$!
  write_lock_owner "$holder" "$(/bin/hostname)"
  run_prune --apply --no-notify
  kill "$holder" 2>/dev/null
  assert_failure 75
  assert_output --partial "lock"
  run mutating_calls
  assert_output ""
  [[ -f "$(LOCK)/owner" ]]
}

@test "cache-prune: ambiguous lock ownership (no owner file, other host) is not reclaimed" {
  mkdir -p "$(LOCK)"
  run_prune --apply --no-notify
  assert_failure 75
  [[ -d "$(LOCK)" ]]

  rm -rf "$(LOCK)"
  write_lock_owner 999999 "some-other-host"
  : >"$CALLS"
  run_prune --apply --no-notify
  assert_failure 75
  run mutating_calls
  assert_output ""
}

@test "cache-prune: a clearly stale lock (same host, dead pid) is reclaimed and released on exit" {
  sleep 0 &
  local dead=$!
  wait "$dead"
  write_lock_owner "$dead" "$(/bin/hostname)"
  run_prune
  assert_success
  assert_output --partial "stale lock"
  [[ ! -e "$(LOCK)" ]]
}

# age_path <path> <hours>: set mtime N hours in the past (real clock).
age_path() { touch -t "$(/bin/date -v-"$2"H +%Y%m%d%H%M.%S)" "$1"; }

@test "cache-prune: failing to publish lock owner metadata releases the lock, exits 1, mutates nothing, notifies" {
  write_policy_fixture
  cat >"$STUBS/mv" <<'EOF'
#!/bin/bash
case "${@: -1}" in */cache-prune.lock/owner) exit 1 ;; esac
exec /bin/mv "$@"
EOF
  chmod +x "$STUBS/mv"
  run_prune --apply
  assert_failure 1
  [[ ! -e "$(LOCK)" ]]
  run mutating_calls
  assert_output ""
  run grep '^osascript' "$CALLS"
  assert_output --partial "lock"
  rm "$STUBS/mv"
  run_prune
  assert_success
}

@test "cache-prune: a crash mid-publish (only owner.tmp.* left) blocks while fresh, is reclaimed once stale" {
  mkdir -p "$(LOCK)"
  printf 'pid=1\n' >"$(LOCK)/owner.tmp.4242"
  run_prune
  assert_failure 75
  age_path "$(LOCK)" 7
  run_prune
  assert_success
  assert_output --partial "reclaiming"
  [[ ! -e "$(LOCK)" ]]
}

@test "cache-prune: an ambiguous lock older than 6h is reclaimed" {
  mkdir -p "$(LOCK)"
  age_path "$(LOCK)" 7
  run_prune
  assert_success
  [[ ! -e "$(LOCK)" ]]
}

@test "cache-prune: a dead-pid lock with leftover owner.tmp.* is reclaimed" {
  sleep 0 &
  local dead=$!
  wait "$dead"
  write_lock_owner "$dead" "$(/bin/hostname)"
  printf 'x\n' >"$(LOCK)/owner.tmp.777"
  run_prune
  assert_success
  [[ ! -e "$(LOCK)" ]]
}

@test "cache-prune: --apply notifies when a live lock has been held for more than a day" {
  sleep 60 &
  local holder=$!
  mkdir -p "$(LOCK)"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$holder" "$(/bin/hostname)" "$(($(/bin/date -u +%s) - 3600))" >"$(LOCK)/owner"
  run_prune --apply
  assert_failure 75
  run grep -c '^osascript' "$CALLS"
  assert_output "0"
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$holder" "$(/bin/hostname)" "$(($(/bin/date -u +%s) - 2 * 86400))" >"$(LOCK)/owner"
  run_prune --apply
  kill "$holder" 2>/dev/null
  assert_failure 75
  run grep '^osascript' "$CALLS"
  assert_output --partial "lock held"
  run mutating_calls
  assert_output ""
}

@test "cache-prune: a normal run releases its own lock" {
  run_prune
  assert_success
  [[ ! -e "$(LOCK)" ]]
}

# --- log ---------------------------------------------------------------------

LOGF() { printf '%s' "$FAKE_HOME/Library/Logs/cache-prune.log"; }

@test "cache-prune: writes an authoritative log with df before/after and the summary" {
  write_policy_fixture
  run_prune --apply --no-notify
  assert_success
  [[ -f "$(LOGF)" ]]
  grep -q 'Summary (apply)' "$(LOGF)"
  grep -q 'removed tag old:91' "$(LOGF)"
  grep -q 'df -h / (before; not a measure of freed space)' "$(LOGF)"
  grep -q 'df -h / (after; not a measure of freed space)' "$(LOGF)"
  grep -q 'measured cache reclaim' "$(LOGF)"
}

@test "cache-prune: log above the cap is rotated to .1" {
  mkdir -p "$(dirname "$(LOGF)")"
  head -c 1100000 /dev/zero | tr '\0' 'x' >"$(LOGF)"
  run_prune
  assert_success
  [[ -f "$(LOGF).1" ]]
  [[ "$(/usr/bin/stat -f %z "$(LOGF)")" -lt 1048576 ]]
}

@test "cache-prune: --apply refuses destructive steps when the log cannot be written" {
  write_policy_fixture
  mkdir -p "$(LOGF)" # a directory where the log file should be
  run_prune --apply --no-notify
  assert_failure 1
  assert_output --partial "log is not writable"
  run mutating_calls
  assert_output ""
}

@test "cache-prune: dry-run still completes when the log cannot be written" {
  mkdir -p "$(LOGF)"
  run_prune
  assert_success
  assert_output --partial "cannot write log file"
}

# --- notification ------------------------------------------------------------

@test "cache-prune: --apply sends one best-effort notification with a summary" {
  write_policy_fixture
  run_prune --apply
  assert_success
  run grep '^osascript ' "$CALLS"
  assert_output --regexp '^osascript -e display notification "Cache prune: freed ~[0-9.]+ GB · 3 image tags removed · 1 items to review" with title "cache-prune"$'
}

@test "cache-prune: dry-run and --no-notify never notify; osascript failure does not change the exit" {
  run_prune
  run_prune --apply --no-notify
  run grep -c '^osascript' "$CALLS"
  assert_output "0"
  make_stub "$STUBS/osascript" 'exit 1'
  run_prune --apply
  assert_success
}

# --- install / uninstall -----------------------------------------------------

PLIST() { printf '%s' "$FAKE_HOME/Library/LaunchAgents/com.skwid138.cache-prune.plist"; }
plist_get() { /usr/bin/plutil -extract "$1" "${2:-json}" -o - "$(PLIST)"; }

@test "cache-prune: --install renders a lint-clean plist and bootstraps it (never kickstart)" {
  run_prune --install
  assert_success
  [[ -f "$(PLIST)" ]]
  /usr/bin/plutil -lint "$(PLIST)"
  local script_abs
  script_abs="$(cd "$BATS_TEST_DIRNAME/../personal" && pwd)/cache-prune.sh"
  run plist_get ProgramArguments
  assert_output "[\"\/bin\/bash\",\"${script_abs//\//\\/}\",\"--apply\"]"
  run plist_get Label raw
  assert_output "com.skwid138.cache-prune"
  run plist_get StartCalendarInterval
  assert_output '{"Day":1,"Hour":10,"Minute":0}'
  run plist_get RunAtLoad raw
  assert_output "false"
  run plist_get KeepAlive
  assert_failure
  run plist_get EnvironmentVariables.PATH raw
  assert_output "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
  run plist_get EnvironmentVariables.HOME raw
  assert_output "$FAKE_HOME"
  run plist_get StandardOutPath raw
  assert_output "$FAKE_HOME/Library/Logs/cache-prune.launchd.log"
  [[ -d "$FAKE_HOME/Library/Logs" ]]
  local uid
  uid="$(id -u)"
  run grep '^launchctl' "$CALLS"
  assert_output "$(printf '%s\n' \
    "launchctl print gui/$uid/com.skwid138.cache-prune" \
    "launchctl enable gui/$uid/com.skwid138.cache-prune" \
    "launchctl bootstrap gui/$uid $(PLIST)")"
}

@test "cache-prune: --install XML-escapes HOME and boots out an already-loaded agent first" {
  FAKE_HOME="$T/h&o<me"
  mkdir -p "$FAKE_HOME"
  echo 0 >"$FIX/launchctl_print_rc"
  run_prune --install
  assert_success
  /usr/bin/plutil -lint "$(PLIST)"
  run plist_get EnvironmentVariables.HOME raw
  assert_output "$FAKE_HOME"
  run grep -E '^launchctl (bootout|bootstrap)' "$CALLS"
  assert_line --index 0 --regexp '^launchctl bootout gui/[0-9]+/com\.skwid138\.cache-prune$'
  assert_line --index 1 --regexp '^launchctl bootstrap '
}

@test "cache-prune: --install removes the rendered plist when bootstrap fails" {
  echo 5 >"$FIX/launchctl_bootstrap_rc"
  run_prune --install
  assert_failure 1
  [[ ! -e "$(PLIST)" ]]
}

@test "cache-prune: --uninstall with no agent loaded succeeds and removes any plist" {
  mkdir -p "$(dirname "$(PLIST)")"
  echo '<plist/>' >"$(PLIST)"
  run_prune --uninstall
  assert_success
  [[ ! -e "$(PLIST)" ]]
  run grep -c '^launchctl bootout' "$CALLS"
  assert_output "0"
}

@test "cache-prune: --uninstall fails when bootout of a loaded agent fails" {
  echo 0 >"$FIX/launchctl_print_rc"
  echo 5 >"$FIX/launchctl_bootout_rc"
  run_prune --uninstall
  assert_failure 1
}

@test "cache-prune: refuses to run as root" {
  make_stub "$STUBS/id" 'if [[ "${1-}" == "-u" ]]; then echo 0; else /usr/bin/id "$@"; fi'
  run_prune --install
  assert_failure 1
  assert_output --partial "refusing to run as root"
  run grep -c '^launchctl' "$CALLS"
  assert_output "0"
}

# --- builder cache estimate --------------------------------------------------

@test "cache-prune: builder estimate counts only reclaimable records last used more than 30 days ago" {
  cat >"$FIX/buildx_du.txt" <<'DU'
ID                           RECLAIMABLE   SIZE       LAST ACCESSED
old1                         true          1.5GB*     3 months ago
old2                         true          500MB      5 weeks ago
old3                         true          1GB        2 years ago
new1                         true          9GB        4 weeks ago
new2                         true          9GB        10 hours ago
new3                         true          9GB        About an hour ago
busy                         false         9GB        11 months ago
Shared:     15.18GB
Private:    2.427GB
Reclaimable:    17.61GB
Total:      17.61GB
DU
  run_prune
  assert_success
  assert_output --partial "estimate: 3 of 7 records last used >30d ago, ~3.00GB"
  assert_output --partial "Total:      17.61GB"
}

# --- log becomes unwritable mid-run ------------------------------------------

@test "cache-prune: log turning unwritable before the first destructive step refuses every mutation" {
  write_policy_fixture
  touch "$FIX/break_log_on_uv_dir" # chmod 000 the open log during `uv cache dir`
  run_prune --apply --no-notify
  chmod 644 "$(LOGF)"
  assert_failure 1
  assert_output --partial "log write failed"
  run mutating_calls
  assert_output ""
}

@test "cache-prune: log failing mid-run stops later destructive steps (including each image rm)" {
  write_policy_fixture
  touch "$FIX/break_log_on_image_inspect" # breaks after uv/pnpm/npm already ran
  run_prune --apply --no-notify
  chmod 644 "$(LOGF)"
  assert_failure 1
  grep -q '^uv cache prune$' "$CALLS"
  run grep -E '^docker .* (image rm|image prune|builder prune)( |$)' "$CALLS"
  assert_output ""
}

# --- keep-list must fail closed ----------------------------------------------

@test "cache-prune: an unreadable keep-list (mode 000) fails closed: zero image rm" {
  write_policy_fixture
  chmod 000 "$FAKE_HOME/.config/cache-prune/keep-images"
  run_prune --apply --no-notify
  chmod 644 "$FAKE_HOME/.config/cache-prune/keep-images"
  assert_failure 1
  assert_output --partial "keep-list"
  assert_output --partial "fail-closed"
  run grep -cE '^docker .* image rm ' "$CALLS"
  assert_output "0"
}

@test "cache-prune: a keep-list path that is a directory fails closed: zero image rm" {
  write_policy_fixture
  rm -f "$FAKE_HOME/.config/cache-prune/keep-images"
  mkdir -p "$FAKE_HOME/.config/cache-prune/keep-images"
  run_prune --apply --no-notify
  assert_failure 1
  assert_output --partial "[fail] docker:tagged-images"
  run grep -cE '^docker .* image rm ' "$CALLS"
  assert_output "0"
}

@test "cache-prune: an absent keep-list protects nothing and is not an error" {
  write_policy_fixture
  rm -f "$FAKE_HOME/.config/cache-prune/keep-images"
  run_prune --apply --no-notify
  assert_success
  grep -qx 'docker --context orbstack image rm pinned:1' "$CALLS"
}

# --- re-resolve each tag immediately before removal ---------------------------

@test "cache-prune: each image rm is preceded by a gated re-resolve of that tag to the eligible ID" {
  write_policy_fixture
  run_prune --apply --no-notify
  assert_success
  # Among docker calls, every `image rm X` directly follows `image inspect --format {{.Id}} X`.
  run awk '/^docker /{ if ($0 ~ / image rm /) { t = $NF; if (prev != "docker --context orbstack image inspect --format {{.Id}} " t) bad++ } prev = $0 } END { print bad + 0 }' "$CALLS"
  assert_output "0"
  run grep -c ' image rm ' "$CALLS"
  assert_output "3"
}

@test "cache-prune: a tag that now resolves to a different image is skipped, others still removed" {
  write_policy_fixture
  printf '%s\n' "old:91|$(id_of 42)" >"$FIX/reresolve"
  run_prune --apply --no-notify
  assert_success
  assert_output --partial "skipped old:91"
  refute_line --partial "removed tag old:91"
  run grep -E ' image rm ' "$CALLS"
  assert_output "$(printf '%s\n' 'docker --context orbstack image rm dup:a' 'docker --context orbstack image rm dup:b')"
}

@test "cache-prune: a failed re-resolve skips that tag and fails the step" {
  write_policy_fixture
  printf '%s\n' "dup:a|FAIL" >"$FIX/reresolve"
  run_prune --apply --no-notify
  assert_failure 1
  run grep -E ' image rm ' "$CALLS"
  assert_output "$(printf '%s\n' 'docker --context orbstack image rm old:91' 'docker --context orbstack image rm dup:b')"
}

@test "cache-prune: log failing during the pre-rm re-resolve refuses that rm and everything after" {
  write_policy_fixture
  touch "$FIX/break_log_on_reresolve"
  run_prune --apply --no-notify
  chmod 644 "$(LOGF)"
  assert_failure 1
  run grep -E '^docker .* (image rm|image prune|builder prune)( |$)' "$CALLS"
  assert_output ""
}

# --- dangling list honesty ---------------------------------------------------

@test "cache-prune: --apply logs a dangling-candidates snapshot right before image prune, after tagged removals" {
  write_policy_fixture
  touch "$FIX/rm_leaves_dangling" # tagged removals leave old:91 and dup:* behind untagged
  run_prune --apply --no-notify
  assert_success
  assert_output --partial "dangling candidates snapshot immediately before image prune, after tagged removals (Docker selects the final set; container-referenced rows are retained)"
  assert_line --regexp "^  $(short_of 7) "
  assert_line --regexp "^  $(short_of 8) "
  assert_line --regexp "^  $(short_of 10) "
  assert_output --partial "3 dangling images older than 30d"
  # Ordering: last tagged removal < re-inventory heading < prune command.
  local rm_at head_at prune_at
  rm_at="$(grep -n 'removed tag dup:b' <<<"$output" | cut -d: -f1)"
  head_at="$(grep -n 'dangling candidates snapshot immediately before image prune' <<<"$output" | cut -d: -f1)"
  prune_at="$(grep -n 'running: docker --context orbstack image prune -f --filter until=720h' <<<"$output" | cut -d: -f1)"
  [[ -n "$rm_at" && -n "$head_at" && -n "$prune_at" ]]
  [[ "$rm_at" -lt "$head_at" && "$head_at" -lt "$prune_at" ]]
  # The dangling inventory immediately precedes the prune among docker calls (no -a).
  run awk '/^docker /{ if ($0 ~ / image prune /) print prev; prev = $0 }' "$CALLS"
  assert_output --regexp '^docker --context orbstack image inspect --format '
  grep -qx 'docker --context orbstack image prune -f --filter until=720h' "$CALLS"
}

@test "cache-prune: dry-run notes that --apply re-inventories dangling images and the list may grow" {
  write_policy_fixture
  run_prune
  assert_success
  assert_output --partial "--apply re-inventories dangling images immediately before pruning"
  assert_output --partial "Docker itself selects what image prune removes"
  refute_output --partial "exact list"
}

# --- Docker template contract ------------------------------------------------
# The parser and the --format templates must agree on field order and
# separators. These constants are the contract; the fixture rows below were
# captured verbatim (read-only) from live `docker --context orbstack
# image|container inspect --format <template>` on 2026-10-08.

EXPECTED_LABEL_P='{{with index . "Config"}}{{with index . "Labels"}}{{with index . "com.docker.compose.project"}}{{.}}{{end}}{{end}}{{end}}'
EXPECTED_LABEL_S='{{with index . "Config"}}{{with index . "Labels"}}{{with index . "com.docker.compose.service"}}{{.}}{{end}}{{end}}{{end}}'
EXPECTED_IMAGE_FORMAT="{{.Id}}|{{.Created}}|{{.Size}}|{{with index . \"RepoTags\"}}{{range .}}{{.}} {{end}}{{end}}|{{with index . \"RepoDigests\"}}{{len .}}{{else}}0{{end}}|$EXPECTED_LABEL_P|$EXPECTED_LABEL_S"
EXPECTED_CONTAINER_FORMAT="{{.Id}}|{{.Image}}|{{.State.Status}}|{{.State.FinishedAt}}|{{.Name}}|$EXPECTED_LABEL_P|$EXPECTED_LABEL_S"

write_live_capture_fixture() {
  cat >"$FIX/images.txt" <<'ROWS'
sha256:eb84fdc6f2a3a064445bb2a2fbc89c515666c428d6c96b6ab68a4cd218819688|2026-03-23T21:34:00.012553343Z|5200|hello-world:latest |1||
sha256:ce99a442106f423cffb47bb1e8e29e04267ce359e7a45061f109b73d54839226|2026-10-08T11:56:18.703484087-05:00|2278551936|polaris-api:latest |0|polaris|api
sha256:18de5bcde97fc5712b85a63936095b45410bec92a0307856378df994b66f7134|2025-11-04T00:29:49.384488867Z|128204042|redis:6 |1||
ROWS
  cat >"$FIX/containers.txt" <<'ROWS'
a8e270ea6a852e15990ae582dfd9949791c61684451de254b0d7b14c18e1a73b|sha256:ce99a442106f423cffb47bb1e8e29e04267ce359e7a45061f109b73d54839226|running|2026-10-08T21:25:57.409781911Z|/polaris-api-1|polaris|api
2e64da9b2a37622f4d8ce38dc9d9d5a0969457e73593acb6f46ed8a123426a78|sha256:18de5bcde97fc5712b85a63936095b45410bec92a0307856378df994b66f7134|exited|2026-10-08T21:25:56.434722421Z|/polaris-redis-1|polaris|redis
ROWS
}

@test "cache-prune: inspect calls pass exactly the contract --format templates" {
  write_live_capture_fixture
  run_prune
  assert_success
  grep -qF "docker --context orbstack image inspect --format $EXPECTED_IMAGE_FORMAT sha256:" "$CALLS"
  grep -qF "docker --context orbstack container inspect --format $EXPECTED_CONTAINER_FORMAT " "$CALLS"
}

@test "cache-prune: rows captured from live docker parse into the right eligibility decisions" {
  write_live_capture_fixture
  run_prune
  assert_success
  assert_line --regexp '^  yes +eb84fdc6f2a3 +198d  hello-world:latest +all criteria met$'
  assert_line --regexp '^  no +ce99a442106f +0d  polaris-api:latest +in use by polaris-api-1\(running\); no RepoDigests \(local build\); age 0d <= 90d$'
  assert_line --regexp '^  no +18de5bcde97f +337d  redis:6 +in use by polaris-redis-1\(exited\)$'
  assert_line --regexp '^  polaris-redis-1 +exited +finished .* compose=polaris/redis image=18de5bcde97f$'
}

# --- late log failure must not exit 0 ----------------------------------------

@test "cache-prune: a log write failure that first occurs inside the summary makes the exit nonzero" {
  write_policy_fixture
  # Pass-through awk that makes the log unwritable once the summary heading
  # has been written. In --apply, summarize's reclaim-totals line calls
  # human_kb -> awk, so that line is the first failed write.
  cat >"$STUBS/awk" <<'STUB'
#!/bin/bash
log="$HOME/Library/Logs/cache-prune.log"
if [[ -f "$FIX/break_log_in_summary" ]] && /usr/bin/grep -q '== Summary' "$log" 2>/dev/null; then
  chmod 000 "$log"
fi
exec /usr/bin/awk "$@"
STUB
  chmod +x "$STUBS/awk"
  touch "$FIX/break_log_in_summary"
  run_prune --apply --no-notify
  chmod 644 "$(LOGF)"
  assert_failure 1
  grep -q '== Summary (apply)' "$(LOGF)"
  run grep -c 'measured cache reclaim' "$(LOGF)"
  assert_output "0"
}

@test "cache-prune: a dry-run whose log stops being writable mid-run exits nonzero" {
  touch "$FIX/break_log_on_uv_dir"
  run_prune
  chmod 644 "$(LOGF)"
  assert_failure 1
  assert_output --partial "log write failed"
  run mutating_calls
  assert_output ""
}

# --- status --------------------------------------------------------------------

@test "cache-prune: --status reports loaded/not loaded and the plist path, mutating nothing" {
  local uid
  uid="$(id -u)"
  run_prune --status
  assert_success
  assert_line "agent: not loaded (gui/$uid/com.skwid138.cache-prune)"
  assert_line "plist: $(PLIST) (absent)"
  echo 0 >"$FIX/launchctl_print_rc"
  mkdir -p "$(dirname "$(PLIST)")"
  echo '<plist/>' >"$(PLIST)"
  run_prune --status
  assert_success
  assert_line "agent: loaded (gui/$uid/com.skwid138.cache-prune)"
  assert_line "plist: $(PLIST) (present)"
  run grep -E '^launchctl (bootstrap|bootout|enable|kickstart)|^(uv|pnpm|npm|docker) ' "$CALLS"
  assert_output ""
}

@test "cache-prune: --status conflicts with other modes" {
  run_prune --status --apply
  assert_failure 2
}
