#!/usr/bin/env bash
# local-models.sh — manage LM Studio local models used by OpenCode.
#
# Discover installed LM Studio models and reconcile selected IDs with OpenCode.
# Runtime actions are explicit; discovery/status do not start the server.

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
MEMORY_AUTO_LIMIT_GIB=16
LOW_CONTEXT_THRESHOLD="${LOCAL_MODELS_LOW_CONTEXT_THRESHOLD:-65536}"

usage() {
  cat <<'EOF'
Usage: local-models <command> [OPTIONS]

Manage installed non-embedding LM Studio models for OpenCode.
Discovery is dynamic; configured catalog IDs take precedence, otherwise a load
uses the exact LM Studio model key as its API identifier.

Commands:
  help, -h, --help
      Show this help.
  list
      Show every installed non-embedding LM Studio model key.
  status
      Show endpoint/server status, loaded runtime identifiers, and compatibility.
  start
      Start LM Studio server on http://127.0.0.1:1234/v1 if needed and verify
      /v1/models responds. Does not load models.
  verify
      Check configuration and runtime compatibility without starting LM Studio.
  load [model-key|catalog-key] [--identifier ID] [--context-length N]
       [--ttl seconds] [-y|--yes]
      Load one discovered model. If the key is omitted, choose from a numbered
      TTY menu. Estimate and confirm before loading.
  unload <identifier|model-key>
      Unload only the exact resolved runtime identifier.
  unload --all-local
      Unload only loaded identifiers beginning with local/.

Environment overrides for tests/advanced use:
  LOCAL_MODELS_LMS_BIN          lms binary path/name
  LOCAL_MODELS_CURL_BIN         curl binary path/name
  LOCAL_MODELS_PYTHON_BIN       python3 binary path/name
  LOCAL_MODELS_OPENCODE_CONFIG  OpenCode JSONC config path
  LOCAL_MODELS_BASE_URL         OpenAI-compatible base URL
  LOCAL_MODELS_LOW_CONTEXT_THRESHOLD  Advisory context threshold (default 65536)

Exit codes follow lib/common.sh: 1 runtime, 2 usage, 3 missing dep, 5 upstream.
EOF
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

native_models_url() {
  local server_url
  server_url="${BASE_URL%/}"
  server_url="${server_url%/v1}"
  printf '%s/api/v1/models\n' "${server_url%/}"
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
  local out sources
  if ! out="$({ "$LMS_BIN" ls --json; } 2>&1)"; then
    die_upstream "lms ls --json failed: $out"
  fi
  if ! sources="$(
    LOCAL_MODELS_JSON="$out" python_json_helper <<'PY'
import json, sys
import os
try:
    data = json.loads(os.environ.get('LOCAL_MODELS_JSON', ''))
except Exception:
    sys.exit(1)
if isinstance(data, dict):
    if isinstance(data.get("models"), list):
        data = data["models"]
    elif isinstance(data.get("data"), list):
        data = data["data"]
    else:
        sys.exit(1)
if not isinstance(data, list):
    sys.exit(1)
for item in data:
    if not isinstance(item, dict):
        continue
    if str(item.get("type", "")).lower() == "embedding":
        continue
    value = item.get("modelKey")
    if isinstance(value, str) and value and not any(ch in value for ch in "\t\r\n\x00"):
        print(value)
PY
  )"; then
    die_upstream "could not parse lms ls --json output"
  fi
  printf '%s\n' "$sources"
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

def safe_identifier(value):
    return isinstance(value, str) and value and not any(ch in value for ch in "\t\r\n\x00")

for item in data if isinstance(data, list) else []:
    if isinstance(item, str):
        if safe_identifier(item):
            print(item)
        continue
    if not isinstance(item, dict):
        continue
    for key in ("identifier", "id", "modelIdentifier", "loadedIdentifier"):
        value = item.get(key)
        if safe_identifier(value):
            print(value)
            break
PY
}

