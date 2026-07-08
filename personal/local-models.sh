#!/usr/bin/env bash
# local-models.sh — manage LM Studio local models used by OpenCode.
#
# The OpenCode config statically lists stable local/... model identifiers.
# This script owns the runtime side: start/verify LM Studio, load models under
# those exact identifiers, and unload only the local identifiers it owns.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "$SCRIPT_DIR/../lib/common.sh"

DEFAULT_BASE_URL="http://127.0.0.1:1234/v1"
BASE_URL="${LOCAL_MODELS_BASE_URL:-$DEFAULT_BASE_URL}"
OPENCODE_CONFIG="${LOCAL_MODELS_OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.jsonc}"
LMS_BIN="${LOCAL_MODELS_LMS_BIN:-lms}"
CURL_BIN="${LOCAL_MODELS_CURL_BIN:-curl}"
PYTHON_BIN="${LOCAL_MODELS_PYTHON_BIN:-python3}"
DEFAULT_CONTEXT_LENGTH=32768
DEFAULT_OUTPUT_LIMIT=8192
MEMORY_AUTO_LIMIT_GIB=16

usage() {
  cat <<'EOF'
Usage: local-models <command> [OPTIONS]

Manage LM Studio local models for OpenCode's static lmstudio provider config.
The runtime is explicit: start/verify never loads a model; load always uses the
stable local/... identifier that OpenCode is configured to show in the TUI.

Commands:
  help, -h, --help
      Show this help.
  list
      Show aliases, LM Studio source keys, stable identifiers, and status.
  status
      Show endpoint/server status, loaded local identifiers, and config status.
  start
      Start LM Studio server on http://127.0.0.1:1234/v1 if needed and verify
      /v1/models responds. Does not load models.
  verify
      Strictly check CLI, endpoint, installed source models, and OpenCode config
      drift. Loaded models are not required.
  load <alias> [--context-length N] [--ttl seconds] [-y|--yes]
      Estimate first, then load the source model as the exact stable identifier.
      Default context length is 32768. A prompt is required for large, low-
      confidence, missing-confidence, or unfavorable estimates unless --yes is
      passed. Non-interactive prompt-required runs fail cleanly.
  unload <alias>
      Unload only that alias's exact stable identifier.
  unload --all-local
      Unload only loaded identifiers beginning with local/.

Aliases:
  ministral-3b        -> mistralai/ministral-3-3b       -> local/ministral-3b
  qwen3-vl-8b         -> qwen/qwen3-vl-8b               -> local/qwen3-vl-8b
  qwen3-vl-30b        -> qwen/qwen3-vl-30b              -> local/qwen3-vl-30b
  qwen3-coder-next    -> qwen3-coder-next-0             -> local/qwen3-coder-next
  qwen3.5-122b-a10b   -> qwen_qwen3.5-122b-a10b         -> local/qwen3.5-122b-a10b
  gpt-oss-120b        -> gpt-oss-120b                   -> local/gpt-oss-120b

Environment overrides for tests/advanced use:
  LOCAL_MODELS_LMS_BIN          lms binary path/name
  LOCAL_MODELS_CURL_BIN         curl binary path/name
  LOCAL_MODELS_PYTHON_BIN       python3 binary path/name
  LOCAL_MODELS_OPENCODE_CONFIG  OpenCode JSONC config path
  LOCAL_MODELS_BASE_URL         OpenAI-compatible base URL

Exit codes follow lib/common.sh: 1 runtime, 2 usage, 3 missing dep, 5 upstream.
EOF
}

all_aliases() {
  cat <<'EOF'
ministral-3b
qwen3-vl-8b
qwen3-vl-30b
qwen3-coder-next
qwen3.5-122b-a10b
gpt-oss-120b
EOF
}

