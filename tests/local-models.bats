#!/usr/bin/env bats
bats_require_minimum_version 1.5.0

# CLI tests for personal/local-models.sh. LM Studio, curl, and OpenCode config
# are stubbed; no test loads a real model or calls inference.

setup() {
  load 'test_helper/bats-support/load'
  load 'test_helper/bats-assert/load'

  SCRIPT="$BATS_TEST_DIRNAME/../personal/local-models.sh"
  STUBDIR="$(mktemp -d)"
  STATEFILE="$STUBDIR/calls.log"
  : >"$STATEFILE"
  export PATH="$STUBDIR:$PATH"
  export STATEFILE

  export LOCAL_MODELS_LMS_BIN="$STUBDIR/lms"
  export LOCAL_MODELS_CURL_BIN="$STUBDIR/curl"
  export LOCAL_MODELS_OPENCODE_CONFIG="$STUBDIR/opencode.jsonc"
  export LOCAL_MODELS_BASE_URL="http://127.0.0.1:1234/v1"
  export LOCAL_MODELS_START_WAIT_ATTEMPTS=1
  export LOCAL_MODELS_START_WAIT_SLEEP=0

  write_model_config "local/catalog-name" "org/model-z" 8192
  write_lms_stub
  write_curl_stub
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_model_config() {
  local catalog_key="$1"
  local model_id="$2"
  local context="${3:-}"
  local limit_field=""
  if [[ -n "$context" ]]; then
    limit_field="\"limit\": { \"context\": $context, \"output\": 4096 },"
  fi
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<EOF
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "$catalog_key": {
          "modelID": "$model_id",
          $limit_field
          "body": { "temperature": 1 }
        }
      }
    }
  }
}
EOF
}

write_lms_stub() {
  cat >"$LOCAL_MODELS_LMS_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'lms %s\n' "$*" >>"$STATEFILE"
case "$1 ${2-}" in
  "server status")
    running="${LMS_RUNNING:-true}"
    if [[ -f "$(dirname "$0")/server-started" ]]; then running=true; fi
    printf '{"running":%s,"port":%s,"host":"%s"}\n' \
      "$running" "${LMS_STATUS_PORT:-1234}" "${LMS_STATUS_HOST:-127.0.0.1}"
    ;;
  "server start")
    touch "$(dirname "$0")/server-started"
    exit "${LMS_START_EXIT:-0}"
    ;;
  "ls --json")
    if [[ "${LMS_LS_EXIT:-0}" -ne 0 ]]; then
      echo "synthetic lms ls failure" >&2
      exit "$LMS_LS_EXIT"
    fi
    if [[ -n "${LMS_LS_JSON:-}" ]]; then
      printf '%s\n' "$LMS_LS_JSON"
    else
      printf '[{"type":"llm","modelKey":"org/model-z"},{"type":"embedding","modelKey":"org/embed"}]\n'
    fi
    ;;
  "ps --json")
    if [[ "${LMS_PS_EXIT:-0}" -ne 0 ]]; then
      echo "synthetic lms ps failure" >&2
      exit "$LMS_PS_EXIT"
    fi
    printf '%s\n' "${LMS_PS_JSON:-[]}"
    ;;
  "load "*)
    if [[ "$*" == *"--estimate-only"* ]]; then
      if [[ -n "${LMS_ESTIMATE_OUTPUT:-}" ]]; then
        printf '%s\n' "$LMS_ESTIMATE_OUTPUT"
      else
        printf 'Estimated Total Memory: 4 GiB\nConfidence: HIGH\nEstimate: This model may be loaded.\n'
      fi
    else
      touch "$(dirname "$0")/model-loaded"
      exit "${LMS_LOAD_EXIT:-0}"
    fi
    ;;
  unload*) exit "${LMS_UNLOAD_EXIT:-0}" ;;
  *) echo "unexpected lms args: $*" >&2; exit 99 ;;
esac
EOF
  chmod +x "$LOCAL_MODELS_LMS_BIN"
}