native_models_report() {
  local raw
  if ! raw="$({ "$CURL_BIN" -fsS "$(native_models_url)"; } 2>/dev/null)"; then
    return 1
  fi
  LOCAL_MODELS_JSON="$raw" python_json_helper <<'PY'
import json
import os
import sys

try:
    data = json.loads(os.environ.get("LOCAL_MODELS_JSON", ""))
except Exception:
    sys.exit(1)

models = data.get("models") if isinstance(data, dict) else data
if not isinstance(models, list):
    sys.exit(1)
print("NATIVE\tavailable")

def safe(value):
    return isinstance(value, str) and value and not any(ch in value for ch in "\t\r\n\x00")

def positive_integer(value):
    if isinstance(value, bool):
        return ""
    if isinstance(value, int) and value > 0:
        return str(value)
    return ""

for model in models:
    if not isinstance(model, dict):
        continue
    key = model.get("key")
    if not safe(key):
        continue
    maximum = positive_integer(model.get("max_context_length"))
    print("MODEL\t{}\t{}".format(key, maximum))
    if "loaded_instances" not in model:
        print("ASSOCIATION_UNKNOWN\t{}".format(key))
        continue
    instances = model.get("loaded_instances")
    if not isinstance(instances, list):
        print("ASSOCIATION_UNKNOWN\t{}".format(key))
        continue
    for instance in instances:
        if not isinstance(instance, dict):
            print("ASSOCIATION_UNKNOWN\t{}".format(key))
            continue
        identifier = instance.get("id")
        if not safe(identifier):
            print("ASSOCIATION_UNKNOWN\t{}".format(key))
            continue
        config = instance.get("config")
        context = positive_integer(config.get("context_length")) if isinstance(config, dict) else ""
        print("INSTANCE\t{}\t{}\t{}".format(key, identifier, context))
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

def fail(message):
    print('ERROR\tconfig\t' + message)
    sys.exit(0)

def report_field(value, field):
    text = str(value)
    if any(character in text for character in ('\t', '\n', '\r', '\x00')):
        fail('{} contains a tab, line break, or NUL'.format(field))
    return text

if not isinstance(config, dict):
    fail('OpenCode config root must be an object')

native_providers = config.get('providers')
if isinstance(native_providers, dict) and 'lmstudio' in native_providers:
    provider_format = 'native'
    provider_path = 'providers.lmstudio'
    provider = native_providers['lmstudio']
    adapter_field = 'package'
    settings_field = 'settings'
    url_field = 'baseURL'
    if not isinstance(provider, dict):
        fail('providers.lmstudio must be an object')
    if 'npm' in provider or 'options' in provider:
        fail('providers.lmstudio mixes native package/settings with legacy npm/options fields')
    adapter = provider.get('package', '')
    settings = provider.get('settings')
else:
    legacy_providers = config.get('provider')
    if isinstance(legacy_providers, dict) and 'lmstudio' in legacy_providers:
        provider = legacy_providers['lmstudio']
        if not isinstance(provider, dict):
            fail('provider.lmstudio must be an object')
    else:
        provider = {}
    provider_format = 'legacy'
    provider_path = 'provider.lmstudio'
    adapter_field = 'npm'
    settings_field = 'options'
    url_field = 'baseURL'
    if 'package' in provider or 'settings' in provider:
        fail('provider.lmstudio mixes legacy npm/options with native package/settings fields')
    adapter = provider.get('npm', '')
    settings = provider.get('options')

if not isinstance(adapter, str):
    fail('{}.{} must be a string'.format(provider_path, adapter_field))
if not isinstance(settings, dict):
    fail('{}.{} must be an object'.format(provider_path, settings_field))
base_url = settings.get(url_field, '')
if not isinstance(base_url, str):
    fail('{}.{}.{} must be a string'.format(provider_path, settings_field, url_field))
adapter = report_field(adapter, '{}.{}'.format(provider_path, adapter_field))
base_url = report_field(base_url, '{}.{}.{}'.format(provider_path, settings_field, url_field))

models = provider.get('models', {})
if not isinstance(models, dict):
    fail('{}.models must be an object'.format(provider_path))

print('FORMAT\t' + provider_format)
print('ADAPTER\t' + adapter)
print('BASEURL\t' + base_url)
for key in sorted(models):
    key = report_field(key, '{}.models key'.format(provider_path))
    model = models[key]
    if not isinstance(model, dict):
        fail('{}.models.{} must be an object'.format(provider_path, key))
    model_id = model.get('modelID') or key
    if not isinstance(model_id, str):
        fail('{}.models.{}.modelID must be a string'.format(provider_path, key))
    limit = model.get('limit', {})
    if not isinstance(limit, dict):
        fail('{}.models.{}.limit must be an object'.format(provider_path, key))
    context_value = limit.get('context')
    output_value = limit.get('output')
    context = ''
    output = ''
    if context_value not in (None, ''):
        if isinstance(context_value, str):
            context_value = report_field(context_value, '{}.models.limit.context'.format(provider_path))
            if not re.fullmatch(r'[0-9]+', context_value) or int(context_value) < 1:
                fail('{}.models.limit.context must be a positive integer'.format(provider_path))
            context = context_value
        elif isinstance(context_value, int) and not isinstance(context_value, bool) and context_value > 0:
            context = str(context_value)
        else:
            fail('{}.models.limit.context must be a positive integer'.format(provider_path))
    if output_value not in (None, ''):
        if isinstance(output_value, str):
            output_value = report_field(output_value, '{}.models.limit.output'.format(provider_path))
            if not re.fullmatch(r'[0-9]+', output_value) or int(output_value) < 1:
                fail('{}.models.limit.output must be a positive integer'.format(provider_path))
            output = output_value
        elif isinstance(output_value, int) and not isinstance(output_value, bool) and output_value > 0:
            output = str(output_value)
        else:
            fail('{}.models.limit.output must be a positive integer'.format(provider_path))
    model_id = report_field(model_id, '{}.models.{}.modelID'.format(provider_path, key))
    context = report_field(context, '{}.models.limit.context'.format(provider_path))
    output = report_field(output, '{}.models.limit.output'.format(provider_path))
    print('MODEL\t{}\t{}\t{}\t{}'.format(key, model_id, context, output))
PY
}