model_source() {
  case "$1" in
    ministral-3b) echo "mistralai/ministral-3-3b" ;;
    qwen3-vl-8b) echo "qwen/qwen3-vl-8b" ;;
    qwen3-vl-30b) echo "qwen/qwen3-vl-30b" ;;
    qwen3-coder-next) echo "qwen3-coder-next-0" ;;
    qwen3.5-122b-a10b) echo "qwen_qwen3.5-122b-a10b" ;;
    gpt-oss-120b) echo "gpt-oss-120b" ;;
    *) return 1 ;;
  esac
}

model_identifier() {
  case "$1" in
    ministral-3b) echo "local/ministral-3b" ;;
    qwen3-vl-8b) echo "local/qwen3-vl-8b" ;;
    qwen3-vl-30b) echo "local/qwen3-vl-30b" ;;
    qwen3-coder-next) echo "local/qwen3-coder-next" ;;
    qwen3.5-122b-a10b) echo "local/qwen3.5-122b-a10b" ;;
    gpt-oss-120b) echo "local/gpt-oss-120b" ;;
    *) return 1 ;;
  esac
}

require_runtime_deps() {
  if ! command -v "$LMS_BIN" >/dev/null 2>&1; then
    die_missing_dep "'lms' is required but not found. Install LM Studio CLI and ensure lms is on PATH, or set LOCAL_MODELS_LMS_BIN."
  fi
  if ! command -v "$CURL_BIN" >/dev/null 2>&1; then
    die_missing_dep "'curl' is required but not found, or set LOCAL_MODELS_CURL_BIN."
  fi
  if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    die_missing_dep "'python3' is required but not found, or set LOCAL_MODELS_PYTHON_BIN."
  fi
}

require_alias() {
  if ! model_source "$1" >/dev/null 2>&1; then
    die_usage "unknown local model alias: $1 (run: local-models list)"
  fi
}

configured_host() {
  local rest hostport
  rest="${BASE_URL#http://}"
  hostport="${rest%%/*}"
  echo "${hostport%:*}"
}

configured_port() {
  local rest hostport port
  rest="${BASE_URL#http://}"
  hostport="${rest%%/*}"
  port="${hostport##*:}"
  [[ "$port" != "$hostport" ]] || die_usage "LOCAL_MODELS_BASE_URL must include an explicit port: $BASE_URL"
  case "$port" in
    *[!0-9]* | "") die_usage "LOCAL_MODELS_BASE_URL has invalid port: $BASE_URL" ;;
  esac
  echo "$port"
}

models_url() {
  printf '%s/models\n' "${BASE_URL%/}"
}

endpoint_responds() {
  "$CURL_BIN" -fsS "$(models_url)" >/dev/null 2>&1
}

python_json_helper() {
  "$PYTHON_BIN" - "$@"
}