write_curl_stub() {
  cat >"$LOCAL_MODELS_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$STATEFILE"
if [[ "$*" == *"/api/v1/models"* ]]; then
  if [[ "${LMS_NATIVE_MODELS_FAIL:-0}" == "1" ]]; then
    exit 7
  fi
  if [[ -f "$(dirname "$0")/model-loaded" && -n "${LMS_NATIVE_MODELS_AFTER_LOAD_JSON:-}" ]]; then
    printf '%s\n' "$LMS_NATIVE_MODELS_AFTER_LOAD_JSON"
  elif [[ -n "${LMS_NATIVE_MODELS_JSON:-}" ]]; then
    printf '%s\n' "$LMS_NATIVE_MODELS_JSON"
  else
    printf '{"models":[]}\n'
  fi
else
  if [[ "${CURL_FAIL_UNTIL_START:-0}" == "1" && ! -f "$(dirname "$0")/server-started" ]]; then
    exit 7
  fi
  printf '{"data":[]}\n'
fi
EOF
  chmod +x "$LOCAL_MODELS_CURL_BIN"
}

@test "help describes dynamic model keys rather than a fixed alias roster" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial 'load [model-key|catalog-key]'
  refute_output --partial 'Aliases:'
  refute_output --partial 'qwen3.8-27b'
}

@test "list discovers arbitrary model keys and retains decision models but filters embeddings" {
  LMS_LS_JSON='[{"type":"llm","modelKey":"org/model-z"},{"type":"decision","modelKey":"org/decision-q"},{"type":"llm","path":"org/guessed-path"},{"type":"embedding","modelKey":"org/embed"}]' \
    run "$SCRIPT" list
  assert_success
  assert_output --partial 'org/model-z'
  assert_output --partial 'org/decision-q'
  refute_output --partial 'org/embed'
  refute_output --partial 'org/guessed-path'
  if grep -q '^lms server start ' "$STATEFILE"; then
    echo "list started LM Studio" >&2
    return 1
  fi
}

@test "list is read-only and works under macOS bash 3.2" {
  run /bin/bash "$SCRIPT" list
  assert_success
  assert_output --partial 'org/model-z'
  if grep -q '^lms server start ' "$STATEFILE" || grep -q '^curl ' "$STATEFILE"; then
    echo "list queried or started an HTTP endpoint" >&2
    return 1
  fi
}

@test "load resolves friendly catalog keys through exact modelID and uses configured context" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[]}]}' \
    LMS_NATIVE_MODELS_AFTER_LOAD_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":8192}}]}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_success
  grep -qxF 'lms load org/model-z --identifier org/model-z --context-length 8192 --estimate-only' "$STATEFILE"
  grep -qxF 'lms load org/model-z --identifier org/model-z --context-length 8192' "$STATEFILE"
  assert_output --partial 'runtime compatibility verified for local/catalog-name'
}

@test "unconfigured load defaults to the exact source key and requires explicit context" {
  rm "$LOCAL_MODELS_OPENCODE_CONFIG"
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":8192,"loaded_instances":[]}]}' \
    LMS_NATIVE_MODELS_AFTER_LOAD_JSON='{"models":[{"key":"org/model-z","max_context_length":8192,"loaded_instances":[{"id":"org/model-z","config":{"context_length":4096}}]}]}' \
    run "$SCRIPT" load org/model-z --context-length 4096 --yes
  assert_success
  grep -qxF 'lms load org/model-z --identifier org/model-z --context-length 4096 --yes' "$STATEFILE"
  assert_output --partial '"status": "PARTIAL_REVIEW_REQUIRED"'
  assert_output --partial '"modelID": "org/model-z"'
  assert_output --partial '"context": 4096'
  refute_output --partial '"output"'
  refute_output --partial '"capabilities"'
  refute_output --partial '"name"'
  assert_output --partial 'OpenCode custom-model defaults include 200000 context and 32000 output'
}

@test "unconfigured load without a context fails before server or model side effects" {
  rm "$LOCAL_MODELS_OPENCODE_CONFIG"
  run "$SCRIPT" load org/model-z
  assert_failure 2
  assert_output --partial 'pass --context-length N'
  if grep -q '^lms server start\|^lms load ' "$STATEFILE"; then
    echo "load without a context caused a side effect" >&2
    return 1
  fi
}

@test "a catalog model without usable context requires an explicit context" {
  write_model_config "local/catalog-name" "org/model-z"
  run "$SCRIPT" load local/catalog-name
  assert_failure 2
  assert_output --partial 'no configured context for local/catalog-name'
  if grep -q '^lms server start\|^lms load ' "$STATEFILE"; then
    echo "load without configured or explicit context caused a side effect" >&2
    return 1
  fi
}