validate_config() {
  [[ -f "$OPENCODE_CONFIG" ]] || die "OpenCode config not found: $OPENCODE_CONFIG"

  local report report_error_kind report_error_message provider_format adapter base
  report="$(jsonc_config_report)"
  report_error_kind="$(printf '%s\n' "$report" | awk -F '\t' '$1=="ERROR" {print $2; exit}')"
  if [[ -n "$report_error_kind" ]]; then
    report_error_message="$(printf '%s\n' "$report" | awk -F '\t' '$1=="ERROR" {print $3; exit}')"
    case "$report_error_kind" in
      parse) die "cannot parse OpenCode JSONC config: $report_error_message" ;;
      *) die "invalid OpenCode LM Studio config: $report_error_message" ;;
    esac
  fi

  provider_format="$(printf '%s\n' "$report" | awk -F '\t' '$1=="FORMAT" {print $2; exit}')"
  adapter="$(printf '%s\n' "$report" | awk -F '\t' '$1=="ADAPTER" {print $2; exit}')"
  base="$(printf '%s\n' "$report" | awk -F '\t' '$1=="BASEURL" {print $2; exit}')"
  case "$provider_format" in
    legacy)
      [[ "$adapter" == "@ai-sdk/openai-compatible" ]] || die "OpenCode provider.lmstudio.npm must be @ai-sdk/openai-compatible (found: ${adapter:-<missing>})"
      [[ "$base" == "$BASE_URL" ]] || die "OpenCode provider.lmstudio.options.baseURL mismatch: expected $BASE_URL, found ${base:-<missing>}"
      ;;
    native)
      case "$adapter" in
        @opencode/ai/providers/openai-compatible | aisdk:@ai-sdk/openai-compatible) ;;
        *) die "OpenCode providers.lmstudio.package must be @opencode/ai/providers/openai-compatible or aisdk:@ai-sdk/openai-compatible (found: ${adapter:-<missing>})" ;;
      esac
      [[ "$base" == "$BASE_URL" ]] || die "OpenCode providers.lmstudio.settings.baseURL mismatch: expected $BASE_URL, found ${base:-<missing>}"
      ;;
    *)
      die "cannot select OpenCode LM Studio provider config format"
      ;;
  esac

  info "OpenCode LM Studio provider config is valid; model catalog is not roster-locked"
}

