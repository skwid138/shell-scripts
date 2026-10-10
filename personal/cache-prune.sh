#!/usr/bin/env bash
# cache-prune.sh — monthly, conservative developer-cache pruning for macOS.
#
# Default is a zero-mutation dry-run that inventories what --apply would do.
# --apply runs an allowlisted set of prune commands (uv, pnpm, npm, Docker via
# OrbStack); everything else is report-only. --install/--uninstall manage a
# per-user launchd agent that runs `--apply` on the 1st of each month.
#
# Designed to run under launchd's minimal environment and macOS /bin/bash 3.2:
# it builds its own PATH, never prompts, and never uses `set -e`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

usage() {
  cat <<'EOF'
Usage: cache-prune [--apply | --install | --uninstall | --status] [--no-notify]

Conservative developer-cache pruning for macOS. Default mode is a dry-run
that performs zero mutations and prints/logs what --apply would do.

Modes:
  (none)        Dry-run: inventory caches, Docker images, and report-only items.
  --apply       Run the allowlisted prune steps:
                  uv cache prune            (never --force)
                  pnpm store prune          (Corepack offline; never downloads)
                  npm cache verify
                  docker image rm <repo:tag>  per eligible tag (never -f)
                  docker image prune -f --filter until=720h   (dangling only)
                  docker builder prune -f --filter until=720h
  --install     Render the launchd template into
                ~/Library/LaunchAgents/com.skwid138.cache-prune.plist and
                bootstrap it (runs --apply on day 1 of each month at 10:00).
  --uninstall   Boot out the launchd agent (absent = OK) and remove the plist.
  --status      Show whether the launchd agent is loaded and the plist path
                (read-only; exits 0).
  -h, --help    Show this help.

Options:
  --no-notify   With --apply, skip the best-effort macOS notification.
                (Dry-runs never notify.)

Docker policy (all calls pinned to `docker --context orbstack`, each one gated
on `orb status` exiting 0; OrbStack is never started):
  A tagged image is removed only if ALL hold:
    1. no container (running or stopped) references its image ID;
    2. it has RepoDigests (i.e. it can be re-pulled);
    3. it was created strictly more than 90 days ago;
    4. none of its tags/ID appear in the keep-list.
  Any container/image inventory error skips tagged removal entirely.
  Volumes are never touched; containers are report-only.

Keep-list: ~/.config/cache-prune/keep-images — one repo:tag or image ID per
line (# comments allowed). Listing any tag protects the whole image ID.

Files:
  Log:   ~/Library/Logs/cache-prune.log (rotated to .1 above 1 MiB; authoritative)
  Lock:  ~/Library/Caches/cache-prune.lock (mkdir lock with owner pid/host/start)

Exit codes:
  0   every step succeeded or was skipped
  1   one or more steps failed or timed out (later steps still ran), or
      install/uninstall failed, or run as root
  2   usage error
  75  another run holds the lock (or lock ownership is ambiguous); nothing done

Environment overrides (tests/advanced use):
  CACHE_PRUNE_BASE_PATH  PATH used instead of the built-in base PATH
                         (nvm default node bin is still prepended)
  CACHE_PRUNE_NOW        epoch seconds to use as "now" for age checks
  CACHE_PRUNE_TIMEOUT    watchdog seconds for inventory/report commands (default 120)
EOF
}

MODE="dry-run"
NOTIFY=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h | --help)
      usage
      exit 0
      ;;
    --apply | --install | --uninstall | --status)
      [[ "$MODE" == "dry-run" ]] || die_usage "only one of --apply/--install/--uninstall/--status may be given"
      MODE="${1#--}"
      shift
      ;;
    --no-notify)
      NOTIFY=0
      shift
      ;;
    *) die_usage "unknown argument: $1 (see --help)" ;;
  esac
done

# --- environment -------------------------------------------------------------

[[ -n "${HOME:-}" && -d "$HOME" ]] || die "HOME is unset or not a directory"

LABEL="com.skwid138.cache-prune"
SYSTEM_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
BASE_PATH="${CACHE_PRUNE_BASE_PATH:-/opt/homebrew/bin:/usr/local/bin:$HOME/.orbstack/bin:$SYSTEM_PATH}"
TIMEOUT="${CACHE_PRUNE_TIMEOUT:-120}"
LOG_FILE="$HOME/Library/Logs/cache-prune.log"
LOG_MAX_BYTES=1048576
KEEP_FILE="$HOME/.config/cache-prune/keep-images"
DOCKER_CTX="orbstack"
IMAGE_MIN_AGE_DAYS=90
PRUNE_UNTIL="720h"
PRUNE_UNTIL_SECS=$((720 * 3600))

# Deterministic Docker target: never let an inherited host/context win.
unset DOCKER_HOST DOCKER_CONTEXT

# Corepack (pnpm shim): never prompt, never hit the network, never honor a
# project's packageManager field, never jump to "latest".
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export COREPACK_ENABLE_NETWORK=0
export COREPACK_ENABLE_PROJECT_SPEC=0
export COREPACK_DEFAULT_TO_LATEST=0

# --- nvm default resolution --------------------------------------------------

NVM_DIR_ROOT="$HOME/.nvm"

# Print installed node versions as "major minor patch" (one per line).
nvm_installed() {
  local d v
  for d in "$NVM_DIR_ROOT/versions/node"/v*; do
    [[ -d "$d" ]] || continue
    v="${d##*/v}"
    [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    printf '%s\n' "${v//./ }"
  done
}

# nvm_match <numeric-spec>: highest installed version whose leading components
# equal the spec's components exactly ("24" matches 24.x.y, not 240.x.y).
# Empty spec matches everything (used for node/stable). Sets NVM_MATCH.
NVM_MATCH=""
nvm_match() {
  local spec="${1#v}" s1="" s2="" s3="" best="" best_key="" maj min pat key
  if [[ -n "$spec" ]]; then
    IFS=. read -r s1 s2 s3 <<<"$spec"
  fi
  while read -r maj min pat; do
    [[ -z "$s1" || "$maj" == "$((10#$s1))" ]] || continue
    [[ -z "$s2" || "$min" == "$((10#$s2))" ]] || continue
    [[ -z "$s3" || "$pat" == "$((10#$s3))" ]] || continue
    key="$(printf '%06d%06d%06d' "$maj" "$min" "$pat")"
    if [[ -z "$best_key" || "$key" > "$best_key" ]]; then
      best_key="$key"
      best="$maj.$min.$pat"
    fi
  done < <(nvm_installed)
  NVM_MATCH="$best"
  [[ -n "$best" ]]
}

# nvm_resolve <alias>: follow the alias chain (bounded, cycle-detected) to an
# installed version. Unsupported aliases (system, iojs, ...) are unresolved.
# Runs in the current shell (no $(...)) so NVM_RESOLVED / NVM_RESOLVE_NOTE
# survive. NVM_RESOLVED is set on success; NVM_RESOLVE_NOTE explains failure.
NVM_RESOLVED=""
NVM_RESOLVE_NOTE=""
nvm_resolve() {
  local name="$1" depth=0 seen=" " file
  while [[ $depth -lt 10 ]]; do
    name="$(printf '%s' "$name" | tr -d '[:space:]')"
    if [[ "$name" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]]; then
      if nvm_match "$name"; then
        NVM_RESOLVED="$NVM_MATCH"
        return 0
      fi
      NVM_RESOLVE_NOTE="no installed version matches '$name'"
      return 1
    fi
    case "$name" in
      node | stable)
        if nvm_match ""; then
          NVM_RESOLVED="$NVM_MATCH"
          return 0
        fi
        NVM_RESOLVE_NOTE="no node versions installed"
        return 1
        ;;
      "" | system | iojs | *..*)
        NVM_RESOLVE_NOTE="unsupported or empty alias '$name'"
        return 1
        ;;
    esac
    if [[ "$seen" == *" $name "* ]]; then
      NVM_RESOLVE_NOTE="alias cycle at '$name'"
      return 1
    fi
    seen="$seen$name "
    file="$NVM_DIR_ROOT/alias/$name"
    if [[ ! -f "$file" ]]; then
      NVM_RESOLVE_NOTE="alias '$name' not found"
      return 1
    fi
    IFS= read -r name <"$file" || [[ -n "$name" ]] || {
      NVM_RESOLVE_NOTE="alias file '$file' unreadable"
      return 1
    }
    depth=$((depth + 1))
  done
  NVM_RESOLVE_NOTE="alias chain deeper than 10"
  return 1
}