@test "load allows an explicit identifier override" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[]}]}' \
    LMS_NATIVE_MODELS_AFTER_LOAD_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"custom/served-id","config":{"context_length":8192}}]}]}' \
    run "$SCRIPT" load local/catalog-name --identifier custom/served-id
  assert_success
  grep -qxF 'lms load org/model-z --identifier custom/served-id --context-length 8192 --estimate-only' "$STATEFILE"
  grep -qxF 'lms load org/model-z --identifier custom/served-id --context-length 8192' "$STATEFILE"
}

@test "load rejects control characters in an explicit identifier before runtime calls" {
  run "$SCRIPT" load local/catalog-name --identifier $'custom/id\ninjected'
  assert_failure 2
  assert_output --partial 'identifier must not contain tabs or line breaks'
  [ ! -s "$STATEFILE" ]
}

@test "duplicate configured modelIDs are rejected without loading" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/catalog-one": { "modelID": "org/model-z", "limit": { "context": 8192 } },
        "local/catalog-two": { "modelID": "org/model-z", "limit": { "context": 8192 } }
      }
    }
  }
}
EOF
  run "$SCRIPT" load local/catalog-one
  assert_failure 2
  assert_output --partial 'ambiguous configured modelID: org/model-z'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "ambiguous configured ID reached load" >&2
    return 1
  fi
}

@test "duplicate installed source keys are rejected without guessing" {
  LMS_LS_JSON='[{"type":"llm","modelKey":"org/model-z"},{"type":"llm","modelKey":"org/model-z"}]' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 2
  assert_output --partial 'ambiguous installed model key: org/model-z'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "duplicate installed key reached load" >&2
    return 1
  fi
}

@test "load refuses a context above LM Studio's reported maximum before estimating" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":4096,"loaded_instances":[]}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 1
  assert_output --partial 'exceeds LM Studio maximum context 4096'
  if grep -q '^lms load org/model-z ' "$STATEFILE"; then
    echo "load estimate or load ran above reported maximum" >&2
    return 1
  fi
}

@test "low context threshold is advisory and does not block a load" {
  write_model_config "local/catalog-name" "org/model-z" 4096
  LOCAL_MODELS_LOW_CONTEXT_THRESHOLD=65536 \
    LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":8192,"loaded_instances":[]}]}' \
    run "$SCRIPT" load local/catalog-name --yes
  assert_success
  assert_output --partial 'below advisory threshold 65536; this is not a load restriction'
  grep -q '^lms load org/model-z --identifier org/model-z --context-length 4096 --yes$' "$STATEFILE"
}

@test "load reuses a compatible exact loaded instance without estimating or reloading" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":16384}}]}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_success
  assert_output --partial 'reusing loaded instance org/model-z with runtime context 16384'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "compatible loaded instance was loaded a second time" >&2
    return 1
  fi
}

@test "load refuses an existing loaded instance below configured context without repairing it" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":4096}}]}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 1
  assert_output --partial 'below requested context 8192'
  refute_output --partial 'lms unload'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "incompatible existing instance was automatically reloaded" >&2
    return 1
  fi
}

@test "load refuses an existing legacy ID mismatch instead of silently reloading" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"local/catalog-name","config":{"context_length":8192}}]}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 1
  assert_output --partial 'uses ID local/catalog-name, expected org/model-z'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "legacy ID mismatch reached load" >&2
    return 1
  fi
}

@test "load rejects duplicate loaded runtime IDs across model-key associations" {
  LMS_LS_JSON='[{"type":"llm","modelKey":"org/model-z"},{"type":"llm","modelKey":"org/other"}]' \
    LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":8192}}]},{"key":"org/other","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":8192}}]}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 1
  assert_output --partial 'ambiguous loaded runtime ID org/model-z'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "duplicate runtime ID reached load" >&2
    return 1
  fi
}

@test "load refuses to risk duplicate loading when loaded-instance association is missing" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384}]}' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 1
  assert_output --partial 'loaded-instance association for org/model-z is unverified'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "load proceeded without a loaded-instance association" >&2
    return 1
  fi
}