report_compatibility() {
  local config_report="$1"
  local runtime_report="$2"
  LOCAL_MODELS_CONFIG_REPORT="$config_report" LOCAL_MODELS_RUNTIME_REPORT="$runtime_report" python_json_helper <<'PY'
import os
import sys

configured = []
for line in os.environ.get("LOCAL_MODELS_CONFIG_REPORT", "").splitlines():
    fields = line.split("\t")
    if fields[0] == "MODEL" and len(fields) == 5:
        configured.append({"key": fields[1], "id": fields[2], "context": fields[3]})

runtime_models = []
instances = []
unknown_associations = set()
runtime_available = False
for line in os.environ.get("LOCAL_MODELS_RUNTIME_REPORT", "").splitlines():
    fields = line.split("\t")
    if fields[0] == "NATIVE":
        runtime_available = True
    elif fields[0] == "MODEL" and len(fields) == 3:
        runtime_models.append({"key": fields[1], "max": fields[2]})
    elif fields[0] == "INSTANCE" and len(fields) == 4:
        instances.append({"key": fields[1], "id": fields[2], "context": fields[3]})
    elif fields[0] == "ASSOCIATION_UNKNOWN" and len(fields) == 2:
        unknown_associations.add(fields[1])

if not configured:
    print("runtime compatibility: unverified (no configured model entries)")
known_incompatible = False
for model in configured:
    label = model["key"]
    matches = [item for item in runtime_models if item["key"] == model["id"]]
    if not matches:
        reason = "native metadata unavailable" if not runtime_available else "no exact LM Studio model-key association"
        print("runtime compatibility {}: unverified ({})".format(label, reason))
        continue
    if len(matches) != 1:
        print("runtime compatibility {}: ambiguous duplicate runtime model key".format(label))
        continue
    loaded = [item for item in instances if item["key"] == model["id"]]
    if not loaded:
        if model["id"] in unknown_associations:
            print("runtime compatibility {}: unverified (loaded-instance association unavailable)".format(label))
        else:
            print("runtime compatibility {}: unverified (model is not loaded)".format(label))
        continue
    if len(loaded) != 1:
        print("runtime compatibility {}: ambiguous loaded instances".format(label))
        continue
    instance = loaded[0]
    duplicate_ids = [item for item in instances if item["id"] == instance["id"]]
    if len(duplicate_ids) != 1:
        print("runtime compatibility {}: ambiguous duplicate loaded runtime ID {}".format(label, instance["id"]))
        continue
    if instance["id"] != model["id"]:
        print("runtime compatibility {}: incompatible (loaded ID {}, configured modelID {})".format(label, instance["id"], model["id"]))
        known_incompatible = True
        continue
    if not model["context"] or not instance["context"]:
        print("runtime compatibility {}: unverified (configured or actual context is missing)".format(label))
        continue
    if int(instance["context"]) < int(model["context"]):
        print("runtime compatibility {}: incompatible (actual context {} is below configured {})".format(label, instance["context"], model["context"]))
        known_incompatible = True
    else:
        print("runtime compatibility {}: compatible (actual context {})".format(label, instance["context"]))
sys.exit(1 if known_incompatible else 0)
PY
}

print_partial_model_fragment() {
  local identifier="$1"
  local context="$2"
  LOCAL_MODELS_FRAGMENT_ID="$identifier" LOCAL_MODELS_FRAGMENT_CONTEXT="$context" python_json_helper <<'PY'
import json
import os

identifier = os.environ.get("LOCAL_MODELS_FRAGMENT_ID", "")
context = os.environ.get("LOCAL_MODELS_FRAGMENT_CONTEXT", "")
warning = "PARTIAL_REVIEW_REQUIRED: OpenCode custom-model defaults include 200000 context and 32000 output, plus tools and images; verify output and capabilities before use."
result = {"status": "PARTIAL_REVIEW_REQUIRED", "review_warning": warning}
if identifier and context.isdigit():
    result["providers"] = {"lmstudio": {"models": {identifier: {"modelID": identifier, "limit": {"context": int(context)}}}}}
else:
    result["verification"] = "Actual served ID or runtime context is unverified; no model claims are emitted."
print(json.dumps(result, indent=2, sort_keys=True))
PY
}

report_loaded_result() {
  local source="$1"
  local identifier="$2"
  local requested_context="$3"
  local configured_context="$4"
  local catalog_key="$5"
  local runtime_report="$6"
  local instance_count actual_id actual_context required_context compatibility_status runtime_id_count
  compatibility_status=0

  instance_count="$(printf '%s\n' "$runtime_report" | awk -F '\t' -v key="$source" '$1=="INSTANCE" && $2==key {count++} END {print count+0}')"
  if [[ "$instance_count" -ne 1 ]]; then
    warn "load succeeded, but runtime compatibility is unverified: expected one exact loaded instance for $source, found $instance_count"
    [[ -n "$catalog_key" ]] || print_partial_model_fragment "" ""
    return 0
  fi
  actual_id="$(printf '%s\n' "$runtime_report" | awk -F '\t' -v key="$source" '$1=="INSTANCE" && $2==key {print $3; exit}')"
  actual_context="$(printf '%s\n' "$runtime_report" | awk -F '\t' -v key="$source" '$1=="INSTANCE" && $2==key {print $4; exit}')"
  runtime_id_count="$(printf '%s\n' "$runtime_report" | awk -F '\t' -v id="$actual_id" '$1=="INSTANCE" && $3==id {count++} END {print count+0}')"
  if [[ "$runtime_id_count" -gt 1 ]]; then
    warn "load succeeded, but loaded runtime ID $actual_id is associated with multiple model keys"
    [[ -n "$catalog_key" ]] || print_partial_model_fragment "" ""
    return 1
  fi
  if [[ "$actual_id" != "$identifier" ]]; then
    warn "load succeeded, but runtime served ID $actual_id differs from requested ID $identifier"
    compatibility_status=1
  elif [[ -z "$actual_context" ]]; then
    warn "load succeeded, but actual runtime context is unverified"
  else
    required_context="$requested_context"
    if [[ -n "$configured_context" && "$configured_context" -gt "$required_context" ]]; then
      required_context="$configured_context"
    fi
    if [[ "$actual_context" -lt "$required_context" ]]; then
      warn "load succeeded, but actual context $actual_context is below required OpenCode/requested context $required_context"
      compatibility_status=1
    elif [[ -n "$configured_context" ]]; then
      info "runtime compatibility verified for $catalog_key (actual context $actual_context)"
    else
      warn "actual runtime context $actual_context is verified, but OpenCode compatibility is unverified without a configured context"
    fi
  fi
  if [[ -z "$catalog_key" ]]; then
    print_partial_model_fragment "$actual_id" "$actual_context"
  fi
  return "$compatibility_status"
}

