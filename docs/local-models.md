# LM Studio local models for OpenCode

`personal/local-models.sh` discovers installed LM Studio models and reconciles
exact runtime identities with the OpenCode LM Studio catalog. It does not keep a
second hardcoded model roster. Discovery/status commands are read-only; only
explicit `start`, `load`, or `unload` commands can have runtime side effects.

## OpenCode provider config

The default config is `~/.config/opencode/opencode.jsonc`. The helper accepts
the native OpenCode V2 `providers.lmstudio` shape and the existing legacy
`provider.lmstudio` shape. In either form, the selected provider must use the
OpenAI-compatible adapter and the matching `http://127.0.0.1:1234/v1` endpoint.
JSONC comments and trailing commas are accepted. When the native provider exists
it takes precedence; provider fields are not combined across shapes.

OpenCode catalog keys can be friendly names. `modelID`, when present, is the
exact ID sent to LM Studio; otherwise the catalog key is the effective API ID.
For example:

```jsonc
{
  "providers": {
    "lmstudio": {
      "package": "@opencode/ai/providers/openai-compatible",
      "settings": { "baseURL": "http://127.0.0.1:1234/v1" },
      "models": {
        "local/catalog-name": {
          "modelID": "org/model-z",
          "limit": { "context": 8192, "output": 4096 }
        }
      }
    }
  }
}
```

The curated config contains six friendly `local/...` entries. The helper also
allows loading other installed non-embedding models without adding them to the
picker. It resolves a catalog entry to an installed model only by exact IDs and
the LM Studio model-key association; it never matches display names or uses
fuzzy matching. Duplicate or ambiguous IDs are reported rather than guessed.

## Discovery and compatibility

`list` reads `lms ls --json`, shows every installed non-embedding model key,
and does not start LM Studio. Decision-type models are not excluded based on
unverified chat-compatibility assumptions.

When the server is already running, `status` and `verify` can read LM Studio's
documented `GET /api/v1/models` metadata. The helper uses exact `models[].key`
and `loaded_instances[].id` associations, plus reported maximum and loaded
context where available. That documented response shape has not been measured
against every LM Studio runtime; missing or malformed metadata is reported as
unverified, not treated as compatible.

For a configured model, OpenCode's `limit.context` is the minimum runtime
context needed for compatibility. A larger actual runtime context is okay; a
smaller one is incompatible. The helper checks a known LM Studio maximum before
loading and compares actual context after loading. It refuses to reload an
existing instance with a mismatched ID, unknown context, or insufficient
context; resolve it manually rather than relying on automatic unload/reload.

`list`, `status`, and `verify` are read-only and never start the server. `verify`
does not require every installed or configured model to be loaded and does not
let an unrelated model block loading the selected model. When the server is
stopped, compatibility is reported as unverified. `start` is the explicit
command that may start the LM Studio server; it preserves the existing endpoint
identity check and refuses to treat a foreign service as LM Studio.

`verify` exits nonzero for a known incompatibility, such as a loaded context
below the configured context or a loaded ID that differs from the configured
`modelID`. Missing runtime metadata, an unloaded model, or a stopped server is
reported as unverified and is not treated as a compatibility success or a
known incompatibility.

## Commands

```bash
local-models list
local-models status
local-models verify
local-models start
local-models load org/model-z
local-models load local/catalog-name --context-length 131072 --ttl 600 --yes
local-models unload org/model-z
local-models unload --all-local
```

- `list` prints installed non-embedding LM Studio model keys.
- `status` reports server/endpoint state, every loaded runtime ID, config state,
  and best-effort compatibility.
- `verify` checks config validity and reports exact runtime compatibility when
  metadata is available. It does not start the server.
- `start` may start the pinned server but never loads models.
- `load [model-key|catalog-key]` accepts an exact installed model key or exact
  configured catalog key. If omitted in a TTY, a numbered model menu is shown.
- `--identifier ID` overrides the API identifier for a new load. Without a
  configured catalog mapping, the default identifier is the exact source model
  key and is passed explicitly to `lms load --identifier`.
