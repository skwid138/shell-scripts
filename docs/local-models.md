# LM Studio local models for OpenCode

`personal/local-models.sh` manages the LM Studio runtime side of OpenCode local
models. OpenCode model discovery is static in `~/.config/opencode/opencode.jsonc`;
this script starts/verifies the runtime and loads/unloads models under stable
`local/...` identifiers.

## Runtime endpoint

The v1 endpoint is pinned to:

```text
http://127.0.0.1:1234/v1
```

`local-models.sh start` uses `lms server start --bind 127.0.0.1 --port 1234` and
then verifies `/v1/models` with curl. It also checks LM Studio CLI status so a
random OpenAI-compatible service on the same port does not silently pass.

If LM Studio is already running somewhere else, the script does not kill or
restart it. It fails with guidance instead.

## Commands

```bash
local-models list
local-models status
local-models start
local-models verify
local-models load ministral-3b
local-models load ministral-3b --context-length 4096 --ttl 600 --yes
local-models unload ministral-3b
local-models unload --all-local
```

- `list` shows aliases, LM Studio source keys, stable identifiers, and best-effort installed/loaded status.
- `status` shows server/endpoint state, loaded `local/...` identifiers, and config alignment.
- `start` starts/verifies the server only; it never loads a model.
- `verify` checks CLI availability, endpoint response, installed source models, and OpenCode config drift. Loaded models are not required.
- `load` estimates first, then loads with `--identifier local/...` so the API ID exactly matches OpenCode's configured model ID.
- `unload <alias>` unloads only the exact stable ID for that alias.
- `unload --all-local` unloads loaded IDs beginning `local/`; it does not call `lms unload --all`.

## Context sizing and estimate prompts

Default context length is `32768` tokens. Override with:

```bash
local-models load ministral-3b --context-length 8192
```

Before loading, the script runs `lms load ... --estimate-only` and parses:

- `Estimated Total Memory`
- `Confidence:`
- favorable/unfavorable estimate prose

It auto-loads only when memory is parseable, at most `16 GiB`, the estimate text
is clearly favorable, and confidence is recognized and not `LOW`. Otherwise it
prompts. In non-interactive shells, prompt-required loads fail unless `--yes` is
passed.

## V1 mapping

| Alias | LM Studio source | Stable identifier / OpenCode model ID |
| --- | --- | --- |
| `ministral-3b` | `mistralai/ministral-3-3b` | `local/ministral-3b` |
| `qwen3-vl-8b` | `qwen/qwen3-vl-8b` | `local/qwen3-vl-8b` |
| `qwen3-vl-30b` | `qwen/qwen3-vl-30b` | `local/qwen3-vl-30b` |
| `qwen3-coder-next` | `qwen3-coder-next-0` | `local/qwen3-coder-next` |
| `qwen3.5-122b-a10b` | `qwen_qwen3.5-122b-a10b` | `local/qwen3.5-122b-a10b` |
| `gpt-oss-120b` | `gpt-oss-120b` | `local/gpt-oss-120b` |

Embedding models are intentionally excluded from OpenCode v1.

## Manual add/remove/update in v1

There is no dynamic `local-models.sh add` command yet. For now:

1. Edit the hardcoded mapping functions in `personal/local-models.sh`.
2. Add/remove the matching `provider.lmstudio.models."local/..."` entry in
   `~/.config/opencode/opencode.jsonc`.
3. Keep `provider.lmstudio.options.baseURL` as `http://127.0.0.1:1234/v1`.
4. Run:

   ```bash
   local-models verify
   ./tests/test_helper/bats-core/bin/bats tests/local-models.bats
   ```

5. Restart the OpenCode daemon so the static config reloads:

   ```bash
   opensession --local --restart
   ```

Future work: add `local-models.sh add` to inspect installed LM Studio models,
generate a safe stable identifier, update OpenCode config, and extend the drift
guard tests automatically.