resolve_model() {
  local selection="$1"
  local installed="$2"
  local report="$3"
  LOCAL_MODELS_SELECTION="$selection" LOCAL_MODELS_INSTALLED="$installed" LOCAL_MODELS_CONFIG_REPORT="$report" python_json_helper <<'PY'
import os
import sys

selection = os.environ.get("LOCAL_MODELS_SELECTION", "")
installed = [line for line in os.environ.get("LOCAL_MODELS_INSTALLED", "").splitlines() if line]
report = os.environ.get("LOCAL_MODELS_CONFIG_REPORT", "")
models = []
for line in report.splitlines():
    fields = line.split("\t")
    if fields[0] == "MODEL" and len(fields) == 5:
        models.append({"key": fields[1], "id": fields[2], "context": fields[3]})

def fail(message):
    print("ERROR\t" + message)
    sys.exit(0)

if not selection:
    fail("model selection is required")

catalog = [model for model in models if model["key"] == selection]
if catalog:
    if len(catalog) != 1:
        fail("ambiguous OpenCode catalog key: " + selection)
    chosen = catalog[0]
    source_matches = [key for key in installed if key == chosen["id"]]
    if len(source_matches) != 1:
        if not source_matches:
            fail("catalog modelID has no exact installed LM Studio model key: " + chosen["id"])
        fail("ambiguous installed model key: " + chosen["id"])
    id_matches = [model for model in models if model["id"] == chosen["id"]]
    if len(id_matches) != 1:
        fail("ambiguous configured modelID: " + chosen["id"])
    print("SOURCE\t" + source_matches[0])
    print("IDENTIFIER\t" + chosen["id"])
    print("CONTEXT\t" + chosen["context"])
    print("CATALOG\t" + chosen["key"])
    sys.exit(0)

source_matches = [key for key in installed if key == selection]
if len(source_matches) != 1:
    if not source_matches:
        fail("model key is not installed: " + selection)
    fail("ambiguous installed model key: " + selection)

id_matches = [model for model in models if model["id"] == selection]
if len(id_matches) > 1:
    fail("ambiguous configured modelID: " + selection)
if id_matches:
    chosen = id_matches[0]
    print("SOURCE\t" + source_matches[0])
    print("IDENTIFIER\t" + chosen["id"])
    print("CONTEXT\t" + chosen["context"])
    print("CATALOG\t" + chosen["key"])
else:
    print("SOURCE\t" + source_matches[0])
    print("IDENTIFIER\t" + source_matches[0])
    print("CONTEXT\t")
    print("CATALOG\t")
PY
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
  local installed source
  installed="$(installed_sources)" || exit $?
  printf '%s\n' "LM Studio non-embedding model keys:"
  if [[ -z "$installed" ]]; then
    printf '%s\n' "  none"
    return 0
  fi
  while IFS= read -r source; do
    [[ -n "$source" ]] && printf '  %s\n' "$source"
  done <<EOF
$installed
EOF
}