- `unload <identifier|model-key>` unloads one exact runtime ID. A model key is
  resolved only through the exact loaded-instance association.
- Legacy `unload --all-local` retains its existing `local/` prefix scope. It
  does not claim ownership of every discovered model or unload every model.

## Context and loading guardrails

For a configured catalog entry, `load` uses its positive `limit.context` by
default. If no usable context is configured, pass `--context-length N` or make
an explicit choice at the TTY prompt. A missing config is allowed only with an
explicit context (or interactive context choice), with a warning that OpenCode
compatibility is not established. The helper never edits OpenCode config.

`--context-length N` is the requested context for this load. It cannot be lower
than a configured OpenCode context because that would create a known-incompatible
load. If LM Studio reports a maximum context, values above it are rejected. An
advisory low-context threshold defaults to `65536`; set
`LOCAL_MODELS_LOW_CONTEXT_THRESHOLD` to change it. Falling below the threshold
warns but does not block the load.

Before a new load, the helper keeps the existing estimate and confirmation
guardrails. It auto-loads only when memory is parseable, at most `16 GiB`, the
estimate is favorable, and confidence is recognized as high or medium. Other
estimates require a TTY confirmation or `--yes`; noninteractive prompt-required
loads fail cleanly. `--ttl` is passed to the specific load. An unambiguously
matching loaded instance with enough runtime context is reused without a second
load. Existing mismatches are reported; the helper does not silently unload or
reload them.

A load command's success is not proof of OpenCode compatibility. The helper
reports verified, incompatible, or unverified runtime identity/context after a
load. If the requested model loaded but its actual context is below the
configured context, it reports incompatibility and leaves the instance for an
explicit user decision.

## Partial model-map output

When loading a model without a matching OpenCode catalog entry, the helper can
print a JSON envelope labeled `PARTIAL_REVIEW_REQUIRED`. Its `providers` model
fragment is keyed by the actual served ID and includes context only when that
context was verified. Unknown ID/context claims are omitted. The fragment does
not invent a name, output limit, or capabilities, and is not a complete
OpenCode-ready model profile.

OpenCode's custom-model fallback assumptions include 200000 context, 32000
output, tools, and images. Review the real output limit and capabilities before
manually copying the model fragment into `opencode.jsonc`. The helper never
writes config automatically.

## Curated local catalog baseline

The config preserves friendly keys and maps them to exact LM Studio model IDs:

| OpenCode key | LM Studio `modelID` | Context | Output | Sampling (`temperature`, `top_p`, `top_k`) |
| --- | --- | ---: | ---: | --- |
| `local/qwen3.8-27b` | `qwen/qwen3.8-27b` | 131072 | 16384 | `1`, `0.95`, `20` |
| `local/qwen3.8-27b-splash` | `qwen3.8-27b-splash` | 131072 | 16384 | `1`, `0.95`, `20` |
| `local/qwen3.8-flash-next-gsq-rco` | `qwen3.8-flash-next-gsq-rco` | 131072* | 16384 | `1`, `0.95`, `20` |
| `local/qwen3-coder-next` | `qwen/qwen3-coder-next` | 131072 | 8192 | `1`, `0.95`, `40` |
| `local/qwen3.5-122b-a10b` | `qwen_qwen3.5-122b-a10b` | 131072 | 16384 | `0.6`, `0.95`, `20` |
| `local/gpt-oss-120b` | `gpt-oss-120b` | 131072 | 16384 | `1`, `1`, `0` |

`*` Flash's 131072 context is an experimental config target, not a verified
runtime fit. No live model load or inference was performed for this change.
CoderNext and GPT-OSS explicitly declare text input/output so OpenCode does not
implicitly advertise image input for those known text-only models. Native
reasoning-effort forwarding is not asserted.

Earlier helper versions loaded friendly `local/...` IDs directly. The current
catalog maps those friendly keys to actual model IDs. If a legacy ID is already
loaded, inspect `lms ps --json` and unload only the exact old ID before loading
the selected model again; the helper will not silently perform that transition.
