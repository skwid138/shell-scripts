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
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.8-27b": { "limit": { "context": 131072, "output": 8192 } },
        "local/qwen3-coder-next": { "limit": { "context": 32768, "output": 8192 } },
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
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } }
      }
    }
  }
}
EOF
}

# The ls fixture uses LM Studio's plain modelKey values (no @6bit/@8bit
# variant suffix); the script maps aliases to these plain keys.
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
[{"type":"llm","modelKey":"gpt-oss-120b"},{"type":"llm","modelKey":"qwen_qwen3.5-122b-a10b"},{"type":"llm","modelKey":"qwen/qwen3.8-27b"},{"type":"llm","modelKey":"qwen/qwen3-coder-next"},{"type":"embedding","modelKey":"text-embedding-nomic-embed-text-v1.5"}]
JSON
    ;;
  "ps --json")
    if [[ -n "${LMS_PS_JSON:-}" ]]; then
      printf '%s\n' "$LMS_PS_JSON"
    else
      cat <<'JSON'
[{"identifier":"local/gpt-oss-120b"},{"identifier":"not-local"}]
JSON
    fi
    ;;
  "load gpt-oss-120b")
    # Synthetic HIGH/favorable estimate: exercises the auto-load branch.
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
  "load qwen/qwen3.8-27b")
    if [[ "$*" == *"--estimate-only"* ]]; then
      cat <<'ESTIMATE'
Estimated Total Memory: 38.50 GiB
Confidence: LOW
Estimate: This model may not fit within your resource guardrails.
ESTIMATE
    else
      exit "${LMS_LOAD_EXIT:-0}"
    fi
    ;;
  "load qwen/qwen3-coder-next")
    if [[ "$*" == *"--estimate-only"* ]]; then
      cat <<'ESTIMATE'
Estimated Total Memory: 84.44 GiB
Confidence: LOW
Estimate: This model may not fit within your resource guardrails.
ESTIMATE
    else
      exit "${LMS_LOAD_EXIT:-0}"
    fi
    ;;
  "load qwen_qwen3.5-122b-a10b")
    if [[ "$*" == *"--estimate-only"* ]]; then
      cat <<'ESTIMATE'
Estimated Total Memory: 70.00 GiB
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
printf '{"data":[{"id":"local/gpt-oss-120b"}]}\n'
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

@test "local-models: --help alias table lists exactly the four-model roster" {
  run "$SCRIPT" --help
  assert_success
  assert_line --regexp '^  gpt-oss-120b +-> gpt-oss-120b +-> local/gpt-oss-120b$'
  assert_line --regexp '^  qwen3\.5-122b-a10b +-> qwen_qwen3\.5-122b-a10b +-> local/qwen3\.5-122b-a10b$'
  assert_line --regexp '^  qwen3\.8-27b +-> qwen/qwen3\.8-27b +-> local/qwen3\.8-27b$'
  assert_line --regexp '^  qwen3-coder-next +-> qwen/qwen3-coder-next +-> local/qwen3-coder-next$'
  [ "$(printf '%s\n' "$output" | grep -c -- '-> local/')" -eq 4 ]
}

@test "local-models: list shows exactly the four-model roster with status" {
  run "$SCRIPT" list
  assert_success
  assert_line --regexp '^gpt-oss-120b +gpt-oss-120b +local/gpt-oss-120b +installed=yes loaded=yes$'
  assert_line --regexp '^qwen3\.5-122b-a10b +qwen_qwen3\.5-122b-a10b +local/qwen3\.5-122b-a10b +installed=yes loaded=no$'
  assert_line --regexp '^qwen3\.8-27b +qwen/qwen3\.8-27b +local/qwen3\.8-27b +installed=yes loaded=no$'
  assert_line --regexp '^qwen3-coder-next +qwen/qwen3-coder-next +local/qwen3-coder-next +installed=yes loaded=no$'
  # Header plus exactly four roster rows.
  [ "${#lines[@]}" -eq 5 ]
  refute_output --partial "ministral"
  refute_output --partial "qwen3-vl"
  refute_output --partial "qwen3-coder-next-0"
}