cmd_verify() {
  require_runtime_deps
  local config_report runtime_report status running
  if [[ -f "$OPENCODE_CONFIG" ]]; then
    validate_config
    config_report="$(jsonc_config_report)"
  else
    config_report=""
    warn "OpenCode config is missing; compatibility cannot be established"
  fi
  status="$(server_status_report)" || exit $?
  running="$(printf '%s\n' "$status" | status_field RUNNING)"
  printf 'server_running: %s\n' "$running"
  if [[ "$running" != "yes" ]]; then
    printf '%s\n' "runtime compatibility: unverified (server stopped)"
    return 0
  fi
  if ! status_matches_config "$status"; then
    printf '%s\n' "runtime compatibility: unverified (LM Studio endpoint identity does not match configured endpoint)"
    return 0
  fi
  if runtime_report="$(native_models_report)"; then
    if ! report_compatibility "$config_report" "$runtime_report"; then
      info "read-only verification complete; a known compatibility mismatch was found"
      return 1
    fi
  else
    if ! report_compatibility "$config_report" ""; then
      info "read-only verification complete; a known compatibility mismatch was found"
      return 1
    fi
  fi
  info "read-only verification complete; no model or server was started"
}

cmd_status() {
  require_runtime_deps
  local status running loaded config_status server_host server_port config_report runtime_report
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
  loaded="$(loaded_identifiers)" || exit $?
  if [[ -n "$loaded" ]]; then
    printf 'loaded_runtime_identifiers:\n'
    printf '%s\n' "$loaded" | while IFS= read -r line; do
      [[ -n "$line" ]] && printf '  %s\n' "$line"
    done
  else
    printf 'loaded_runtime_identifiers: none\n'
  fi
  if [[ -f "$OPENCODE_CONFIG" ]] && validate_config >/dev/null 2>&1; then
    config_status="valid"
    config_report="$(jsonc_config_report)"
  elif [[ ! -f "$OPENCODE_CONFIG" ]]; then
    config_status="missing"
    config_report=""
  else
    config_status="drifted"
    config_report=""
  fi
  printf 'opencode_config: %s (%s)\n' "$config_status" "$OPENCODE_CONFIG"
  if [[ "$running" == "yes" ]] && status_matches_config "$status" && runtime_report="$(native_models_report)"; then
    report_compatibility "$config_report" "$runtime_report"
  elif [[ "$running" != "yes" ]]; then
    printf '%s\n' "runtime compatibility: unverified (server stopped)"
  else
    printf '%s\n' "runtime compatibility: unverified (native metadata unavailable or endpoint identity mismatch)"
  fi
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
  local selection=""
  if [[ $# -gt 0 && "$1" != -* ]]; then
    selection="$1"
    shift
  fi

  local context_length ttl yes identifier_override installed config_report resolved native_report
  local native_count source_max instance_count instance_id instance_context loaded association_unknown_count
  local source identifier estimate decision decision_kind answer configured_context catalog_key post_report
  local model_number model_key selection_number
  context_length=""
  ttl=""
  yes=0
  identifier_override=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context-length | -c)
        [[ $# -ge 2 ]] || die_usage "missing value for $1"
        context_length="$2"
        shift 2
        ;;
      --identifier)
        [[ $# -ge 2 && -n "$2" ]] || die_usage "--identifier requires a non-empty value"
        case "$2" in
          *$'\t'* | *$'\n'* | *$'\r'*) die_usage "identifier must not contain tabs or line breaks" ;;
        esac
        identifier_override="$2"
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
  if [[ -n "$ttl" ]]; then
    case "$ttl" in *[!0-9]* | "") die_usage "--ttl must be an integer number of seconds" ;; esac
  fi

  require_runtime_deps
  installed="$(installed_sources)" || exit $?
  if [[ -f "$OPENCODE_CONFIG" ]]; then
    validate_config
    config_report="$(jsonc_config_report)"
  else
    config_report=""
    warn "OpenCode config is missing; loading requires an explicit context and cannot establish OpenCode compatibility"
  fi
  if [[ -z "$selection" ]]; then
    [[ -t 0 ]] || die_usage "load requires a model key; numbered selection is available in a TTY"
    [[ -n "$installed" ]] || die "no installed non-embedding LM Studio models are available to select"
    printf '%s\n' "Choose an installed model:" >&2
    model_number=0
    while IFS= read -r model_key; do
      [[ -n "$model_key" ]] || continue
      model_number=$((model_number + 1))
      printf '  %s) %s\n' "$model_number" "$model_key" >&2
    done <<EOF
$installed
EOF
    printf 'Model number: ' >&2
    read -r selection_number || die "could not read model selection"
    case "$selection_number" in *[!0-9]* | "") die_usage "model selection must be a listed number" ;; esac
    selection="$(printf '%s\n' "$installed" | sed -n "${selection_number}p")"
    [[ -n "$selection" ]] || die_usage "model selection is out of range"
  fi
  case "$selection" in
    *$'\t'* | *$'\n'* | *$'\r'*) die_usage "model key must not contain tabs or line breaks" ;;
  esac
  resolved="$(resolve_model "$selection" "$installed" "$config_report")"
  if printf '%s\n' "$resolved" | grep -q '^ERROR[[:space:]]'; then
    die_usage "$(printf '%s\n' "$resolved" | awk -F '\t' '$1=="ERROR" {print $2; exit}')"
  fi
  source="$(printf '%s\n' "$resolved" | awk -F '\t' '$1=="SOURCE" {print $2; exit}')"
  identifier="$(printf '%s\n' "$resolved" | awk -F '\t' '$1=="IDENTIFIER" {print $2; exit}')"
  configured_context="$(printf '%s\n' "$resolved" | awk -F '\t' '$1=="CONTEXT" {print $2; exit}')"
  catalog_key="$(printf '%s\n' "$resolved" | awk -F '\t' '$1=="CATALOG" {print $2; exit}')"
  if [[ -z "$context_length" ]]; then
    context_length="$configured_context"
  fi
  [[ -n "$source" && -n "$identifier" ]] || die "could not resolve selected LM Studio model"
  if [[ -n "$identifier_override" ]]; then
    identifier="$identifier_override"
  fi
  if [[ -z "$context_length" ]]; then
    if [[ -t 0 ]]; then
      printf 'No configured context for %s. Context length: ' "$selection" >&2
      read -r context_length || die "could not read context length"
    else
      die_usage "no configured context for $selection; pass --context-length N"
    fi
  fi
  case "$context_length" in *[!0-9]* | "") die_usage "--context-length must be an integer (found: ${context_length:-<empty>})" ;; esac
  [[ "$context_length" -gt 0 ]] || die_usage "--context-length must be greater than zero"
  if [[ -n "$configured_context" && "$context_length" -lt "$configured_context" ]]; then
    die "requested context $context_length is below configured OpenCode context $configured_context; refusing to create an incompatible load"
  fi
  case "$LOW_CONTEXT_THRESHOLD" in
    *[!0-9]* | "") ;;
    *)
      if [[ "$LOW_CONTEXT_THRESHOLD" -gt 0 && "$context_length" -lt "$LOW_CONTEXT_THRESHOLD" ]]; then
        warn "context $context_length is below advisory threshold $LOW_CONTEXT_THRESHOLD; this is not a load restriction"
      fi
      ;;
  esac

  cmd_start
  if native_report="$(native_models_report)"; then
    native_count="$(printf '%s\n' "$native_report" | awk -F '\t' -v key="$source" '$1=="MODEL" && $2==key {count++} END {print count+0}')"
    [[ "$native_count" -le 1 ]] || die "ambiguous LM Studio runtime metadata for exact model key $source"
    source_max="$(printf '%s\n' "$native_report" | awk -F '\t' -v key="$source" '$1=="MODEL" && $2==key {print $3; exit}')"
    if [[ "$native_count" -eq 0 ]]; then
      warn "no exact native runtime record for $source; maximum and loaded-instance association are unverified"
    elif [[ -z "$source_max" ]]; then
      warn "LM Studio did not report a maximum context for $source; load compatibility is unverified"
    fi
    if [[ -n "$source_max" && "$context_length" -gt "$source_max" ]]; then
      die "requested context $context_length exceeds LM Studio maximum context $source_max for $source"
    fi
    association_unknown_count="$(printf '%s\n' "$native_report" | awk -F '\t' -v key="$source" '$1=="ASSOCIATION_UNKNOWN" && $2==key {count++} END {print count+0}')"
    [[ "$association_unknown_count" -eq 0 ]] || die "loaded-instance association for $source is unverified; refusing to risk a duplicate load"
    instance_count="$(printf '%s\n' "$native_report" | awk -F '\t' -v key="$source" '$1=="INSTANCE" && $2==key {count++} END {print count+0}')"
    [[ "$instance_count" -le 1 ]] || die "ambiguous loaded instances for exact LM Studio model key $source; refusing to guess"
    if [[ "$instance_count" -eq 1 ]]; then
      instance_id="$(printf '%s\n' "$native_report" | awk -F '\t' -v key="$source" '$1=="INSTANCE" && $2==key {print $3; exit}')"
      instance_context="$(printf '%s\n' "$native_report" | awk -F '\t' -v key="$source" '$1=="INSTANCE" && $2==key {print $4; exit}')"
      runtime_id_count="$(printf '%s\n' "$native_report" | awk -F '\t' -v id="$instance_id" '$1=="INSTANCE" && $3==id {count++} END {print count+0}')"
      [[ "$runtime_id_count" -eq 1 ]] || die "ambiguous loaded runtime ID $instance_id across model-key associations; refusing to guess"
      [[ "$instance_id" == "$identifier" ]] || die "loaded instance for $source uses ID $instance_id, expected $identifier; refusing to reload or unload it automatically"
      [[ -n "$instance_context" ]] || die "loaded instance $instance_id has unverified context; refusing to reload it"
      [[ "$instance_context" -ge "$context_length" ]] || die "loaded instance $instance_id context $instance_context is below requested context $context_length; unload and reload manually"
      if [[ -n "$configured_context" && "$instance_context" -lt "$configured_context" ]]; then
        die "loaded instance $instance_id context $instance_context is below configured context $configured_context; unload and reload manually"
      fi
      info "reusing loaded instance $instance_id with runtime context $instance_context"
      report_loaded_result "$source" "$identifier" "$context_length" "$configured_context" "$catalog_key" "$native_report" || return $?
      return 0
    fi
  else
    warn "LM Studio native model metadata is unavailable; maximum and runtime context are unverified"
  fi
  loaded="$(loaded_identifiers)" || exit $?
  if printf '%s\n' "$loaded" | contains_line "$identifier"; then
    die "identifier $identifier is already loaded but has no unambiguous exact model-key/runtime-context association; refusing to reload"
  fi

  if ! estimate="$({ "$LMS_BIN" load "$source" --identifier "$identifier" --context-length "$context_length" --estimate-only; } 2>&1)"; then
    die_upstream "lms load estimate failed for $selection: $estimate"
  fi
  printf '%s\n' "$estimate" >&2
  decision="$(printf '%s\n' "$estimate" | estimate_decision)"
  decision_kind="$(printf '%s\n' "$decision" | awk 'NR==1 {print $1}')"
  if [[ "$decision_kind" != "auto" && "$yes" != "1" ]]; then
    if [[ ! -t 0 ]]; then
      die "estimate for $selection requires confirmation; rerun interactively or pass --yes to override"
    fi
    printf 'Estimate for %s requires confirmation. Load %s as %s? [y/N] ' "$source" "$source" "$identifier" >&2
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
    die_upstream "lms load failed for $source ($identifier)"
  fi
  info "loaded $source as $identifier"
  if post_report="$(native_models_report)"; then
    report_loaded_result "$source" "$identifier" "$context_length" "$configured_context" "$catalog_key" "$post_report" || return $?
  else
    warn "load succeeded, but runtime identity/context could not be verified"
    [[ -n "$catalog_key" ]] || print_partial_model_fragment "" ""
  fi
}