@test "a successful load with a smaller actual context is not reported compatible" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[]}]}' \
    LMS_NATIVE_MODELS_AFTER_LOAD_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":4096}}]}]}' \
    run "$SCRIPT" load local/catalog-name --yes
  assert_failure 1
  assert_output --partial 'load succeeded, but actual context 4096 is below required OpenCode/requested context 8192'
  grep -q '^lms load org/model-z --identifier org/model-z --context-length 8192 --yes$' "$STATEFILE"
  refute_output --partial 'runtime compatibility verified'
}

@test "verify is read-only and reports unknown compatibility when the server is stopped" {
  LMS_RUNNING=false CURL_FAIL_UNTIL_START=1 run "$SCRIPT" verify
  assert_success
  assert_output --partial 'runtime compatibility: unverified (server stopped)'
  if grep -q '^lms server start\|^curl ' "$STATEFILE"; then
    echo "read-only verify started the server or queried its HTTP endpoint" >&2
    return 1
  fi
}

@test "verify returns nonzero for exact loaded context below OpenCode's configured context" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":4096}}]}]}' \
    run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial 'runtime compatibility local/catalog-name: incompatible (actual context 4096 is below configured 8192)'
  if grep -q '^lms server start ' "$STATEFILE"; then
    echo "verify started LM Studio" >&2
    return 1
  fi
}

@test "verify returns zero when actual context meets or exceeds configured context" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"org/model-z","config":{"context_length":16384}}]}]}' \
    run "$SCRIPT" verify
  assert_success
  assert_output --partial 'runtime compatibility local/catalog-name: compatible (actual context 16384)'
  if grep -q '^lms server start ' "$STATEFILE"; then
    echo "verify started LM Studio" >&2
    return 1
  fi
}

@test "verify returns nonzero for exact modelID association mismatch" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[{"id":"legacy/id","config":{"context_length":8192}}]}]}' \
    run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial 'runtime compatibility local/catalog-name: incompatible (loaded ID legacy/id, configured modelID org/model-z)'
  if grep -q '^lms server start\|^lms load\|^lms unload ' "$STATEFILE"; then
    echo "verify started or mutated the runtime after detecting an ID mismatch" >&2
    return 1
  fi
}

@test "verify reports a missing loaded-instance field as unknown rather than unloaded" {
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384}]}' \
    run "$SCRIPT" verify
  assert_success
  assert_output --partial 'runtime compatibility local/catalog-name: unverified (loaded-instance association unavailable)'
  refute_output --partial 'model is not loaded'
}

@test "status reports all runtime IDs and remains read-only" {
  LMS_PS_JSON='[{"identifier":"runtime/model-z"},{"identifier":"local/legacy-model"}]' \
    LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[]}]}' \
    run "$SCRIPT" status
  assert_success
  assert_output --partial 'runtime/model-z'
  assert_output --partial 'local/legacy-model'
  if grep -q '^lms server start ' "$STATEFILE"; then
    echo "status started LM Studio" >&2
    return 1
  fi
}

@test "load refuses a foreign service on the configured endpoint" {
  LMS_STATUS_PORT=5678 run "$SCRIPT" load local/catalog-name
  assert_failure 5
  assert_output --partial 'refusing to treat a random OpenAI-compatible service as LM Studio'
  if grep -q '^lms server start\|^lms load ' "$STATEFILE"; then
    echo "load started or mutated a foreign endpoint" >&2
    return 1
  fi
}

@test "start may start a stopped LM Studio server but does not load a model" {
  LMS_RUNNING=false CURL_FAIL_UNTIL_START=1 run "$SCRIPT" start
  assert_success
  grep -qxF 'lms server start --bind 127.0.0.1 --port 1234' "$STATEFILE"
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "start loaded a model" >&2
    return 1
  fi
}

@test "unfavorable estimate still requires confirmation in noninteractive mode" {
  LMS_ESTIMATE_OUTPUT='Estimated Total Memory: 80 GiB
Confidence: LOW
Estimate: This model may not fit.' \
    run "$SCRIPT" load local/catalog-name
  assert_failure 1
  assert_output --partial 'requires confirmation'
  grep -q '^lms load org/model-z --identifier org/model-z --context-length 8192 --estimate-only$' "$STATEFILE"
  if grep -q '^lms load org/model-z --identifier org/model-z --context-length 8192$' "$STATEFILE"; then
    echo "unconfirmed estimate reached actual load" >&2
    return 1
  fi
}