server_status_report() {
  local status report
  if ! status="$({ "$LMS_BIN" server status --json --quiet; } 2>&1)"; then
    die_upstream "lms server status failed: $status"
  fi
  if ! report="$(
    LOCAL_MODELS_JSON="$status" python_json_helper <<'PY'
import json
import os
import sys
from urllib.parse import urlparse

raw = os.environ.get("LOCAL_MODELS_JSON", "")

def load_status(text):
    try:
        return json.loads(text)
    except Exception:
        pass

    decoder = json.JSONDecoder()
    last = None
    for index, char in enumerate(text):
        if char != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except Exception:
            continue
        last = value
    if last is not None:
        return last
    raise ValueError("no JSON object found")

def walk_dicts(value):
    if not isinstance(value, dict):
        return
    yield value
    for nested_key in ("server", "status", "config", "listen", "httpServer", "apiServer"):
        nested = value.get(nested_key)
        if isinstance(nested, dict):
            yield nested

def pick(data, keys):
    for item in walk_dicts(data):
        for key in keys:
            value = item.get(key)
            if value not in (None, ""):
                return value
    return ""

def truthy(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in ("1", "true", "yes", "running")
    return bool(value)

def normalize_host_port(host, port):
    host = "" if host in (None, "") else str(host)
    port = "" if port in (None, "") else str(port)

    url_value = pick(data, ("url", "baseUrl", "baseURL", "endpoint"))
    if url_value:
        parsed = urlparse(str(url_value))
        if parsed.hostname and not host:
            host = parsed.hostname
        if parsed.port and not port:
            port = str(parsed.port)

    if host.startswith("http://") or host.startswith("https://"):
        parsed = urlparse(host)
        if parsed.hostname:
            host = parsed.hostname
        if parsed.port and not port:
            port = str(parsed.port)
    elif host.count(":") == 1:
        maybe_host, maybe_port = host.rsplit(":", 1)
        if maybe_port.isdigit():
            host = maybe_host
            if not port:
                port = maybe_port

    return host, port

try:
    data = load_status(raw)
except Exception as exc:
    print(f"ERROR\t{exc}")
    sys.exit(1)

if not isinstance(data, dict):
    print("ERROR\tstatus JSON was not an object")
    sys.exit(1)

running = truthy(pick(data, ("running", "isRunning", "serverRunning")))
host = pick(data, ("host", "hostname", "bind", "bindHost", "bindAddress", "address", "serverHost", "hostAddress"))
port = pick(data, ("port", "serverPort", "listenPort", "apiPort"))
host, port = normalize_host_port(host, port)

print("RUNNING\t{}".format("yes" if running else "no"))
print("HOST\t{}".format(host))
print("PORT\t{}".format(port))
print("SUMMARY\trunning={} host={} port={}".format(
    str(running).lower(),
    host or "<unreported>",
    port or "<unreported>",
))
PY
  )"; then
    die_upstream "could not parse lms server status --json output: $status"
  fi
  printf '%s\n' "$report"
}

status_field() {
  local key="$1"
  awk -F '\t' -v key="$key" '$1 == key {print $2; exit}'
}

server_running() {
  local report
  report="$(server_status_report)" || exit $?
  printf '%s\n' "$report" | status_field RUNNING
}

normalize_host_for_compare() {
  local host lower
  host="$1"
  host="${host#[}"
  host="${host%]}"
  lower="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    localhost | 127.0.0.1 | ::1) echo "loopback" ;;
    *) echo "$lower" ;;
  esac
}

status_summary() {
  printf '%s\n' "$1" | status_field SUMMARY
}

status_matches_config() {
  local report="$1"
  local running actual_host actual_port expected_host expected_port
  running="$(printf '%s\n' "$report" | status_field RUNNING)"
  actual_host="$(printf '%s\n' "$report" | status_field HOST)"
  actual_port="$(printf '%s\n' "$report" | status_field PORT)"
  expected_host="$(configured_host)"
  expected_port="$(configured_port)"

  [[ "$running" == "yes" ]] || return 1
  [[ -n "$actual_port" && "$actual_port" == "$expected_port" ]] || return 1
  if [[ -n "$actual_host" ]]; then
    [[ "$(normalize_host_for_compare "$actual_host")" == "$(normalize_host_for_compare "$expected_host")" ]] || return 1
  fi
  return 0
}

require_status_matches_config() {
  local report="$1"
  local reason="$2"
  local expected_host expected_port summary
  status_matches_config "$report" && return 0

  expected_host="$(configured_host)"
  expected_port="$(configured_port)"
  summary="$(status_summary "$report")"

  die_upstream "$reason; lms server status reports $summary, expected host=$expected_host port=$expected_port for $BASE_URL. Stop the process on $(models_url), reconfigure LM Studio, or set LOCAL_MODELS_BASE_URL to the LM Studio endpoint."
}

installed_sources() {
  local out
  if ! out="$({ "$LMS_BIN" ls --json; } 2>&1)"; then
    die_upstream "lms ls --json failed: $out"
  fi
  LOCAL_MODELS_JSON="$out" python_json_helper <<'PY'
import json, sys
import os
try:
    data = json.loads(os.environ.get('LOCAL_MODELS_JSON', ''))
except Exception:
    sys.exit(1)
for item in data if isinstance(data, list) else []:
    if item.get("type") == "embedding":
        continue
    for key in ("modelKey", "indexedModelIdentifier", "path"):
        value = item.get(key)
        if value:
            print(value)
PY
}