cmd_unload() {
  [[ $# -ge 1 ]] || die_usage "unload requires an alias or --all-local"
  require_runtime_deps
  local target id loaded unload_rc exact_count runtime_report matches match_count runtime_id_count
  target="$1"
  shift
  [[ $# -eq 0 ]] || die_usage "unload accepts exactly one target"
  case "$target" in
    --all-local)
      loaded="$(loaded_identifiers)" || exit $?
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
      loaded="$(loaded_identifiers)" || exit $?
      exact_count="$(printf '%s\n' "$loaded" | awk -v id="$target" '$0==id {count++} END {print count+0}')"
      if [[ "$exact_count" -gt 1 ]]; then
        die "ambiguous duplicate loaded identifier $target; refusing to unload"
      elif [[ "$exact_count" -eq 1 ]]; then
        id="$target"
      else
        if ! runtime_report="$(native_models_report)"; then
          die "no exact loaded identifier or verified model-key association for $target"
        fi
        matches="$(printf '%s\n' "$runtime_report" | awk -F '\t' -v target="$target" '$1=="INSTANCE" && ($2==target || $3==target) {print $3}')"
        match_count="$(printf '%s\n' "$matches" | awk 'NF {count++} END {print count+0}')"
        [[ "$match_count" -eq 1 ]] || die "no unique exact loaded runtime ID associated with $target"
        id="$matches"
        runtime_id_count="$(printf '%s\n' "$runtime_report" | awk -F '\t' -v id="$id" '$1=="INSTANCE" && $3==id {count++} END {print count+0}')"
        [[ "$runtime_id_count" -eq 1 ]] || die "ambiguous loaded runtime ID $id across model-key associations"
      fi
      if ! "$LMS_BIN" unload "$id"; then
        die_upstream "lms unload failed for exact runtime ID $id"
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