@test "unload accepts one exact loaded runtime identifier" {
  LMS_PS_JSON='[{"identifier":"runtime/model-z"},{"identifier":"not-local"}]' run "$SCRIPT" unload runtime/model-z
  assert_success
  grep -qxF 'lms unload runtime/model-z' "$STATEFILE"
  [ "$(grep -c '^lms unload ' "$STATEFILE")" -eq 1 ]
}

@test "unload ignores loaded identifiers containing control characters" {
  LMS_PS_JSON='[{"identifier":"runtime/id\ninjected"}]' run "$SCRIPT" unload runtime/id
  assert_failure 1
  assert_output --partial 'no unique exact loaded runtime ID associated with runtime/id'
  if grep -q '^lms unload ' "$STATEFILE"; then
    echo "malformed loaded identifier reached unload" >&2
    return 1
  fi
}

@test "unload resolves model keys only through exact loaded-instance associations" {
  LMS_PS_JSON='[{"identifier":"runtime-id-z"}]' \
    LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","loaded_instances":[{"id":"runtime-id-z","config":{"context_length":8192}}]}]}' \
    run "$SCRIPT" unload org/model-z
  assert_success
  grep -qxF 'lms unload runtime-id-z' "$STATEFILE"
}

@test "legacy --all-local remains limited to identifiers beginning local/" {
  LMS_PS_JSON='[{"identifier":"local/first"},{"identifier":"runtime/model-z"},{"identifier":"local/second"}]' \
    run "$SCRIPT" unload --all-local
  assert_success
  grep -qxF 'lms unload local/first' "$STATEFILE"
  grep -qxF 'lms unload local/second' "$STATEFILE"
  [ "$(grep -c '^lms unload ' "$STATEFILE")" -eq 2 ]
  if grep -q '^lms unload runtime/model-z\|^lms unload --all' "$STATEFILE"; then
    echo "legacy --all-local broadened beyond local/ IDs" >&2
    return 1
  fi
}

@test "native V2 provider accepts JSONC and non-roster model entries" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/one": { "modelID": "org/one", "limit": { "context": 8192, "output": 4096 } },
        "local/two": { "modelID": "org/two" },
      },
    },
  },
}
EOF
  run "$SCRIPT" verify
  assert_success
  assert_output --partial 'runtime compatibility local/one: unverified'
  assert_output --partial 'runtime compatibility local/two: unverified'
}

@test "selected load is not blocked by an unrelated uninstalled catalog model" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/catalog-name": { "modelID": "org/model-z", "limit": { "context": 8192 } },
        "local/unrelated": { "modelID": "org/not-installed", "limit": { "context": 131072 } }
      }
    }
  }
}
EOF
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":16384,"loaded_instances":[]}]}' \
    run "$SCRIPT" load local/catalog-name --yes
  assert_success
  grep -q '^lms load org/model-z --identifier org/model-z --context-length 8192 --yes$' "$STATEFILE"
}

@test "config parser rejects escaped delimiters instead of silently dropping context" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/catalog-name": { "modelID": "org/model-z", "limit": { "context": "8192\n-injected", "output": 4096 } }
      }
    }
  }
}
EOF
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial 'models.limit.context contains a tab, line break, or NUL'
  refute_output --partial '-injected'
  [ ! -s "$STATEFILE" ]
}

@test "partial fragment omits context when runtime context cannot be verified" {
  rm "$LOCAL_MODELS_OPENCODE_CONFIG"
  LMS_NATIVE_MODELS_JSON='{"models":[{"key":"org/model-z","max_context_length":8192,"loaded_instances":[]}]}' \
    LMS_NATIVE_MODELS_AFTER_LOAD_JSON='{"models":[{"key":"org/model-z","max_context_length":8192,"loaded_instances":[{"id":"org/model-z","config":{}}]}]}' \
    run "$SCRIPT" load org/model-z --context-length 4096 --yes
  assert_success
  assert_output --partial '"status": "PARTIAL_REVIEW_REQUIRED"'
  assert_output --partial 'Actual served ID or runtime context is unverified'
  refute_output --partial '"context": 4096'
  refute_output --partial '"output"'
}