loaded_identifiers() {
  local out
  if ! out="$({ "$LMS_BIN" ps --json; } 2>&1)"; then
    die_upstream "lms ps --json failed: $out"
  fi
  LOCAL_MODELS_JSON="$out" python_json_helper <<'PY'
import json, sys
import os
try:
    data = json.loads(os.environ.get('LOCAL_MODELS_JSON', ''))
except Exception:
    sys.exit(1)
if isinstance(data, dict):
    data = data.get("models") or data.get("data") or []
for item in data if isinstance(data, list) else []:
    if isinstance(item, str):
        print(item)
        continue
    if not isinstance(item, dict):
        continue
    for key in ("identifier", "id", "modelIdentifier", "loadedIdentifier"):
        value = item.get(key)
        if value:
            print(value)
            break
PY
}

contains_line() {
  local needle="$1"
  while IFS= read -r line; do
    [[ "$line" == "$needle" ]] && return 0
  done
  return 1
}

jsonc_config_report() {
  python_json_helper "$OPENCODE_CONFIG" <<'PY'
import json, re, sys

path = sys.argv[1]

def strip_jsonc(src):
    out = []
    i = 0
    n = len(src)
    in_str = False
    quote = ''
    escape = False
    while i < n:
        ch = src[i]
        nxt = src[i + 1] if i + 1 < n else ''
        if in_str:
            out.append(ch)
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == quote:
                in_str = False
            i += 1
            continue
        if ch in ('"', "'"):
            in_str = True
            quote = ch
            out.append(ch)
            i += 1
            continue
        if ch == '/' and nxt == '/':
            i += 2
            while i < n and src[i] not in '\r\n':
                i += 1
            continue
        if ch == '/' and nxt == '*':
            i += 2
            while i + 1 < n and not (src[i] == '*' and src[i + 1] == '/'):
                i += 1
            i += 2
            continue
        out.append(ch)
        i += 1
    stripped = ''.join(out)
    stripped = re.sub(r',\s*([}\]])', r'\1', stripped)
    return stripped

try:
    with open(path, encoding='utf-8') as f:
        config = json.loads(strip_jsonc(f.read()))
except Exception as exc:
    print(f"ERROR\tparse\t{exc}")
    sys.exit(0)

provider = (config.get('provider') or {}).get('lmstudio') or {}
print('NPM\t' + str(provider.get('npm', '')))
print('BASEURL\t' + str((provider.get('options') or {}).get('baseURL', '')))
models = provider.get('models') or {}
for key in sorted(models):
    limit = models.get(key, {}).get('limit') or {}
    print('MODEL\t{}\t{}\t{}'.format(key, limit.get('context', ''), limit.get('output', '')))
PY
}

expected_identifiers() {
  local alias
  all_aliases | while IFS= read -r alias; do
    model_identifier "$alias"
  done
}

