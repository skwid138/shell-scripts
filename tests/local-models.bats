#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# CLI tests for personal/local-models.sh.
# External LM Studio state is fully stubbed via LOCAL_MODELS_* overrides.

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

  write_valid_config
  write_lms_stub
  write_curl_stub_success
}

teardown() {
  [[ -d "$STUBDIR" ]] && rm -rf "$STUBDIR"
}

write_valid_config() {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  // JSONC comments and trailing commas are intentional test coverage.
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": {
        "baseURL": "http://127.0.0.1:1234/v1" // comment after string URL
      },
      "models": {
        "local/ministral-3b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3-vl-8b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3-vl-30b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3-coder-next": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": 32768, "output": 8192 } },
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } },
      },
    },
  },
}
EOF
}

write_drifted_config() {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/ministral-3b": { "limit": { "context": 32768, "output": 8192 } }
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
    if [[ -f "$(dirname "$0")/lms-started" ]]; then
      running=true
    fi
    printf '{"running":%s,"port":%s,"host":"%s"}\n' "$running" "${LMS_STATUS_PORT:-1234}" "${LMS_STATUS_HOST:-127.0.0.1}"
    ;;
  "server start")
    touch "$(dirname "$0")/lms-started"
    exit "${LMS_START_EXIT:-0}"
    ;;
  "ls --json")
    cat <<'JSON'
[{"type":"llm","modelKey":"mistralai/ministral-3-3b"},{"type":"llm","modelKey":"qwen/qwen3-vl-8b"},{"type":"llm","modelKey":"qwen/qwen3-vl-30b"},{"type":"llm","modelKey":"qwen3-coder-next-0"},{"type":"llm","modelKey":"qwen_qwen3.5-122b-a10b"},{"type":"llm","modelKey":"gpt-oss-120b"},{"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5"}]
JSON
    ;;
  "ps --json")
    if [[ -n "${LMS_PS_JSON:-}" ]]; then
      printf '%s\n' "$LMS_PS_JSON"
    else
      cat <<'JSON'
[{"identifier":"local/ministral-3b"},{"identifier":"not-local"}]
JSON
    fi
    ;;
  "load mistralai/ministral-3-3b")
    if [[ "$*" == *"--estimate-only"* ]]; then
      cat <<'ESTIMATE'
Estimated Total Memory: 4.96 GiB
Confidence: HIGH
Estimate: This model may be loaded based on your resource guardrails settings.
ESTIMATE
    else
      exit "${LMS_LOAD_EXIT:-0}"
    fi
    ;;
  "load qwen/qwen3-vl-8b")
    if [[ "$*" == *"--estimate-only"* ]]; then
      cat <<'ESTIMATE'
Estimated Total Memory: 24 GiB
Confidence: LOW
Estimate: This model may not fit within your resource guardrails.
ESTIMATE
    else
      exit "${LMS_LOAD_EXIT:-0}"
    fi
    ;;
  unload*)
    exit "${LMS_UNLOAD_EXIT:-0}"
    ;;
  *)
    echo "unexpected lms args: $*" >&2
    exit 99
    ;;
esac
EOF
  chmod +x "$LOCAL_MODELS_LMS_BIN"
}

write_curl_stub_success() {
  cat >"$LOCAL_MODELS_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$STATEFILE"
printf '{"data":[{"id":"local/ministral-3b"}]}\n'
EOF
  chmod +x "$LOCAL_MODELS_CURL_BIN"
}