@test "local-models: retired aliases are rejected by load and unload" {
  local retired
  for retired in ministral-3b qwen3-vl-8b qwen3-vl-30b; do
    run "$SCRIPT" load "$retired" --yes
    assert_failure 2
    assert_output --partial "unknown local model alias: $retired"
    run "$SCRIPT" unload "$retired"
    assert_failure 2
    assert_output --partial "unknown local model alias: $retired"
  done
  if grep -qE '^lms (load|unload) ' "$STATEFILE"; then
    echo "retired alias reached lms load/unload" >&2
    return 1
  fi
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
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.8-27b": { "limit": { "context": 131072, "output": 8192 } },
        "local/qwen3-coder-next": { "limit": { "context": 32768, "output": 8192 } },
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
  assert_output --partial "local/qwen3.8-27b"
  assert_output --partial "local/qwen3-coder-next"
}

@test "local-models: verify reports a retired model left in OpenCode config as extra" {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<'EOF'
{
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.8-27b": { "limit": { "context": 131072, "output": 8192 } },
        "local/qwen3-coder-next": { "limit": { "context": 32768, "output": 8192 } },
        "local/ministral-3b": { "limit": { "context": 32768, "output": 8192 } }
      }
    }
  }
}
EOF
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial "Extra:"
  assert_output --partial "local/ministral-3b"
}

@test "local-models: load passes stable identifier and context length" {
  run "$SCRIPT" load gpt-oss-120b --context-length 4096 --ttl 60 --yes
  assert_success
  grep -qE '^lms load gpt-oss-120b --identifier local/gpt-oss-120b --context-length 4096 --ttl 60 --yes$' "$STATEFILE"
}

@test "local-models: load auto-loads without prompt when estimate is HIGH and favorable" {
  run "$SCRIPT" load gpt-oss-120b
  assert_success
  grep -qxF 'lms load gpt-oss-120b --identifier local/gpt-oss-120b --context-length 32768' "$STATEFILE"
}

@test "local-models: load fails non-interactively when estimate needs prompt" {
  run "$SCRIPT" load qwen3.8-27b
  assert_failure 1
  assert_output --partial "requires confirmation"
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 131072 --estimate-only' "$STATEFILE"
  if grep -qE '^lms load qwen3\.8-27b --identifier local/qwen3\.8-27b --context-length [0-9]+$' "$STATEFILE"; then
    echo "load ran despite required prompt" >&2
    return 1
  fi
}

@test "local-models: load qwen3-coder-next estimates then loads plain modelKey as stable identifier" {
  run "$SCRIPT" load qwen3-coder-next --yes
  assert_success
  assert_output --partial "Estimated Total Memory: 84.44 GiB"
  assert_output --partial "loaded qwen3-coder-next as local/qwen3-coder-next"
  grep -qxF 'lms load qwen/qwen3-coder-next --identifier local/qwen3-coder-next --context-length 32768 --estimate-only' "$STATEFILE"
  grep -qxF 'lms load qwen/qwen3-coder-next --identifier local/qwen3-coder-next --context-length 32768 --yes' "$STATEFILE"
}

@test "local-models: unload alias unloads exact stable identifier only" {
  run "$SCRIPT" unload qwen3-coder-next
  assert_success
  grep -qxF 'lms unload local/qwen3-coder-next' "$STATEFILE"
  [ "$(grep -c '^lms unload ' "$STATEFILE")" -eq 1 ]
}

@test "local-models: unload --all-local unloads only identifiers beginning local/" {
  LMS_PS_JSON='[{"identifier":"local/gpt-oss-120b"},{"identifier":"not-local"},{"identifier":"local/qwen3.8-27b"}]' run "$SCRIPT" unload --all-local
  assert_success
  grep -qE '^lms unload local/gpt-oss-120b$' "$STATEFILE"
  grep -qE '^lms unload local/qwen3\.8-27b$' "$STATEFILE"
  if grep -qE '^lms unload not-local$|^lms unload --all' "$STATEFILE"; then
    echo "unsafe unload detected" >&2
    return 1
  fi
}

@test "local-models: unload --all-local propagates exact-id unload failures" {
  LMS_PS_JSON='[{"identifier":"local/gpt-oss-120b"}]' LMS_UNLOAD_EXIT=5 run "$SCRIPT" unload --all-local
  assert_failure 5
  assert_output --partial "one or more local model unloads failed"
}

@test "local-models: runs cleanly under /bin/bash 3.2" {
  run /bin/bash "$SCRIPT" list
  assert_success
  assert_output --partial "qwen3-coder-next"
  assert_output --partial "qwen/qwen3.8-27b"
}