NODE_VERSION=""
NODE_BIN=""
if nvm_resolve default; then
  NODE_VERSION="$NVM_RESOLVED"
  NODE_BIN="$NVM_DIR_ROOT/versions/node/v$NODE_VERSION/bin"
  if [[ ! -d "$NODE_BIN" ]]; then
    NVM_RESOLVE_NOTE="resolved v$NODE_VERSION but $NODE_BIN is missing"
    NODE_VERSION=""
    NODE_BIN=""
  fi
fi

if [[ -n "$NODE_BIN" ]]; then
  export PATH="$NODE_BIN:$BASE_PATH"
else
  export PATH="$BASE_PATH"
fi

if [[ "$(id -u)" == "0" ]]; then
  die "refusing to run as root; cache-prune manages per-user caches and a gui/<uid> LaunchAgent"
fi

# Neutral cwd: no project npmrc/packageManager/uv.toml influence. $HOME (not
# `/`): pnpm writes a probe file into cwd and `/` is read-only on macOS.
cd "$HOME" || die "cannot cd to $HOME"

# --- clock / dates -----------------------------------------------------------

now_epoch() {
  if [[ -n "${CACHE_PRUNE_NOW:-}" ]]; then
    printf '%s\n' "$CACHE_PRUNE_NOW"
  else
    /bin/date -u +%s
  fi
}
NOW="$(now_epoch)"

# iso_to_epoch <ISO-8601>: BSD /bin/date only (GNU date may shadow `date` on
# interactive PATHs). Fractional seconds are stripped (floor). Accepts Z or a
# ±HH:MM offset. Returns 1 on anything else.
iso_to_epoch() {
  local s="$1" base rest sign oh om off epoch
  [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]] || return 1
  base="${BASH_REMATCH[1]}"
  rest="${BASH_REMATCH[3]}"
  epoch="$(/bin/date -j -u -f '%Y-%m-%dT%H:%M:%S' "$base" +%s 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  if [[ "$rest" != "Z" ]]; then
    sign="${rest:0:1}"
    oh="${rest:1:2}"
    om="${rest:4:2}"
    off=$((10#$oh * 3600 + 10#$om * 60))
    if [[ "$sign" == "+" ]]; then
      epoch=$((epoch - off))
    else
      epoch=$((epoch + off))
    fi
  fi
  printf '%s\n' "$epoch"
}

# --- work dir, logging -------------------------------------------------------

WORK="$(mktemp -d "/tmp/cache-prune.XXXXXX")" || die "cannot create work dir"
LOCK_DIR="$HOME/Library/Caches/cache-prune.lock"
LOCK_HELD=0

# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  if [[ "$LOCK_HELD" -eq 1 ]]; then
    local owner_pid=""
    owner_pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    if [[ "$owner_pid" == "$$" ]]; then
      rm -f "$LOCK_DIR/owner"
      rmdir "$LOCK_DIR" 2>/dev/null
    fi
    LOCK_HELD=0
  fi
  [[ -n "${WORK:-}" && -d "$WORK" ]] && rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

LOG_OK=0
REFUSE_MUTATIONS=0
open_log() {
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
  if [[ -f "$LOG_FILE" ]]; then
    local size
    size="$(/usr/bin/stat -f %z "$LOG_FILE" 2>/dev/null || echo 0)"
    if [[ "$size" =~ ^[0-9]+$ && "$size" -gt "$LOG_MAX_BYTES" ]]; then
      mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null
    fi
  fi
  if { : >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_OK=1
  else
    LOG_OK=0
    warn "cannot write log file $LOG_FILE"
  fi
}

# log: stdout + log file. Every file write is checked: a failure after
# startup (disk full, permissions changed, file replaced) flips the run into
# refusal mode for --apply, since the log is the authoritative record.
LOG_WRITE_FAILED=0
log() {
  printf '%s\n' "$*"
  [[ "$LOG_OK" -eq 1 ]] || return 0
  if ! { printf '[%s] %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >>"$LOG_FILE"; } 2>/dev/null; then
    LOG_OK=0
    LOG_WRITE_FAILED=1
    if [[ "$MODE" == "apply" ]]; then
      REFUSE_MUTATIONS=1
      warn "log write failed ($LOG_FILE); refusing all further destructive steps"
    else
      warn "log write failed ($LOG_FILE); continuing dry-run without a log"
    fi
  fi
}

# mutation_allowed <command description>: the last check before any
# destructive command. Records the intent in the log (which also proves the
# log is still writable) and refuses if any log write has failed.
mutation_allowed() {
  [[ "$MODE" == "apply" ]] || return 1
  [[ "$REFUSE_MUTATIONS" -eq 0 ]] || return 1
  log "  running: $*"
  [[ "$REFUSE_MUTATIONS" -eq 0 && "$LOG_OK" -eq 1 ]] || {
    REFUSE_MUTATIONS=1
    return 1
  }
  return 0
}

# log_file <path>: log each line of a file, indented.
log_file() {
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    log "    $line"
  done <"$1"
}

# --- lock ----------------------------------------------------------------------

LOCK_BUSY_EXIT=75
THIS_HOST="$(/bin/hostname 2>/dev/null || echo unknown)"

write_lock_owner() {
  printf 'pid=%s\nhost=%s\nstarted=%s\n' "$$" "$THIS_HOST" "$(/bin/date -u +%s)" >"$LOCK_DIR/owner.tmp.$$" &&
    mv -f "$LOCK_DIR/owner.tmp.$$" "$LOCK_DIR/owner"
}

# acquire_lock: 0 = held; 1 = busy/ambiguous (caller exits LOCK_BUSY_EXIT).
# Reclaims only a clearly stale lock: owner file present, same host, numeric
# pid that is not running. Anything else is left alone.
acquire_lock() {
  mkdir -p "$(dirname "$LOCK_DIR")" 2>/dev/null
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
    if ! write_lock_owner; then
      log "lock: acquired $LOCK_DIR but could not write owner metadata"
    fi
    return 0
  fi
  local pid="" host="" started=""
  if [[ -f "$LOCK_DIR/owner" ]]; then
    pid="$(sed -n 's/^pid=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    host="$(sed -n 's/^host=//p' "$LOCK_DIR/owner" 2>/dev/null)"
    started="$(sed -n 's/^started=//p' "$LOCK_DIR/owner" 2>/dev/null)"
  fi
  if [[ -z "$pid" || ! "$pid" =~ ^[0-9]+$ || "$host" != "$THIS_HOST" ]]; then
    log "lock: $LOCK_DIR exists with ambiguous ownership (pid='${pid}' host='${host}'); skipping run"
    return 1
  fi
  if kill -0 "$pid" 2>/dev/null || ps -p "$pid" >/dev/null 2>&1; then
    log "lock: held by live pid $pid on $host (started $started); skipping run"
    return 1
  fi
  log "lock: reclaiming stale lock from dead pid $pid on $host (started $started)"
  rm -f "$LOCK_DIR/owner"
  if ! rmdir "$LOCK_DIR" 2>/dev/null || ! mkdir "$LOCK_DIR" 2>/dev/null; then
    log "lock: could not reclaim $LOCK_DIR (unexpected contents or a concurrent run); skipping run"
    return 1
  fi
  LOCK_HELD=1
  write_lock_owner || log "lock: could not write owner metadata"
  return 0
}

# --- step bookkeeping --------------------------------------------------------

STEP_NAMES=()
STEP_STATUSES=()
STEP_DETAILS=()
record_step() {
  STEP_NAMES+=("$1")
  STEP_STATUSES+=("$2")
  STEP_DETAILS+=("$3")
  log "  -> [$2] $1: $3"
}

# --- watchdog (inventory/report commands only) -------------------------------

# run_timed <out-file> <cmd...>: stdout -> out-file, stderr -> out-file.err.
# Returns the command's exit code, or 124 if the watchdog killed it.
# Never used for mutating commands.
run_timed() {
  local out="$1" pid wd rc marker
  shift
  marker="$WORK/timeout.$RANDOM.$RANDOM"
  "$@" >"$out" 2>"$out.err" </dev/null &
  pid=$!
  (
    sp=""
    trap 'kill "$sp" 2>/dev/null; exit 0' TERM
    sleep "$TIMEOUT" &
    sp=$!
    wait "$sp"
    : >"$marker"
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -KILL "$pid" 2>/dev/null
  ) >/dev/null 2>&1 </dev/null &
  wd=$!
  wait "$pid"
  rc=$?
  kill -TERM "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  if [[ -e "$marker" ]]; then
    rm -f "$marker"
    return 124
  fi
  return "$rc"
}

status_for_rc() {
  case "$1" in
    0) echo success ;;
    124) echo timeout ;;
    *) echo fail ;;
  esac
}

