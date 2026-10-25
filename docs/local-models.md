# LM Studio local models for OpenCode

`personal/local-models.sh` manages the LM Studio runtime for four explicitly
configured OpenCode models. It starts/verifies the server and loads/unloads
models under stable `local/...` identifiers. The config may use either the
legacy `provider.lmstudio` shape or native OpenCode v2 `providers.lmstudio`;
model discovery remains based on the configured model entries, not on a dynamic
LM Studio listing.

## OpenCode provider config

The default config is `~/.config/opencode/opencode.jsonc`. The helper accepts
these complete LM Studio provider shapes:

| Config shape | Adapter field | Accepted value | Endpoint field |
| --- | --- | --- | --- |
| Legacy `provider.lmstudio` | `npm` | `@ai-sdk/openai-compatible` | `options.baseURL` |
| Native v2 `providers.lmstudio` | `package` | `@opencode/ai/providers/openai-compatible` or `aisdk:@ai-sdk/openai-compatible` | `settings.baseURL` |

For example, the native v2 provider uses:

```jsonc
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/gpt-oss-120b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.5-122b-a10b": { "limit": { "context": 32768, "output": 8192 } },
        "local/qwen3.8-27b": { "limit": { "context": 131072, "output": 8192 } },
        "local/qwen3-coder-next": { "limit": { "context": 32768, "output": 8192 } }
      }
    }
  }
}
```

If `providers.lmstudio` is present, it takes precedence and is validated as a
whole. The helper does not fall back to the legacy entry or combine fields
between formats. Do not mix legacy `npm`/`options` fields into a native entry,
or native `package`/`settings` fields into a legacy entry. The selected
provider's `baseURL` must match the runtime endpoint below. JSONC comments and
trailing commas are accepted. In either format, `models` is keyed by the exact
`local/...` identifiers and each entry needs `limit.context` and `limit.output`.

`verify` validates this config before starting or checking the LM Studio
server. An invalid config therefore stops `verify` and `load` before runtime
startup, memory estimation, or model loading.

## LM Studio API endpoint

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
local-models load qwen3.8-27b
local-models load qwen3.8-27b --context-length 4096 --ttl 600 --yes
local-models unload qwen3.8-27b
local-models unload --all-local
```

- `list` shows aliases, LM Studio source keys, stable identifiers, and best-effort installed/loaded status.
- `status` shows server/endpoint state, loaded `local/...` identifiers, and config alignment.
- `start` starts/verifies the server only; it never loads a model.
- `verify` checks CLI dependencies, validates OpenCode config, then checks the endpoint and installed source models. Invalid config is rejected before any `lms` or curl runtime call. Loaded models are not required.
- `load` estimates first, then loads with `--identifier local/...` so the API ID exactly matches OpenCode's configured model ID.
- `unload <alias>` unloads only the exact stable ID for that alias.
- `unload --all-local` unloads loaded IDs beginning `local/`; it does not call `lms unload --all`.

## Context sizing and estimate prompts

Default load context is per alias. `verify` checks the selected provider's
`models["local/..."]` entries against these context and output limits, so the
load default and OpenCode limits cannot silently diverge:

| Alias | Default load context / expected OpenCode `limit.context` | OpenCode `limit.output` |
| --- | --- | --- |
| `qwen3.8-27b` | `131072` | `8192` |
| `gpt-oss-120b` | `32768` | `8192` |
| `qwen3.5-122b-a10b` | `32768` | `8192` |
| `qwen3-coder-next` | `32768` | `8192` |

`verify` maps each OpenCode `local/...` key back to its alias and fails if
`limit.context` differs from that alias's default or if `limit.output` is not
`8192`. The context value lives in `model_context_length` in
`personal/local-models.sh`.

Override for a single load with:

```bash
local-models load qwen3-coder-next --context-length 8192
```

`--context-length N` affects only that load. It does not edit OpenCode config.
A runtime context **lower** than the OpenCode `limit.context` for that model
creates a mismatch: OpenCode will budget against the configured window and can
send requests the loaded model cannot hold. Prefer the default unless you are
deliberately testing a smaller window.

Before loading, the script runs `lms load ... --estimate-only` and parses:

- `Estimated Total Memory`
- `Confidence:`
- favorable/unfavorable estimate prose

It auto-loads only when memory is parseable, at most `16 GiB`, the estimate text
is clearly favorable, and confidence is recognized and not `LOW`. Otherwise it
prompts. In non-interactive shells, prompt-required loads fail unless `--yes` is
passed.

### Applying config and context changes

OpenCode reloads config changes automatically. If an edit is not reflected,
use `/reload` in OpenCode. Reloading config does not change the context of a
model already loaded in LM Studio. To change a loaded model's context, unload
that alias and load it again with the desired context; the helper does not do
this automatically. For example:

```bash
local-models unload qwen3.8-27b
local-models load qwen3.8-27b
```

The second command uses the configured `131072` default, runs the memory
estimate, and may ask for confirmation. Configured context is not a guarantee
of runtime memory use or performance.

## Managed model mapping

| Alias | LM Studio source | Stable identifier / OpenCode model ID | Format |
| --- | --- | --- | --- |
| `gpt-oss-120b` | `gpt-oss-120b` | `local/gpt-oss-120b` | GGUF |
| `qwen3.5-122b-a10b` | `qwen_qwen3.5-122b-a10b` | `local/qwen3.5-122b-a10b` | GGUF |
| `qwen3.8-27b` | `qwen/qwen3.8-27b` | `local/qwen3.8-27b` | MLX 8-bit |
| `qwen3-coder-next` | `qwen/qwen3-coder-next` | `local/qwen3-coder-next` | MLX 6-bit |

The LM Studio source is the plain `modelKey` from `lms ls --json`, without the
`@6bit`/`@8bit` variant suffix LM Studio shows for MLX models.

Embedding models are not part of this script-managed OpenCode roster.

## Adding, removing, or updating a managed model

There is no dynamic `local-models.sh add` command yet. For now:

1. Edit the hardcoded mapping functions in `personal/local-models.sh`
   (including `model_context_length` for the alias's default context).
2. Add/remove the matching `models."local/..."` entry under the selected
   `provider.lmstudio` or `providers.lmstudio` block in
   `~/.config/opencode/opencode.jsonc`. Set `limit.context` to the alias's
   default and `limit.output` to `8192`.
3. Keep the selected provider shape and adapter consistent with the table
   above, and set its format-specific endpoint field to
   `http://127.0.0.1:1234/v1`.
4. Run:

   ```bash
   local-models verify
   ./tests/test_helper/bats-core/bin/bats tests/local-models.bats
   ```

5. OpenCode reloads config edits automatically. If the change is not visible,
   use `/reload` in OpenCode. Reloading the config does not reload an already
   loaded LM Studio model; unload and load that alias again if its runtime
   context needs to change.

Future work: add `local-models.sh add` to inspect installed LM Studio models,
generate a safe stable identifier, update OpenCode config, and extend the drift
guard tests automatically.