write_curl_stub_fail_then_success() {
  cat >"$LOCAL_MODELS_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$STATEFILE"
count_file="$(dirname "$0")/curl-count"
count=$(cat "$count_file" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" >"$count_file"
if [[ "$count" -eq 1 ]]; then
  exit 7
fi
printf '{"data":[]}\n'
EOF
  chmod +x "$LOCAL_MODELS_CURL_BIN"
}

@test "local-models: --help exits 0 and prints usage" {
  run "$SCRIPT" --help
  assert_success
  assert_output --partial "Usage: local-models"
  assert_output --partial "load <alias>"
}

@test "local-models: list shows aliases with installed and loaded status" {
  run "$SCRIPT" list
  assert_success
  assert_output --partial "ministral-3b"
  assert_output --partial "mistralai/ministral-3-3b"
  assert_output --partial "local/ministral-3b"
  assert_output --partial "installed=yes"
  assert_output --partial "loaded=yes"
}

@test "local-models: start starts pinned server when endpoint is down" {
  write_curl_stub_fail_then_success
  LMS_RUNNING=false run "$SCRIPT" start
  assert_success
  grep -qE '^lms server start --bind 127\.0\.0\.1 --port 1234$' "$STATEFILE"
  assert_output --partial "LM Studio server ready"
}

@test "local-models: start refuses responding endpoint when LM Studio status is elsewhere" {
  LMS_STATUS_PORT=5678 run "$SCRIPT" start
  assert_failure 5
  assert_output --partial "responds, but LM Studio CLI status does not match configured http://127.0.0.1:1234/v1"
  assert_output --partial "expected host=127.0.0.1 port=1234"
  if grep -qE '^lms server start ' "$STATEFILE"; then
    echo "server start ran despite endpoint/status mismatch" >&2
    return 1
  fi
}

@test "local-models: verify accepts JSONC comments, block comments, strings, and trailing commas" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  /* block comment */
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/ministral-3b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3-vl-8b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3-vl-30b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3-coder-next": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": 32768, "output": 8192 } },
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } },
      }
    }
  },
  "note": "not // a comment and not /* a block */",
}
EOF
  run "$SCRIPT" verify
  assert_success
  assert_output --partial "verification passed"
}

@test "local-models: verify fails on OpenCode config drift" {
  write_drifted_config
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial "OpenCode lmstudio model keys do not match"
  assert_output --partial "local/qwen3-vl-8b"
}

@test "local-models: load passes stable identifier and context length" {
  run "$SCRIPT" load ministral-3b --context-length 4096 --ttl 60 --yes
  assert_success
  grep -qE '^lms load mistralai/ministral-3-3b --identifier local/ministral-3b --context-length 4096 --ttl 60 --yes$' "$STATEFILE"
}

@test "local-models: load fails non-interactively when estimate needs prompt" {
  run "$SCRIPT" load qwen3-vl-8b
  assert_failure 1
  assert_output --partial "requires confirmation"
  if grep -qE '^lms load qwen/qwen3-vl-8b --identifier local/qwen3-vl-8b --context-length 32768$' "$STATEFILE"; then
    echo "load ran despite required prompt" >&2
    return 1
  fi
}

@test "local-models: unload alias unloads exact stable identifier only" {
  run "$SCRIPT" unload ministral-3b
  assert_success
  grep -qE '^lms unload local/ministral-3b$' "$STATEFILE"
}

@test "local-models: unload --all-local unloads only identifiers beginning local/" {
  LMS_PS_JSON='[{"identifier":"local/ministral-3b"},{"identifier":"not-local"},{"identifier":"local/qwen3-vl-8b"}]' run "$SCRIPT" unload --all-local
  assert_success
  grep -qE '^lms unload local/ministral-3b$' "$STATEFILE"
  grep -qE '^lms unload local/qwen3-vl-8b$' "$STATEFILE"
  if grep -qE '^lms unload not-local$|^lms unload --all' "$STATEFILE"; then
    echo "unsafe unload detected" >&2
    return 1
  fi
}

@test "local-models: unload --all-local propagates exact-id unload failures" {
  LMS_PS_JSON='[{"identifier":"local/ministral-3b"}]' LMS_UNLOAD_EXIT=5 run "$SCRIPT" unload --all-local
  assert_failure 5
  assert_output --partial "one or more local model unloads failed"
}

@test "local-models: runs cleanly under /bin/bash 3.2" {
  run /bin/bash "$SCRIPT" list
  assert_success
  assert_output --partial "ministral-3b"
}