# --- size helpers -------------------------------------------------------------

# du_kb <path>: KB used, or "unknown".
du_kb() {
  local p="$1" out="$WORK/du.$RANDOM"
  [[ -e "$p" ]] || {
    echo 0
    return
  }
  if run_timed "$out" du -sk "$p" && [[ ! -s "$out.err" ]]; then
    awk 'NR==1{print $1}' "$out"
  else
    echo unknown
  fi
}

human_kb() {
  case "$1" in
    unknown | "") echo "unknown" ;;
    *) awk -v k="$1" 'BEGIN { if (k >= 1048576) printf "%.2f GB", k/1048576; else if (k >= 1024) printf "%.1f MB", k/1024; else printf "%d KB", k }' ;;
  esac
}

human_bytes() {
  awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.2fGB", b/1e9; else if (b >= 1e6) printf "%.1fMB", b/1e6; else if (b >= 1e3) printf "%.1fkB", b/1e3; else printf "%dB", b }'
}

FREED_KB=0
FREED_UNKNOWN=0
account_freed() {
  local before="$1" after="$2"
  if [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]]; then
    if [[ "$before" -gt "$after" ]]; then
      FREED_KB=$((FREED_KB + before - after))
    fi
  else
    FREED_UNKNOWN=1
  fi
}

# --- docker (OrbStack) -------------------------------------------------------

DOCKER_OK=0
DOCKER_SKIP_REASON=""

# orb_gate: `orb status` must exit 0 (never bare `orb`, never start OrbStack).
orb_gate() {
  local out="$WORK/orb.out" rc
  if ! command -v orb >/dev/null 2>&1; then
    DOCKER_SKIP_REASON="orb not found on PATH"
    return 1
  fi
  run_timed "$out" orb status
  rc=$?
  if [[ $rc -ne 0 ]]; then
    DOCKER_SKIP_REASON="orb status exited $rc ($(head -n1 "$out" 2>/dev/null))"
    return 1
  fi
  return 0
}

# docker_inv <out-file> <args...>: gated, pinned, watchdog-bounded inventory.
docker_inv() {
  local out="$1"
  shift
  if [[ "$DOCKER_OK" -ne 1 ]] || ! orb_gate; then
    DOCKER_OK=0
    return 125
  fi
  run_timed "$out" docker --context "$DOCKER_CTX" "$@"
}

# docker_mut <out-file> <args...>: gated, pinned mutation. No watchdog kill.
docker_mut() {
  local out="$1"
  shift
  if [[ "$DOCKER_OK" -ne 1 ]] || ! orb_gate; then
    DOCKER_OK=0
    return 125
  fi
  docker --context "$DOCKER_CTX" "$@" >"$out" 2>"$out.err" </dev/null
}

docker_rc_note() {
  case "$1" in
    125) echo "docker unavailable: $DOCKER_SKIP_REASON" ;;
    124) echo "timed out after ${TIMEOUT}s" ;;
    *) echo "exit $1: $(head -n1 "$2.err" 2>/dev/null)" ;;
  esac
}

# load_keep_list: snapshot the keep-list once. Absent = empty (protects
# nothing). Present but not a readable regular file (mode 000, directory,
# dangling symlink, read error) = 1, and the caller must fail closed.
KEEP_SNAPSHOT=""
KEEP_ERR=""
load_keep_list() {
  KEEP_SNAPSHOT="$WORK/keep-list"
  : >"$KEEP_SNAPSHOT"
  if [[ ! -e "$KEEP_FILE" && ! -L "$KEEP_FILE" ]]; then
    return 0
  fi
  if [[ ! -f "$KEEP_FILE" || ! -r "$KEEP_FILE" ]]; then
    KEEP_ERR="keep-list $KEEP_FILE exists but is not a readable regular file"
    return 1
  fi
  if ! cat "$KEEP_FILE" >"$KEEP_SNAPSHOT" 2>/dev/null; then
    KEEP_ERR="keep-list $KEEP_FILE could not be read"
    return 1
  fi
  return 0
}

# keep_list_protects <id> <tags...>: consults the snapshot from load_keep_list.
keep_list_protects() {
  local id="$1" entry hex
  shift
  [[ -n "$KEEP_SNAPSHOT" && -f "$KEEP_SNAPSHOT" ]] || return 1
  hex="${id#sha256:}"
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [[ -n "$entry" ]] || continue
    local t
    for t in "$@"; do
      [[ "$entry" == "$t" ]] && return 0
    done
    case "$entry" in
      sha256:*) [[ "$entry" == "$id" ]] && return 0 ;;
      *)
        if [[ "$entry" =~ ^[0-9a-f]{12,64}$ && "$hex" == "$entry"* ]]; then
          return 0
        fi
        ;;
    esac
  done <"$KEEP_SNAPSHOT"
  return 1
}