@test "legacy provider shape remains supported while invalid adapters fail closed" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/catalog-name": { "modelID": "org/model-z", "limit": { "context": 8192 } },
      },
    },
  },
}
EOF
  run "$SCRIPT" verify
  assert_success
  assert_output --partial 'read-only verification complete'

  sed 's/@ai-sdk\/openai-compatible/unsupported-adapter/' "$LOCAL_MODELS_OPENCODE_CONFIG" >"$STUBDIR/invalid.jsonc"
  mv "$STUBDIR/invalid.jsonc" "$LOCAL_MODELS_OPENCODE_CONFIG"
  : >"$STATEFILE"
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial 'provider.lmstudio.npm must be @ai-sdk/openai-compatible'
  [ ! -s "$STATEFILE" ]
}

@test "load preserves TTL and explicit estimate confirmation flags" {
  run "$SCRIPT" load local/catalog-name --ttl 60 --yes
  assert_success
  grep -qxF 'lms load org/model-z --identifier org/model-z --context-length 8192 --ttl 60 --yes' "$STATEFILE"
}

@test "legacy --all-local reports exact-ID unload failures" {
  LMS_PS_JSON='[{"identifier":"local/first"}]' LMS_UNLOAD_EXIT=5 run "$SCRIPT" unload --all-local
  assert_failure 5
  assert_output --partial 'one or more local model unloads failed'
}

@test "load fails closed when native metadata and lms ps are unavailable" {
  LMS_NATIVE_MODELS_FAIL=1 LMS_PS_EXIT=5 run "$SCRIPT" load local/catalog-name --yes
  assert_failure 5
  assert_output --partial 'lms ps --json failed'
  if grep -q '^lms load ' "$STATEFILE"; then
    echo "load estimate or load ran after lms ps failed" >&2
    return 1
  fi
  if grep -q '^lms unload ' "$STATEFILE"; then
    echo "unload ran after lms ps failed" >&2
    return 1
  fi
}

@test "status fails closed instead of reporting no loaded IDs when lms ps fails" {
  LMS_PS_EXIT=5 run "$SCRIPT" status
  assert_failure 5
  assert_output --partial 'lms ps --json failed'
  refute_output --partial 'loaded_runtime_identifiers: none'
}

@test "unload --all-local fails closed when lms ps fails" {
  LMS_PS_EXIT=5 run "$SCRIPT" unload --all-local
  assert_failure 5
  assert_output --partial 'lms ps --json failed'
  refute_output --partial 'unloaded loaded local/ identifiers'
  if grep -q '^lms unload ' "$STATEFILE"; then
    echo "unload ran after lms ps failed" >&2
    return 1
  fi
}

@test "exact-ID unload fails closed when lms ps fails" {
  LMS_PS_EXIT=5 run "$SCRIPT" unload runtime/model-z
  assert_failure 5
  assert_output --partial 'lms ps --json failed'
  if grep -q '^lms unload ' "$STATEFILE"; then
    echo "exact-ID unload ran after lms ps failed" >&2
    return 1
  fi
}

@test "list fails upstream when lms ls exits unsuccessfully" {
  LMS_LS_EXIT=7 run "$SCRIPT" list
  assert_failure 5
  assert_output --partial 'lms ls --json failed: synthetic lms ls failure'
  refute_output --partial '  none'
}

@test "list rejects malformed lms ls JSON instead of reporting an empty inventory" {
  LMS_LS_JSON='not-json' run "$SCRIPT" list
  assert_failure 5
  assert_output --partial 'could not parse lms ls --json output'
  refute_output --partial '  none'
}

@test "load fails upstream when lms ls exits unsuccessfully before any runtime action" {
  LMS_LS_EXIT=7 run "$SCRIPT" load local/catalog-name --yes
  assert_failure 5
  assert_output --partial 'lms ls --json failed: synthetic lms ls failure'
  if grep -q '^lms server start\|^lms load\|^lms unload ' "$STATEFILE"; then
    echo "runtime action ran after lms ls failed" >&2
    return 1
  fi
}

@test "load rejects malformed lms ls JSON before any runtime action" {
  LMS_LS_JSON='not-json' run "$SCRIPT" load local/catalog-name --yes
  assert_failure 5
  assert_output --partial 'could not parse lms ls --json output'
  refute_output --partial 'model key is not installed'
  if grep -q '^lms server start\|^lms load\|^lms unload ' "$STATEFILE"; then
    echo "runtime action ran after malformed lms ls JSON" >&2
    return 1
  fi
}
