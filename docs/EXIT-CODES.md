# Exit Codes

Every script in `agent/` and `personal/` follows a single, predictable exit-code
convention. This is what makes them safe to compose: a caller can branch on
`$?` and know exactly what kind of failure occurred without parsing stderr.

## The table

| Code | Meaning              | Caller behavior                                    |
|-----:|----------------------|----------------------------------------------------|
| `0`  | Success              | Continue.                                          |
| `1`  | Runtime failure      | Expected failure (e.g. "no PR for this branch"). The script ran correctly but the answer is "no". Caller may retry or branch. |
| `2`  | Usage error          | Arguments were wrong. Re-invoking with the same args will fail the same way. |
| `3`  | Missing dependency   | A required binary (`gh`, `jq`, `acli`, …) is not installed. Caller should surface the install hint. |
| `4`  | Unauthenticated      | The dependency is installed but not logged in (e.g. `gh auth status` fails). Caller should surface the auth hint. |
| `5`  | Upstream API failure | Auth was fine, but the remote (GitHub, Jira, SonarCloud, gcloud) returned an error. Caller should retry or surface the upstream message. |

Codes `6`-`125` are reserved for future shared meanings. Per-script
script-specific codes (e.g. exit 8 from `gh pr checks` meaning "checks
pending") MUST be either translated to one of the codes above or documented
in the script's `--help` output.

## Why these codes

The convention is borrowed from the broader Unix tradition (codes 1, 2) and
from the `gh` CLI's own family of "this is a real failure vs this is a soft
no" exit codes. The split between `1` (soft no) and `5` (upstream broke) is
the most valuable distinction in practice — it tells callers whether to
retry, prompt the user for new input, or surface an opaque upstream error.

The split between `3` (missing dep) and `4` (unauthed) lets the calling
agent emit a precise install/auth hint without re-running the binary itself
to figure out which one applies.

## How scripts implement this

Use the `die_*` family from `lib/common.sh`:

```bash
source "$(dirname "$0")/../lib/common.sh"

require_cmd "gh"                      # exits 3 with "Install gh: ..." hint
require_auth "gh" "gh auth status" "gh auth login"  # exits 4 with auth hint

if ! out="$(gh api ... 2>&1)"; then
  die_upstream "gh api failed: $out"  # exits 5
fi

[[ -n "$1" ]] || die_usage "Usage: $0 <ticket-id>"  # exits 2

die "unexpected state"                # exits 1, the catchall
```

The helpers prepend a tagged prefix (`error:`, `usage:`, etc.) to stderr so
that callers parsing logs can still distinguish failure modes by string
match if exit code alone is not enough.

## What scripts MUST NOT do

- **Do not exit `0` on a real failure.** A "soft no" (no PR exists, ticket
  not found) is exit `1`, not `0`. Callers depend on `$?` for control flow.
- **Do not exit `2` for runtime conditions.** Reserve `2` for genuine
  argument-parsing errors. Otherwise users will think they typed something
  wrong when in fact the system is broken.
- **Do not bubble up arbitrary upstream codes.** If `gh` exits 8 ("checks
  pending"), translate it before exiting: 8 has a different meaning to
  every script that wraps `gh`. Pick one of `0`/`1`/`5` according to
  semantics, document the choice in `--help`.
- **Do not assume `set -e`.** Project policy (see
  [CONVENTIONS.md](CONVENTIONS.md)) is `set -uo pipefail` only. Always
  check return codes explicitly with `if ! cmd`, then call `die_*`.

## See also

- [`CONVENTIONS.md`](CONVENTIONS.md) — full shell style + project rules
- [`ADDING-A-SCRIPT.md`](ADDING-A-SCRIPT.md) — checklist for new scripts
- `lib/common.sh` — implementation of the `die_*` family