CONTAINERS_FILE=""
# docker_inventory_containers: writes "$WORK/containers" (inspect rows).
docker_inventory_containers() {
  local ids="$WORK/ps.out" rows="$WORK/containers" rc n_ids n_rows
  CONTAINERS_FILE="$rows"
  : >"$rows"
  docker_inv "$ids" ps -aq --no-trunc
  rc=$?
  if [[ $rc -ne 0 ]]; then
    CONTAINER_INV_ERR="container list failed: $(docker_rc_note "$rc" "$ids")"
    return 1
  fi
  n_ids="$(grep -c . "$ids")"
  [[ "$n_ids" -eq 0 ]] && return 0
  local args=()
  while IFS= read -r id; do
    [[ -n "$id" ]] && args+=("$id")
  done <"$ids"
  docker_inv "$rows" container inspect --format "$CONTAINER_FORMAT" "${args[@]}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    CONTAINER_INV_ERR="container inspect failed: $(docker_rc_note "$rc" "$rows")"
    return 1
  fi
  n_rows="$(grep -c . "$rows")"
  if [[ "$n_rows" -ne "$n_ids" ]]; then
    CONTAINER_INV_ERR="container inspect returned $n_rows rows for $n_ids containers"
    return 1
  fi
  return 0
}

# Templates use `index`/`with` for optional keys: Docker 29 renders inspect
# templates against raw JSON maps with missingkey=error, so `.Config.Labels`
# errors on images without labels (which would fail-close the whole step).
LABEL_TPL_PROJECT='{{with index . "Config"}}{{with index . "Labels"}}{{with index . "com.docker.compose.project"}}{{.}}{{end}}{{end}}{{end}}'
LABEL_TPL_SERVICE='{{with index . "Config"}}{{with index . "Labels"}}{{with index . "com.docker.compose.service"}}{{.}}{{end}}{{end}}{{end}}'
IMAGE_FORMAT="{{.Id}}|{{.Created}}|{{.Size}}|{{with index . \"RepoTags\"}}{{range .}}{{.}} {{end}}{{end}}|{{with index . \"RepoDigests\"}}{{len .}}{{else}}0{{end}}|$LABEL_TPL_PROJECT|$LABEL_TPL_SERVICE"
CONTAINER_FORMAT="{{.Id}}|{{.Image}}|{{.State.Status}}|{{.State.FinishedAt}}|{{.Name}}|$LABEL_TPL_PROJECT|$LABEL_TPL_SERVICE"

# docker_inventory_images <dangling:true|false> <rows-out>
docker_inventory_images() {
  local dangling="$1" rows="$2" ids="$WORK/imgids.$1" rc n_ids n_rows
  : >"$rows"
  docker_inv "$ids.raw" image ls -q --no-trunc --filter "dangling=$dangling"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    IMAGE_INV_ERR="image list failed: $(docker_rc_note "$rc" "$ids.raw")"
    return 1
  fi
  # `image ls` repeats an ID once per tag/digest row; dedupe by ID.
  grep . "$ids.raw" | sort -u >"$ids"
  n_ids="$(grep -c . "$ids")"
  [[ "$n_ids" -eq 0 ]] && return 0
  local args=()
  while IFS= read -r id; do
    args+=("$id")
  done <"$ids"
  docker_inv "$rows" image inspect --format "$IMAGE_FORMAT" "${args[@]}"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    IMAGE_INV_ERR="image inspect failed: $(docker_rc_note "$rc" "$rows")"
    return 1
  fi
  n_rows="$(grep -c . "$rows")"
  if [[ "$n_rows" -ne "$n_ids" ]]; then
    IMAGE_INV_ERR="image inspect returned $n_rows rows for $n_ids images"
    return 1
  fi
  return 0
}

# containers_using <image-id>: "name(state)" list of containers on that image.
containers_using() {
  [[ -n "$CONTAINERS_FILE" && -f "$CONTAINERS_FILE" ]] || return 0
  awk -F'|' -v id="$1" '$2 == id { n = $5; sub(/^\//, "", n); printf "%s%s(%s)", sep, n, $3; sep = ", " }' "$CONTAINERS_FILE"
}

short_id() {
  local h="${1#sha256:}"
  printf '%s\n' "${h:0:12}"
}

age_days() {
  echo $(((NOW - $1) / 86400))
}

REMOVE_TAGS_FILE=""
IMAGES_REMOVED_TAGS=0
REVIEW_ITEMS=0