validate_config() {
  [[ -f "$OPENCODE_CONFIG" ]] || die "OpenCode config not found: $OPENCODE_CONFIG"

  local report npm base expected actual missing extra bad_limits line key ctx out
  report="$(jsonc_config_report)"
  if printf '%s\n' "$report" | awk -F '\t' '$1=="ERROR" {found=1} END {exit !found}'; then
    die "cannot parse OpenCode JSONC config: $(printf '%s\n' "$report" | awk -F '\t' '$1=="ERROR" {print $3; exit}')"
  fi

  npm="$(printf '%s\n' "$report" | awk -F '\t' '$1=="NPM" {print $2; exit}')"
  base="$(printf '%s\n' "$report" | awk -F '\t' '$1=="BASEURL" {print $2; exit}')"
  [[ "$npm" == "@ai-sdk/openai-compatible" ]] || die "OpenCode provider.lmstudio.npm must be @ai-sdk/openai-compatible (found: ${npm:-<missing>})"
  [[ "$base" == "$BASE_URL" ]] || die "OpenCode provider.lmstudio.options.baseURL mismatch: expected $BASE_URL, found ${base:-<missing>}"

  expected="$(expected_identifiers | sort)"
  actual="$(printf '%s\n' "$report" | awk -F '\t' '$1=="MODEL" {print $2}' | sort)"
  missing="$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))"
  extra="$(comm -13 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))"
  if [[ -n "$missing" || -n "$extra" ]]; then
    {
      printf 'OpenCode lmstudio model keys do not match script mapping.\n'
      [[ -z "$missing" ]] || printf 'Missing:\n%s\n' "$missing"
      [[ -z "$extra" ]] || printf 'Extra:\n%s\n' "$extra"
    } >&2
    exit 1
  fi

  bad_limits=0
  while IFS=$'\t' read -r line key ctx out; do
    [[ "$line" == "MODEL" ]] || continue
    if [[ "$ctx" != "$DEFAULT_CONTEXT_LENGTH" || "$out" != "$DEFAULT_OUTPUT_LIMIT" ]]; then
      warn "unexpected limits for $key: context=$ctx output=$out (expected ${DEFAULT_CONTEXT_LENGTH}/${DEFAULT_OUTPUT_LIMIT})"
      bad_limits=1
    fi
  done <<EOF
$report
EOF
  [[ "$bad_limits" == "0" ]] || die "OpenCode lmstudio model limits drifted"
}

cmd_start() {
  require_runtime_deps
  local status running host port attempt max_attempts sleep_seconds
  status="$(server_status_report)" || exit $?
  running="$(printf '%s\n' "$status" | status_field RUNNING)"
  if endpoint_responds; then
    require_status_matches_config "$status" "$(models_url) responds, but LM Studio CLI status does not match configured $BASE_URL; refusing to treat a random OpenAI-compatible service as LM Studio"
    info "LM Studio server ready at $BASE_URL"
    return 0
  fi

  if [[ "$running" == "yes" ]]; then
    die_upstream "LM Studio server is running ($(status_summary "$status")), but configured endpoint $BASE_URL is not responding; not restarting or killing it automatically. Stop/reconfigure LM Studio or set LOCAL_MODELS_BASE_URL to the reported endpoint."
  fi

  host="$(configured_host)"
  port="$(configured_port)"
  info "Starting LM Studio server at $BASE_URL"
  if ! "$LMS_BIN" server start --bind "$host" --port "$port"; then
    die_upstream "lms server start --bind $host --port $port failed"
  fi

  max_attempts="${LOCAL_MODELS_START_WAIT_ATTEMPTS:-20}"
  sleep_seconds="${LOCAL_MODELS_START_WAIT_SLEEP:-0.25}"
  attempt=0
  while [[ "$attempt" -lt "$max_attempts" ]]; do
    if endpoint_responds; then
      status="$(server_status_report)" || exit $?
      require_status_matches_config "$status" "$(models_url) responds after start, but LM Studio CLI status does not match configured $BASE_URL"
      info "LM Studio server ready at $BASE_URL"
      return 0
    fi
    sleep "$sleep_seconds"
    attempt=$((attempt + 1))
  done
  die_upstream "LM Studio server did not respond at $(models_url) after start"
}

cmd_list() {
  require_runtime_deps
  local installed loaded alias source identifier installed_status loaded_status
  installed="$(installed_sources)"
  loaded="$(loaded_identifiers)"
  printf '%-22s %-34s %-32s %s %s\n' "alias" "source" "identifier" "installed" "loaded"
  all_aliases | while IFS= read -r alias; do
    source="$(model_source "$alias")"
    identifier="$(model_identifier "$alias")"
    installed_status="no"
    loaded_status="no"
    if printf '%s\n' "$installed" | contains_line "$source"; then
      installed_status="yes"
    fi
    if printf '%s\n' "$loaded" | contains_line "$identifier"; then
      loaded_status="yes"
    fi
    printf '%-22s %-34s %-32s installed=%s loaded=%s\n' "$alias" "$source" "$identifier" "$installed_status" "$loaded_status"
  done
}