# Writes a valid-shape OpenCode config with per-model limits so tests can
# exercise the per-alias expected-context mapping in verify.
# Args: gpt-oss-120b ctx, qwen3.5-122b-a10b ctx, qwen3.8-27b ctx,
#       qwen3-coder-next ctx, output limit applied to all four.
write_config_limits() {
  cat >"$LOCAL_MODELS_OPENCODE_CONFIG" <<EOF_CONFIG
{
  "provider": {
    "lmstudio": {
      "npm": "@ai-sdk/openai-compatible",
      "options": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/gpt-oss-120b": { "limit": { "context": $1, "output": $5 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": $2, "output": $5 } },
        "local/qwen3.8-27b": { "limit": { "context": $3, "output": $5 } },
        "local/qwen3-coder-next": { "limit": { "context": $4, "output": $5 } }
      }
    }
  }
}
EOF_CONFIG
}

@test "local-models: verify rejects qwen3.8-27b context left at the old 32768 default" {
  write_config_limits 32768 32768 32768 32768 8192
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial "unexpected limits for local/qwen3.8-27b: context=32768 output=8192 (expected 131072/8192)"
  assert_output --partial "OpenCode lmstudio model limits drifted"
}

@test "local-models: verify under /bin/bash 3.2 accepts Qwen 131072 and others 32768" {
  run /bin/bash "$SCRIPT" verify
  assert_success
  assert_output --partial "verification passed"
}

@test "local-models: load qwen3.8-27b defaults to 131072 for estimate and actual load" {
  run "$SCRIPT" load qwen3.8-27b --yes
  assert_success
  assert_output --partial "loaded qwen3.8-27b as local/qwen3.8-27b"
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 131072 --estimate-only' "$STATEFILE"
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 131072 --yes' "$STATEFILE"
  if grep -qE '^lms load .*--context-length 32768' "$STATEFILE"; then
    echo "qwen3.8-27b load used the 32768 default" >&2
    return 1
  fi
}

@test "local-models: load qwen3.8-27b under /bin/bash 3.2 defaults to 131072" {
  run /bin/bash "$SCRIPT" load qwen3.8-27b --yes
  assert_success
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 131072 --estimate-only' "$STATEFILE"
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 131072 --yes' "$STATEFILE"
}

@test "local-models: non-Qwen3.8 aliases keep the 32768 default for estimate and actual load" {
  local alias source
  for alias in gpt-oss-120b qwen3.5-122b-a10b qwen3-coder-next; do
    : >"$STATEFILE"
    case "$alias" in
      gpt-oss-120b) source="gpt-oss-120b" ;;
      qwen3.5-122b-a10b) source="qwen_qwen3.5-122b-a10b" ;;
      qwen3-coder-next) source="qwen/qwen3-coder-next" ;;
    esac
    run "$SCRIPT" load "$alias" --yes
    assert_success
    grep -qxF "lms load $source --identifier local/$alias --context-length 32768 --estimate-only" "$STATEFILE"
    grep -qxF "lms load $source --identifier local/$alias --context-length 32768 --yes" "$STATEFILE"
  done
}

@test "local-models: explicit --context-length overrides the Qwen 131072 default without touching config" {
  local before after
  before="$(cksum <"$LOCAL_MODELS_OPENCODE_CONFIG")"
  run "$SCRIPT" load qwen3.8-27b --context-length 65536 --yes
  assert_success
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 65536 --estimate-only' "$STATEFILE"
  grep -qxF 'lms load qwen/qwen3.8-27b --identifier local/qwen3.8-27b --context-length 65536 --yes' "$STATEFILE"
  if grep -qE '^lms load .*--context-length 131072' "$STATEFILE"; then
    echo "default context leaked past explicit override" >&2
    return 1
  fi
  after="$(cksum <"$LOCAL_MODELS_OPENCODE_CONFIG")"
  [ "$before" = "$after" ]
}

@test "local-models: verify rejects an unchanged model whose context was raised to 131072" {
  write_config_limits 131072 32768 131072 32768 8192
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial "unexpected limits for local/gpt-oss-120b: context=131072 output=8192 (expected 32768/8192)"
  refute_output --partial "unexpected limits for local/qwen3.8-27b"
}

@test "local-models: verify rejects a wrong output limit" {
  write_config_limits 32768 32768 131072 32768 4096
  run "$SCRIPT" verify
  assert_failure 1
  assert_output --partial "unexpected limits for local/qwen3.8-27b: context=131072 output=4096 (expected 131072/8192)"
  assert_output --partial "unexpected limits for local/gpt-oss-120b: context=32768 output=4096 (expected 32768/8192)"
  assert_output --partial "OpenCode lmstudio model limits drifted"
}