docker_tagged_images() {
  local rows="$WORK/images.tagged" id created size tags ndig proj svc
  local epoch reasons users eligible n_elig=0 n_total=0
  REMOVE_TAGS_FILE="$WORK/remove-tags"
  : >"$REMOVE_TAGS_FILE"
  CONTAINER_INV_ERR=""
  IMAGE_INV_ERR=""

  log ""
  log "== Docker: tagged images (remove only if unused by any container, has RepoDigests, >${IMAGE_MIN_AGE_DAYS}d old, not keep-listed) =="
  if ! docker_inventory_containers; then
    record_step "docker:tagged-images" fail "$CONTAINER_INV_ERR; fail-closed, no tagged removals"
    return
  fi
  if ! docker_inventory_images false "$rows"; then
    record_step "docker:tagged-images" fail "$IMAGE_INV_ERR; fail-closed, no tagged removals"
    return
  fi
  if ! load_keep_list; then
    log "  ERROR: $KEEP_ERR"
    record_step "docker:tagged-images" fail "$KEEP_ERR; fail-closed, no tagged removals"
    return
  fi

  log "$(printf '  %-9s %-12s %6s  %-45s %s' ELIGIBLE IMAGE-ID AGE TAGS REASON)"
  while IFS='|' read -r id created size tags ndig proj svc; do
    [[ -n "$id" ]] || continue
    n_total=$((n_total + 1))
    reasons=""
    eligible=1
    # shellcheck disable=SC2086  # tags are whitespace-separated repo:tag tokens
    set -- $tags
    users="$(containers_using "$id")"
    if [[ -n "$users" ]]; then
      eligible=0
      reasons="${reasons}in use by $users; "
    fi
    if [[ ! "$ndig" =~ ^[0-9]+$ || "$ndig" -eq 0 ]]; then
      eligible=0
      reasons="${reasons}no RepoDigests (local build); "
    fi
    local age_txt="?"
    if epoch="$(iso_to_epoch "$created")"; then
      age_txt="$(age_days "$epoch")d"
      if [[ $((NOW - epoch)) -le $((IMAGE_MIN_AGE_DAYS * 86400)) ]]; then
        eligible=0
        reasons="${reasons}age $age_txt <= ${IMAGE_MIN_AGE_DAYS}d; "
      fi
    else
      eligible=0
      reasons="${reasons}unparseable Created '$created'; "
    fi
    if keep_list_protects "$id" "$@"; then
      eligible=0
      reasons="${reasons}keep-listed; "
    fi
    if [[ $# -eq 0 ]]; then
      eligible=0
      reasons="${reasons}no tags; "
    fi
    if [[ $eligible -eq 1 ]]; then
      n_elig=$((n_elig + 1))
      reasons="all criteria met"
      local t
      for t in "$@"; do
        printf '%s|%s\n' "$t" "$id" >>"$REMOVE_TAGS_FILE"
      done
    fi
    reasons="${reasons%; }"
    log "$(printf '  %-9s %-12s %6s  %-45s %s' "$([[ $eligible -eq 1 ]] && echo yes || echo no)" "$(short_id "$id")" "$age_txt" "$tags" "$reasons" | cut -c1-400)"
  done <"$rows"

  local n_tags
  n_tags="$(grep -c . "$REMOVE_TAGS_FILE")"
  if [[ "$MODE" != "apply" ]]; then
    if [[ "$n_tags" -gt 0 ]]; then
      log "  would run (per tag, never -f; each tag is re-resolved to the eligible image ID first):"
      while IFS='|' read -r t _; do
        log "    docker --context $DOCKER_CTX image rm $t"
      done <"$REMOVE_TAGS_FILE"
    fi
    record_step "docker:tagged-images" skip "dry-run: $n_elig of $n_total images eligible ($n_tags tags would be removed)"
    return
  fi
  local failed=0 refused=0 changed=0 untagged=0 deleted=0 out="$WORK/rmi.out" rc want got
  while IFS='|' read -r t want; do
    [[ -n "$t" ]] || continue
    if [[ "$REFUSE_MUTATIONS" -ne 0 ]]; then
      refused=$((refused + 1))
      continue
    fi
    # The inventory is a snapshot: re-resolve the tag (gated like every
    # docker call) and remove only if it still names the eligible image.
    # Residual window (accepted): `image rm` takes the tag, not the ID, so a
    # re-tag between this check and the rm below could still remove the
    # newer image's tag. Docker has no compare-and-delete for tags; the
    # window is milliseconds in a monthly unattended run, and rm without -f
    # still refuses images used by containers.
    docker_inv "$out" image inspect --format '{{.Id}}' "$t"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      failed=$((failed + 1))
      log "  FAILED to re-resolve $t before removal ($(docker_rc_note "$rc" "$out")); not removed"
      continue
    fi
    got="$(head -n1 "$out" | tr -d '[:space:]')"
    if [[ "$got" != "$want" ]]; then
      changed=$((changed + 1))
      log "  skipped $t: now resolves to ${got:-nothing}, not eligible ID $want; not removed"
      continue
    fi
    if ! mutation_allowed "docker --context $DOCKER_CTX image rm $t   # $want"; then
      refused=$((refused + 1))
      continue
    fi
    docker_mut "$out" image rm "$t"
    rc=$?
    if [[ $rc -eq 0 ]]; then
      IMAGES_REMOVED_TAGS=$((IMAGES_REMOVED_TAGS + 1))
      untagged=$((untagged + $(grep -c '^Untagged:' "$out")))
      deleted=$((deleted + $(grep -c '^Deleted:' "$out")))
      log "  removed tag $t"
      log_file "$out"
    else
      failed=$((failed + 1))
      log "  FAILED to remove $t: $(docker_rc_note "$rc" "$out")"
    fi
  done <"$REMOVE_TAGS_FILE"
  local detail="removed $IMAGES_REMOVED_TAGS/$n_tags tags; $untagged untagged references, $deleted deleted image IDs/layers reported"
  [[ $changed -gt 0 ]] && detail="$detail; $changed skipped (tag changed since inventory)"
  if [[ $refused -gt 0 ]]; then
    record_step "docker:tagged-images" skip "$detail; $refused removals refused (log unwritable)"
  elif [[ $failed -gt 0 ]]; then
    record_step "docker:tagged-images" fail "$detail; $failed removals failed"
  else
    record_step "docker:tagged-images" success "$detail"
  fi
}

docker_dangling() {
  local rows="$WORK/images.dangling" id created size tags ndig proj svc epoch n=0 total=0 users
  IMAGE_INV_ERR=""
  log ""
  log "== Docker: dangling images older than 30d (docker image prune -f --filter until=$PRUNE_UNTIL) =="
  # Runs after docker_tagged_images, so in --apply this inventory is taken
  # after tagged removals and immediately before the prune below.
  if [[ "$MODE" == "apply" ]]; then
    log "  (dangling candidates snapshot immediately before image prune, after tagged removals (Docker selects the final set; container-referenced rows are retained))"
  else
    log "  note: --apply re-inventories dangling images immediately before pruning (after tagged removals) and logs that candidate snapshot."
    log "        It can be longer than this list if a tagged removal leaves an image behind untagged (possible only once all of"
    log "        its tags are removed, which is what --apply does for eligible images) or if new images go dangling meanwhile."
    log "        Docker itself selects what image prune removes (dangling + until=$PRUNE_UNTIL); in-use images are kept."
  fi
  if ! docker_inventory_images true "$rows"; then
    record_step "docker:dangling-inventory" fail "$IMAGE_INV_ERR"
    [[ "$MODE" == "apply" ]] && log "  exact prune list unavailable; prune still applies docker's own dangling + until=$PRUNE_UNTIL rules"
  else
    log "$(printf '  %-12s %-36s %-28s %10s  %s' IMAGE-ID CREATED COMPOSE SIZE NOTE)"
    while IFS='|' read -r id created size tags ndig proj svc; do
      [[ -n "$id" ]] || continue
      if ! epoch="$(iso_to_epoch "$created")"; then
        log "$(printf '  %-12s %-36s %-28s %10s  %s' "$(short_id "$id")" "$created" "${proj:--}/${svc:--}" "$(human_bytes "$size")" "unparseable Created; prune decides")"
        continue
      fi
      [[ $((NOW - epoch)) -gt $PRUNE_UNTIL_SECS ]] || continue
      users="$(containers_using "$id")"
      n=$((n + 1))
      [[ "$size" =~ ^[0-9]+$ ]] && total=$((total + size))
      log "$(printf '  %-12s %-36s %-28s %10s  %s' "$(short_id "$id")" "$created" "${proj:--}/${svc:--}" "$(human_bytes "$size")" "${users:+in use by $users (prune keeps it)}")"
    done <"$rows"
    log "  $n dangling images older than 30d; combined size $(human_bytes "$total") (shared layers may make actual reclaim smaller)"
    record_step "docker:dangling-inventory" success "$n dangling images >30d, $(human_bytes "$total") listed"
  fi

  if [[ "$MODE" != "apply" ]]; then
    record_step "docker:image-prune" skip "dry-run: would run docker --context $DOCKER_CTX image prune -f --filter until=$PRUNE_UNTIL"
    return
  fi
  if ! mutation_allowed "docker --context $DOCKER_CTX image prune -f --filter until=$PRUNE_UNTIL"; then
    record_step "docker:image-prune" skip "log unwritable; refusing destructive step"
    return
  fi
  local out="$WORK/iprune.out" rc
  docker_mut "$out" image prune -f --filter "until=$PRUNE_UNTIL"
  rc=$?
  log_file "$out"
  if [[ $rc -eq 0 ]]; then
    record_step "docker:image-prune" success "$(grep -i 'reclaimed' "$out" | head -n1)"
  else
    record_step "docker:image-prune" "$(status_for_rc "$rc")" "$(docker_rc_note "$rc" "$out")"
  fi
}

docker_builder() {
  local out="$WORK/bdu.out" rc
  log ""
  log "== Docker: build cache older than 30d (docker builder prune -f --filter until=$PRUNE_UNTIL) =="
  # `buildx du --filter until=` does not filter on this Docker version, so
  # estimate from the LAST ACCESSED column instead (relative, approximate).
  docker_inv "$out" buildx du
  rc=$?
  if [[ $rc -eq 0 ]]; then
    local est
    est="$(awk '
      $2 == "true" || $2 == "false" {
        n_all++
        if ($2 != "true") next
        rel = ""; for (i = 4; i <= NF; i++) rel = rel " " $i
        days = -1
        if (match(rel, /[0-9]+ (second|minute|hour|day|week|month|year)s? ago/)) {
          split(substr(rel, RSTART, RLENGTH), p, " "); q = p[1]; u = p[2]
        } else if (match(rel, /(About|Less than) an? [a-z]+ ago/)) {
          k = split(substr(rel, RSTART, RLENGTH), p, " "); q = 1; u = p[k - 1]
        } else next
        sub(/s$/, "", u)
        if (u == "day") days = q; else if (u == "week") days = 7 * q
        else if (u == "month") days = 30 * q; else if (u == "year") days = 365 * q
        else days = 0
        if (days <= 30) next
        s = $3; gsub(/\*/, "", s)
        num = s + 0; un = s; sub(/^[0-9.]+/, "", un)
        m = 1
        if (un == "kB" || un == "KB") m = 1e3; else if (un == "MB") m = 1e6; else if (un == "GB") m = 1e9; else if (un == "TB") m = 1e12
        t += num * m; c++
      }
      END { printf "%d %d %d", c + 0, n_all + 0, t + 0 }' "$out")"
    local cnt total_n bytes
    read -r cnt total_n bytes <<<"$est"
    grep -E '^(Shared|Private|Reclaimable|Total):' "$out" >"$out.totals"
    log_file "$out.totals"
    log "  estimate: $cnt of $total_n records last used >30d ago, ~$(human_bytes "$bytes") (from buildx du LAST ACCESSED, approximate; sizes marked * are shared and may not all be freed)"
    record_step "docker:builder-estimate" success "$cnt of $total_n records >30d, ~$(human_bytes "$bytes")"
  else
    record_step "docker:builder-estimate" "$(status_for_rc "$rc")" "$(docker_rc_note "$rc" "$out")"
  fi

  if [[ "$MODE" != "apply" ]]; then
    record_step "docker:builder-prune" skip "dry-run: would run docker --context $DOCKER_CTX builder prune -f --filter until=$PRUNE_UNTIL"
    return
  fi
  if ! mutation_allowed "docker --context $DOCKER_CTX builder prune -f --filter until=$PRUNE_UNTIL"; then
    record_step "docker:builder-prune" skip "log unwritable; refusing destructive step"
    return
  fi
  out="$WORK/bprune.out"
  docker_mut "$out" builder prune -f --filter "until=$PRUNE_UNTIL"
  rc=$?
  log_file "$out"
  if [[ $rc -eq 0 ]]; then
    record_step "docker:builder-prune" success "$(grep -i 'total' "$out" | head -n1)"
  else
    record_step "docker:builder-prune" "$(status_for_rc "$rc")" "$(docker_rc_note "$rc" "$out")"
  fi
}

docker_containers_report() {
  local id img state finished name proj svc epoch n=0
  log ""
  log "== Docker: exited containers (report only; never removed) =="
  if [[ -z "$CONTAINERS_FILE" || ! -f "$CONTAINERS_FILE" || -n "$CONTAINER_INV_ERR" ]]; then
    record_step "docker:containers-report" fail "container inventory unavailable"
    return
  fi
  while IFS='|' read -r id img state finished name proj svc; do
    [[ -n "$id" ]] || continue
    [[ "$state" == "exited" || "$state" == "dead" || "$state" == "created" ]] || continue
    n=$((n + 1))
    local age="?"
    epoch="$(iso_to_epoch "$finished")" && age="$(age_days "$epoch")d ago"
    log "$(printf '  %-32s %-8s finished %-10s compose=%s/%s image=%s' "${name#/}" "$state" "$age" "${proj:--}" "${svc:--}" "$(short_id "$img")" | cut -c1-200)"
  done <"$CONTAINERS_FILE"
  REVIEW_ITEMS=$((REVIEW_ITEMS + n))
  record_step "docker:containers-report" success "$n exited/created containers to review"
}

docker_system_df() {
  local label="$1" out="$WORK/df.$1" rc
  docker_inv "$out" system df
  rc=$?
  log ""
  log "== Docker: system df ($label) =="
  if [[ $rc -eq 0 ]]; then
    log_file "$out"
  else
    log "  unavailable: $(docker_rc_note "$rc" "$out")"
  fi
}

docker_steps() {
  if ! command -v docker >/dev/null 2>&1; then
    record_step "docker" skip "docker CLI not found on PATH"
    return
  fi
  DOCKER_OK=1
  if ! orb_gate; then
    DOCKER_OK=0
    record_step "docker" skip "$DOCKER_SKIP_REASON; zero docker calls made"
    return
  fi
  docker_system_df before
  docker_tagged_images
  docker_dangling
  docker_builder
  docker_containers_report
  [[ "$MODE" == "apply" ]] && docker_system_df after
  if [[ "$DOCKER_OK" -ne 1 ]]; then
    record_step "docker" fail "OrbStack became unavailable mid-run: $DOCKER_SKIP_REASON"
  fi
}

# --- package-manager caches --------------------------------------------------

count_dirs() {
  local d="$1" n=0 e
  [[ -d "$d" ]] || {
    echo 0
    return
  }
  for e in "$d"/*; do
    [[ -d "$e" ]] && n=$((n + 1))
  done
  echo "$n"
}

uv_step() {
  local out="$WORK/uv.out" rc dir before after envs_before envs_after
  log ""
  log "== uv cache =="
  if ! command -v uv >/dev/null 2>&1; then
    record_step "uv" skip "uv not found on PATH"
    return
  fi
  dir=""
  if run_timed "$out" uv cache dir; then
    dir="$(head -n1 "$out")"
  fi
  if [[ -n "$dir" ]]; then
    before="$(du_kb "$dir")"
    envs_before="$(count_dirs "$dir/environments-v2")"
    log "  cache dir: $dir ($(human_kb "$before")); environments-v2 dirs: $envs_before"
  else
    before="unknown"
    envs_before="unknown"
    log "  cache dir: unknown (uv cache dir failed)"
  fi
  if [[ "$MODE" != "apply" ]]; then
    record_step "uv" skip "dry-run: would run uv cache prune (no --force); size $(human_kb "$before"), environments-v2 dirs $envs_before"
    return
  fi
  if ! mutation_allowed "uv cache prune"; then
    record_step "uv" skip "log unwritable; refusing destructive step"
    return
  fi
  uv cache prune >"$out" 2>&1 </dev/null
  rc=$?
  log_file "$out"
  after="unknown"
  envs_after="unknown"
  if [[ -n "$dir" ]]; then
    after="$(du_kb "$dir")"
    envs_after="$(count_dirs "$dir/environments-v2")"
  fi
  account_freed "$before" "$after"
  local detail
  detail="size $(human_kb "$before") -> $(human_kb "$after"); environments-v2 dirs $envs_before -> $envs_after"
  if [[ $rc -eq 0 ]]; then
    record_step "uv" success "$detail"
  else
    record_step "uv" fail "uv cache prune exited $rc; $detail"
  fi
}

pnpm_step() {
  local out="$WORK/pnpm.out" rc store before after pnpm
  log ""
  log "== pnpm store (Corepack offline, cwd \$HOME) =="
  if [[ -z "$NODE_BIN" ]]; then
    record_step "pnpm" skip "nvm default node unresolved (${NVM_RESOLVE_NOTE:-unknown})"
    return
  fi
  pnpm="$NODE_BIN/pnpm"
  if [[ ! -x "$pnpm" ]]; then
    record_step "pnpm" skip "no pnpm in $NODE_BIN"
    return
  fi
  run_timed "$out" "$pnpm" store path
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log_file "$out.err"
    record_step "pnpm" "$(status_for_rc "$rc")" "pnpm store path exited $rc (Corepack offline: pnpm version may not be cached; no download attempted)"
    return
  fi
  store="$(head -n1 "$out")"
  before="$(du_kb "$store")"
  log "  store: $store ($(human_kb "$before"))"
  if [[ "$MODE" != "apply" ]]; then
    record_step "pnpm" skip "dry-run: would run pnpm store prune; store $(human_kb "$before")"
    return
  fi
  if ! mutation_allowed "$pnpm store prune"; then
    record_step "pnpm" skip "log unwritable; refusing destructive step"
    return
  fi
  "$pnpm" store prune >"$out" 2>&1 </dev/null
  rc=$?
  log_file "$out"
  after="$(du_kb "$store")"
  account_freed "$before" "$after"
  if [[ $rc -eq 0 ]]; then
    record_step "pnpm" success "store $(human_kb "$before") -> $(human_kb "$after")"
  else
    record_step "pnpm" fail "pnpm store prune exited $rc; store $(human_kb "$before") -> $(human_kb "$after")"
  fi
}

npm_step() {
  local out="$WORK/npm.out" rc cache before after npm
  log ""
  log "== npm cache =="
  if [[ -z "$NODE_BIN" ]]; then
    record_step "npm" skip "nvm default node unresolved (${NVM_RESOLVE_NOTE:-unknown})"
    return
  fi
  npm="$NODE_BIN/npm"
  if [[ ! -x "$npm" ]]; then
    record_step "npm" skip "no npm in $NODE_BIN"
    return
  fi
  cache="$HOME/.npm"
  if run_timed "$out" "$npm" config get cache && [[ -n "$(head -n1 "$out")" ]]; then
    cache="$(head -n1 "$out")"
  fi
  before="$(du_kb "$cache/_cacache")"
  log "  cache: $cache/_cacache ($(human_kb "$before"))"
  if [[ "$MODE" != "apply" ]]; then
    record_step "npm" skip "dry-run: would run npm cache verify; _cacache $(human_kb "$before")"
    return
  fi
  if ! mutation_allowed "$npm cache verify"; then
    record_step "npm" skip "log unwritable; refusing destructive step"
    return
  fi
  "$npm" cache verify >"$out" 2>&1 </dev/null
  rc=$?
  log_file "$out"
  after="$(du_kb "$cache/_cacache")"
  account_freed "$before" "$after"
  if [[ $rc -eq 0 ]]; then
    record_step "npm" success "_cacache $(human_kb "$before") -> $(human_kb "$after")"
  else
    record_step "npm" fail "npm cache verify exited $rc; _cacache $(human_kb "$before") -> $(human_kb "$after")"
  fi
}

# --- report-only ---------------------------------------------------------------

# report_cmd <step> <cmd...>: run a read-only command under the watchdog and
# log (up to 40 lines of) its output. Missing command -> skip.
report_cmd() {
  local step="$1" out="$WORK/report.$RANDOM" rc
  shift
  if ! command -v "$1" >/dev/null 2>&1; then
    record_step "$step" skip "$1 not found on PATH"
    return
  fi
  run_timed "$out" "$@"
  rc=$?
  head -n 40 "$out" >"$out.head"
  log_file "$out.head"
  if [[ $rc -ne 0 ]]; then
    head -n 5 "$out.err" >"$out.head"
    log_file "$out.head"
  fi
  case "$rc" in
    0) record_step "$step" success "$*" ;;
    124) record_step "$step" timeout "$* timed out after ${TIMEOUT}s" ;;
    *) record_step "$step" fail "$* exited $rc" ;;
  esac
}

report_nvm() {
  local d v n=0
  for d in "$NVM_DIR_ROOT/versions/node"/v*; do
    [[ -d "$d" ]] || continue
    v="${d##*/}"
    n=$((n + 1))
    if [[ -n "$NODE_VERSION" && "$v" == "v$NODE_VERSION" ]]; then
      log "    $v (default)  $(human_kb "$(du_kb "$d")")"
    else
      log "    $v  $(human_kb "$(du_kb "$d")")"
    fi
  done
  record_step "report:nvm" success "$n installed node versions (remove unused ones with: nvm uninstall <v>)"
}

report_simulators() {
  local out="$WORK/simctl" rc
  if ! command -v xcrun >/dev/null 2>&1; then
    record_step "report:simulators" skip "xcrun not found"
    return
  fi
  run_timed "$out" xcrun simctl list devices
  rc=$?
  if [[ $rc -ne 0 ]]; then
    record_step "report:simulators" skip "xcrun simctl unavailable (exit $rc)"
    return
  fi
  local total unavailable
  total="$(grep -cE '\((Booted|Shutdown)\)' "$out")"
  unavailable="$(grep -ci 'unavailable' "$out")"
  log "    $total simulator devices, $unavailable marked unavailable; CoreSimulator/Devices $(human_kb "$(du_kb "$HOME/Library/Developer/CoreSimulator/Devices")")"
  record_step "report:simulators" success "$total devices, $unavailable unavailable (xcrun simctl delete unavailable)"
}

report_library_caches() {
  local out="$WORK/libcaches" rc entries=() e
  for e in "$HOME/Library/Caches"/*; do
    [[ -e "$e" && "$e" != "$LOCK_DIR" ]] && entries+=("$e")
  done
  if [[ ${#entries[@]} -eq 0 ]]; then
    record_step "report:library-caches" skip "no entries in ~/Library/Caches"
    return
  fi
  run_timed "$out" du -sk "${entries[@]}"
  rc=$?
  local note=""
  if [[ $rc -ne 0 || -s "$out.err" ]]; then
    note="incomplete: some entries unreadable (TCC/permissions) or du exit $rc"
  fi
  [[ $rc -eq 124 ]] && note="incomplete: du timed out after ${TIMEOUT}s"
  sort -rn "$out" | head -n 10 | while IFS=$'\t' read -r kb path; do
    log "$(printf '    %10s  %s' "$(human_kb "$kb")" "${path##*/}")"
  done
  if [[ -n "$note" ]]; then
    log "    ($note)"
    record_step "report:library-caches" success "top 10 listed ($note)"
  else
    record_step "report:library-caches" success "top 10 listed"
  fi
}

report_steps() {
  log ""
  log "== Report only (nothing below is modified) =="
  log "  pip:"
  report_cmd "report:pip" python3 -m pip cache info
  log "  poetry:"
  report_cmd "report:poetry" poetry cache list
  log "  npx cache (~/.npm/_npx):"
  local npx
  npx="$(du_kb "$HOME/.npm/_npx")"
  log "    $(human_kb "$npx")"
  if [[ "$npx" == "unknown" ]]; then
    record_step "report:npx" fail "du failed for ~/.npm/_npx"
  else
    record_step "report:npx" success "$(human_kb "$npx")"
  fi
  log "  nvm node versions:"
  report_nvm
  log "  rustup toolchains:"
  local rustup_bin="rustup"
  command -v rustup >/dev/null 2>&1 || rustup_bin="$HOME/.cargo/bin/rustup"
  report_cmd "report:rustup" "$rustup_bin" toolchain list
  log "  simulators:"
  report_simulators
  log "  largest ~/Library/Caches entries:"
  report_library_caches
}

# --- main ----------------------------------------------------------------------

CONTAINER_INV_ERR=""
IMAGE_INV_ERR=""

df_report() {
  local out="$WORK/dfroot.$1"
  log ""
  log "== df -h / ($1; not a measure of freed space) =="
  if run_timed "$out" /bin/df -h /; then
    log_file "$out"
  else
    log "  df unavailable"
  fi
}

run_prune() {
  open_log
  if ! acquire_lock; then
    EXIT_CODE=$LOCK_BUSY_EXIT
    return
  fi
  if [[ "$MODE" == "apply" && "$LOG_OK" -ne 1 ]]; then
    REFUSE_MUTATIONS=1
    warn "--apply: log is not writable; destructive steps will be skipped"
  fi
  log "cache-prune $MODE starting (pid $$, bash $BASH_VERSION, node default: ${NODE_VERSION:-unresolved${NVM_RESOLVE_NOTE:+ — $NVM_RESOLVE_NOTE}})"
  [[ "$MODE" == "apply" ]] || log "dry-run: no changes will be made"

  df_report before
  uv_step
  pnpm_step
  npm_step
  docker_steps
  report_steps
  [[ "$MODE" == "apply" ]] && df_report after

  summarize
  [[ "$MODE" == "apply" && "$NOTIFY" -eq 1 ]] && notify
}

# notify: best-effort; failure ignored. "freed" counts only measured du deltas
# of the uv/pnpm/npm caches (Docker reclaim is in the log, not here).
notify() {
  local gb msg prefix="Cache prune"
  gb="$(awk -v k="$FREED_KB" 'BEGIN { printf "%.2f", k / 1048576 }')"
  [[ "$EXIT_CODE" -ne 0 ]] && prefix="Cache prune (with failures; see log)"
  msg="$prefix: freed ~$gb GB · $IMAGES_REMOVED_TAGS image tags removed · $REVIEW_ITEMS items to review"
  command -v osascript >/dev/null 2>&1 || return 0
  run_timed "$WORK/notify.out" osascript -e "display notification \"$msg\" with title \"cache-prune\"" || true
}

summarize() {
  local i n_fail=0
  log ""
  log "== Summary ($MODE) =="
  for ((i = 0; i < ${#STEP_NAMES[@]}; i++)); do
    log "$(printf '  %-26s %-8s %s' "${STEP_NAMES[$i]}" "${STEP_STATUSES[$i]}" "${STEP_DETAILS[$i]}")"
    case "${STEP_STATUSES[$i]}" in
      fail | timeout) n_fail=$((n_fail + 1)) ;;
    esac
  done
  [[ "$REFUSE_MUTATIONS" -eq 1 ]] && n_fail=$((n_fail + 1))
  [[ "$LOG_WRITE_FAILED" -eq 1 ]] && log "  log write failed during the run; destructive steps after that point were refused (--apply)"
  if [[ "$MODE" == "apply" ]]; then
    log "  measured cache reclaim (uv/pnpm/npm du deltas): $(human_kb "$FREED_KB")$([[ $FREED_UNKNOWN -eq 1 ]] && echo '; some sizes unknown')"
    log "  docker image tags removed: $IMAGES_REMOVED_TAGS (Docker reclaim: see prune output and system df above)"
  fi
  if [[ $n_fail -gt 0 ]]; then
    log "cache-prune $MODE finished with $n_fail failed/timed-out step(s) (partial results above)"
    EXIT_CODE=1
  else
    log "cache-prune $MODE finished OK"
    EXIT_CODE=0
  fi
  # Final check, after every summary write: the log is the authoritative
  # record, so a write failure anywhere (including the lines above, after
  # n_fail was counted) must not end in success.
  if [[ "$LOG_WRITE_FAILED" -eq 1 ]]; then
    EXIT_CODE=1
    warn "log write failed during the run ($LOG_FILE is incomplete); exiting nonzero"
  fi
}

# --- launchd install / uninstall ---------------------------------------------

TEMPLATE="$SCRIPT_DIR/launchd/$LABEL.plist"
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
AGENT_PATH="$SYSTEM_PATH:/opt/homebrew/bin:/usr/local/bin"
AGENT_LOG="$HOME/Library/Logs/cache-prune.launchd.log"

xml_escape() {
  local v="$1"
  v="${v//&/&amp;}"
  v="${v//</&lt;}"
  v="${v//>/&gt;}"
  v="${v//\"/&quot;}"
  v="${v//\'/&apos;}"
  printf '%s' "$v"
}

# render_plist <out>: substitute XML-escaped values into the template.
render_plist() {
  local out="$1" line sp hp pp op
  sp="$(xml_escape "$SCRIPT_PATH")"
  hp="$(xml_escape "$HOME")"
  pp="$(xml_escape "$AGENT_PATH")"
  op="$(xml_escape "$AGENT_LOG")"
  : >"$out" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//__SCRIPT_PATH__/$sp}"
    line="${line//__HOME__/$hp}"
    line="${line//__PATH__/$pp}"
    line="${line//__STDOUT_PATH__/$op}"
    line="${line//__STDERR_PATH__/$op}"
    printf '%s\n' "$line" >>"$out" || return 1
  done <"$TEMPLATE"
}

do_install() {
  local uid domain service tmp
  uid="$(id -u)"
  domain="gui/$uid"
  service="$domain/$LABEL"
  [[ -f "$TEMPLATE" ]] || die "launchd template not found: $TEMPLATE"
  tmp="$WORK/$LABEL.plist"
  render_plist "$tmp" || die "failed to render $TEMPLATE"
  if grep -q '__[A-Z_]*__' "$tmp"; then
    die "rendered plist still contains placeholders"
  fi
  plutil -lint "$tmp" >/dev/null || die "rendered plist failed plutil -lint"
  mkdir -p "$(dirname "$AGENT_PLIST")" "$(dirname "$AGENT_LOG")" || die "cannot create LaunchAgents/Logs directories"

  if launchctl print "$service" >/dev/null 2>&1; then
    info "$LABEL already loaded; booting it out first"
    launchctl bootout "$service" || die "launchctl bootout $service failed"
  fi
  if ! cp "$tmp" "$AGENT_PLIST" || ! chmod 644 "$AGENT_PLIST"; then
    die "cannot write $AGENT_PLIST"
  fi
  launchctl enable "$service" || warn "launchctl enable $service failed (continuing)"
  if ! launchctl bootstrap "$domain" "$AGENT_PLIST"; then
    rm -f "$AGENT_PLIST"
    die "launchctl bootstrap $domain $AGENT_PLIST failed; removed the rendered plist"
  fi
  info "installed $AGENT_PLIST (runs --apply on day 1 of each month at 10:00; not started now)"
}

do_uninstall() {
  local uid service
  uid="$(id -u)"
  service="gui/$uid/$LABEL"
  if launchctl print "$service" >/dev/null 2>&1; then
    launchctl bootout "$service" || die "launchctl bootout $service failed; plist left in place"
    info "booted out $service"
  else
    info "$service not loaded"
  fi
  if [[ -e "$AGENT_PLIST" ]]; then
    rm -f "$AGENT_PLIST" || die "cannot remove $AGENT_PLIST"
    info "removed $AGENT_PLIST"
  fi
}

# do_status: read-only launchd state for `make agents-status`.
do_status() {
  local service
  service="gui/$(id -u)/$LABEL"
  if launchctl print "$service" >/dev/null 2>&1; then
    echo "agent: loaded ($service)"
  else
    echo "agent: not loaded ($service)"
  fi
  if [[ -f "$AGENT_PLIST" ]]; then
    echo "plist: $AGENT_PLIST (present)"
  else
    echo "plist: $AGENT_PLIST (absent)"
  fi
  echo "log:   $LOG_FILE"
}

EXIT_CODE=0
case "$MODE" in
  dry-run | apply)
    run_prune
    exit "$EXIT_CODE"
    ;;
  install) do_install ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
esac
exit 0