check_installed_models() {
  local installed alias source missing
  installed="$(installed_sources)"
  missing=0
  all_aliases | while IFS= read -r alias; do
    source="$(model_source "$alias")"
    if ! printf '%s\n' "$installed" | contains_line "$source"; then
      printf 'Missing installed LM Studio source model for %s: %s\n' "$alias" "$source" >&2
      missing=1
    fi
    [[ "$missing" == "0" ]] || exit 1
  done
}

cmd_verify() {
  require_runtime_deps
  cmd_start
  check_installed_models || die "one or more mapped source models are not installed in LM Studio"
  validate_config
  info "verification passed: LM Studio CLI, endpoint, installed source models, and OpenCode config are aligned"
}

cmd_status() {
  require_runtime_deps
  local status running loaded config_status server_host server_port
  status="$(server_status_report)" || exit $?
  running="$(printf '%s\n' "$status" | status_field RUNNING)"
  server_host="$(printf '%s\n' "$status" | status_field HOST)"
  server_port="$(printf '%s\n' "$status" | status_field PORT)"
  printf 'baseURL: %s\n' "$BASE_URL"
  printf 'server_running: %s\n' "$running"
  printf 'server_host: %s\n' "${server_host:-<unreported>}"
  printf 'server_port: %s\n' "${server_port:-<unreported>}"
  if endpoint_responds; then
    printf 'endpoint: responding\n'
  else
    printf 'endpoint: not responding\n'
  fi
  loaded="$(loaded_identifiers)"
  if [[ -n "$loaded" ]]; then
    printf 'loaded_local_identifiers:\n'
    printf '%s\n' "$loaded" | while IFS= read -r line; do
      case "$line" in
        local/*) printf '  %s\n' "$line" ;;
      esac
    done
  else
    printf 'loaded_local_identifiers: none\n'
  fi
  if validate_config >/dev/null 2>&1; then
    config_status="aligned"
  else
    config_status="drifted"
  fi
  printf 'opencode_config: %s (%s)\n' "$config_status" "$OPENCODE_CONFIG"
}

estimate_decision() {
  local estimate_text
  estimate_text="$(cat)"
  LOCAL_MODELS_ESTIMATE="$estimate_text" LOCAL_MODELS_MEMORY_AUTO_LIMIT_GIB="$MEMORY_AUTO_LIMIT_GIB" python_json_helper <<'PY'
import re, sys
import os
text = os.environ.get('LOCAL_MODELS_ESTIMATE', '')
limit_gib = float(os.environ.get('LOCAL_MODELS_MEMORY_AUTO_LIMIT_GIB', '16'))
memory = None
confidence = None
for line in text.splitlines():
    if 'Estimated Total Memory' in line:
        m = re.search(r'([0-9]+(?:\.[0-9]+)?)\s*(GiB|GB|MiB|MB)', line, re.I)
        if m:
            value = float(m.group(1))
            unit = m.group(2).lower()
            memory = value / 1024.0 if unit in ('mib', 'mb') else value
    m = re.search(r'Confidence:\s*([A-Za-z]+)', line)
    if m:
        confidence = m.group(1).upper()
lower = text.lower()
unfavorable = any(s in lower for s in ('may not', 'cannot', "can't", 'not be loaded', 'insufficient', 'exceed'))
favorable = any(s in lower for s in ('may be loaded', 'can be loaded', 'sufficient', 'within')) and not unfavorable
known_conf = confidence in ('HIGH', 'MEDIUM')
auto = memory is not None and memory <= limit_gib and favorable and known_conf
print('auto' if auto else 'prompt')
print('memory_gib={}'.format('' if memory is None else ('%.2f' % memory)))
print('confidence={}'.format('' if confidence is None else confidence))
PY
}

cmd_load() {
  [[ $# -ge 1 ]] || die_usage "load requires an alias"
  local alias="$1"
  shift
  require_alias "$alias"

  local context_length ttl yes source identifier estimate decision decision_kind answer
  context_length="$DEFAULT_CONTEXT_LENGTH"
  ttl=""
  yes=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context-length | -c)
        [[ $# -ge 2 ]] || die_usage "missing value for $1"
        context_length="$2"
        shift 2
        ;;
      --ttl)
        [[ $# -ge 2 ]] || die_usage "missing value for $1"
        ttl="$2"
        shift 2
        ;;
      -y | --yes)
        yes=1
        shift
        ;;
      *)
        die_usage "unknown load flag: $1"
        ;;
    esac
  done
  case "$context_length" in *[!0-9]* | "") die_usage "--context-length must be an integer" ;; esac
  if [[ -n "$ttl" ]]; then
    case "$ttl" in *[!0-9]* | "") die_usage "--ttl must be an integer number of seconds" ;; esac
  fi

  require_runtime_deps
  cmd_verify
  source="$(model_source "$alias")"
  identifier="$(model_identifier "$alias")"

  if ! estimate="$({ "$LMS_BIN" load "$source" --identifier "$identifier" --context-length "$context_length" --estimate-only; } 2>&1)"; then
    die_upstream "lms load estimate failed for $alias: $estimate"
  fi
  printf '%s\n' "$estimate" >&2
  decision="$(printf '%s\n' "$estimate" | estimate_decision)"
  decision_kind="$(printf '%s\n' "$decision" | awk 'NR==1 {print $1}')"
  if [[ "$decision_kind" != "auto" && "$yes" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      die "estimate for $alias requires confirmation; rerun interactively or pass --yes to override"
    fi
    printf 'Estimate for %s requires confirmation. Load %s as %s? [y/N] ' "$alias" "$source" "$identifier" >&2
    read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *) die "load cancelled" ;;
    esac
  fi

  LOAD_ARGS=("load" "$source" "--identifier" "$identifier" "--context-length" "$context_length")
  if [[ -n "$ttl" ]]; then
    LOAD_ARGS+=("--ttl" "$ttl")
  fi
  if [[ "$yes" == "1" ]]; then
    LOAD_ARGS+=("--yes")
  fi
  if ! "$LMS_BIN" ${LOAD_ARGS[@]+"${LOAD_ARGS[@]}"}; then
    die_upstream "lms load failed for $alias ($identifier)"
  fi
  info "loaded $alias as $identifier"
}

cmd_unload() {
  [[ $# -ge 1 ]] || die_usage "unload requires an alias or --all-local"
  require_runtime_deps
  local target id loaded unload_rc
  target="$1"
  case "$target" in
    --all-local)
      loaded="$(loaded_identifiers)"
      unload_rc=0
      while IFS= read -r id; do
        case "$id" in
          local/*)
            if ! "$LMS_BIN" unload "$id"; then
              unload_rc=5
            fi
            ;;
        esac
      done <<EOF
$loaded
EOF
      if [[ "$unload_rc" -ne 0 ]]; then
        die_upstream "one or more local model unloads failed"
      fi
      info "unloaded loaded local/ identifiers"
      ;;
    *)
      require_alias "$target"
      id="$(model_identifier "$target")"
      if ! "$LMS_BIN" unload "$id"; then
        die_upstream "lms unload failed for $target ($id)"
      fi
      info "unloaded $id"
      ;;
  esac
}

main() {
  [[ $# -ge 1 ]] || {
    usage
    exit 0
  }
  case "$1" in
    help | -h | --help)
      usage
      ;;
    list)
      shift
      [[ $# -eq 0 ]] || die_usage "list takes no arguments"
      cmd_list
      ;;
    status)
      shift
      [[ $# -eq 0 ]] || die_usage "status takes no arguments"
      cmd_status
      ;;
    start)
      shift
      [[ $# -eq 0 ]] || die_usage "start takes no arguments"
      cmd_start
      ;;
    verify)
      shift
      [[ $# -eq 0 ]] || die_usage "verify takes no arguments"
      cmd_verify
      ;;
    load)
      shift
      cmd_load "$@"
      ;;
    unload)
      shift
      cmd_unload "$@"
      ;;
    *)
      die_usage "unknown command: $1"
      ;;
  esac
}

main "$@"
