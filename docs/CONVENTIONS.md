# Conventions

Project-wide rules for shell scripts in `agent/`, `personal/`, `lib/`, and
`shell/`. These are derived from the [Google Shell Style Guide][gss],
[ShellCheck][sc] wiki, and [BashFAQ/105][faq105], with adaptations where the
project's "agent-callable script" model needs something stronger.

[gss]: https://google.github.io/styleguide/shellguide.html
[sc]: https://www.shellcheck.net/wiki/Home
[faq105]: https://mywiki.wooledge.org/BashFAQ/105

## Shebang

Always:

```bash
#!/usr/bin/env bash
```

Never `#!/bin/bash`. macOS ships bash 3.2 at `/bin/bash` for licensing
reasons and that path will never advance. Using `env bash` picks up the
user's installed bash (typically `/opt/homebrew/bin/bash`, version 5.x) when
available, while still working under bash 3.2 if that's all there is — see
the bash portability rule below.

## Strict mode

Use:

```bash
set -uo pipefail
```

**Not** `set -e`. The project follows BashFAQ/105's reasoning: `-e` has too
many surprising exemptions (commands in `if`/`while` conditions, pipelines,
subshells, function calls in compound commands, etc.) to be the primary
error-handling mechanism for scripts that need predictable behavior. Use
explicit error handling instead:

```bash
if ! out="$(gh api ... 2>&1)"; then
  die_upstream "gh api failed: $out"
fi
```

`-u` (error on unset variables) and `-o pipefail` (a pipeline fails if any
stage fails) are kept because they catch real bugs without the foot-guns of
`-e`.

## Error handling

Source `lib/common.sh` immediately after `set`:

```bash
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
```

Use the `die_*` family for all exits. See [EXIT-CODES.md](EXIT-CODES.md)
for the full table; the headline ones:

- `die "msg"` — generic runtime failure (exit 1)
- `die_usage "msg"` — bad arguments (exit 2)
- `die_missing_dep <cmd> <hint>` — install hint (exit 3)
- `die_unauthed <cmd> <auth-cmd> <login-cmd>` — auth hint (exit 4)
- `die_upstream "msg"` — remote API failure (exit 5)

Use `require_cmd` and `require_auth` at the top of the script's main body
to fail fast before doing real work.

## Argument handling

- Every script accepts `-h` / `--help` and exits 0 with a usage message on
  **stdout** (so `script --help | less` works).
- Use `parse_pr_ref` from `lib/detect.sh` for PR references (`275`, `#275`,
  `owner/repo#275`, full URL). Never re-implement.
- Use `detect_*` helpers (`detect_branch`, `detect_owner_repo`,
  `detect_pr_number`, `detect_ticket_from_branch`) for git-aware defaults.

## Output

- **JSON to stdout**, logs and errors to stderr. Pipelines should be able
  to consume the script's stdout cleanly.
- Top-level JSON output MUST include `"version": 1` to allow future schema
  changes without breaking callers silently.
- `info` / `warn` / `error` (from `lib/common.sh`) all write to stderr.

## Quoting

- Always `"$var"`. Always `"${arr[@]}"` for arrays.
- For fixed string-to-string lookups (e.g. repo name → SonarCloud project key),
  prefer a function with a `case` statement over `declare -A`. It's bash 3.2-
  portable, doesn't trip shfmt's arithmetic-expression bug on dashed keys,
  and reads cleanly:

  ```bash
  project_key_for_repo() {
    case "$1" in
      client-portal) echo "wpromote_client-portal" ;;
      kraken)        echo "wpromote_kraken" ;;
      *) return 1 ;;
    esac
  }
  ```

- If you do need `declare -A` (dynamic keys, runtime accumulation), gate
  the script on bash 4+ per the portability rule below, **and always quote
  the key when it contains `-`**. `shfmt` will otherwise reformat
  `MAP[foo-bar]` as if `foo-bar` were arithmetic and corrupt the script.
  There is a regression test for this (`tests/sonar-pr-issues.bats`).
  The rule:

  ```bash
  declare -A MAP=(
    ["client-portal"]="wpromote_client-portal"   # KEEP THE QUOTES
  )
  ```

## Bash portability rule (T7.4)

Default to bash 3.2-compatible idioms. macOS `/bin/bash` is bash 3.2 and
will stay that way; tests, scripts under restricted PATH, or scripts run
in non-interactive shells may end up there. Newer bash is backward
compatible, so portable code costs nothing in modern environments.

**Disallowed without an explicit version guard:**

- `${var^^}` / `${var,,}` — use `tr '[:lower:]' '[:upper:]'`
- `mapfile` / `readarray` — use `while IFS= read -r line; do …; done < <(...)`
- `coproc`
- `&>>` and most other bash-4-only redirect shortcuts
- `[[ -v var ]]` — use `[[ -n "${var-}" ]]`

**Allowed with an explicit version guard:** features like `declare -A`
(associative arrays) where there's no clean 3.2 equivalent. Guard with:

```bash
if (( BASH_VERSINFO[0] < 4 )); then
  die "this script requires bash 4+; install with: brew install bash"
fi
```

If you genuinely need bash 4, **say so**. Otherwise, write 3.2-portable
code.

## Mutating remote systems

Scripts in this repo are **read-only with respect to remote systems**. They
must not:

- `git push`, `gh pr create`, `gh pr merge`, `gh issue close`
- deploy, redeploy, restart services
- delete records or rotate secrets
- post comments to Jira/GitHub *unless* the user explicitly opted in via a
  `--post-jira` or similar flag (and the flag is off by default)

This makes them safe for agents to invoke without escalating consequences.

## Dependency checks

At the top of every script's main body:

```bash
require_cmd "jq"
require_cmd "gh"
require_auth "gh" "gh auth status" "gh auth login"
```

This produces a clean exit 3 / exit 4 with an actionable hint. Never check
deps with `command -v` ad-hoc.

## Formatting (shfmt)

Project config: `shfmt -i 2 -ci`. Specifically **NOT** `-sr`: the project
prefers redirects unspaced (`>/dev/null`, not `> /dev/null`).

Run `make fmt-check` before committing; CI gates on it.

## Linting (shellcheck)

- `make lint` — advisory (severity warning+); useful locally
- `make lint-strict` — gates CI (severity error only)

The repo-level `.shellcheckrc` disables `SC1091` (dynamic-source false
positive) and `SC2034` (unused vars in sourced files). Disable other rules
inline with a comment explaining why:

```bash
# shellcheck disable=SC2155  # we want the early exit if the rhs fails
local foo="$(some_command)" || die "..."
```

## Tests

Every public function in `lib/` and every script in `agent/` MUST have bats
coverage in `tests/`. Convention:

- `tests/<script-name>.bats` for `agent/<script-name>.sh`
- `tests/<libname>.bats` for `lib/<libname>.sh`
- Stub external commands with `GH_*`/`ACLI_*`/etc. env vars rather than
  network calls. See `tests/gh-pr-checks-summary.bats` for the pattern.
- Bats merges stderr into `$output`. To parse JSON output that's mixed
  with stderr `info()` decoration, use:

  ```bash
  get_json() { awk '/^\{/,/^\}$/'; }
  json="$(echo "$output" | get_json)"
  ```

Per-script preflight tests (missing-dep, unauthed) are not duplicated:
`tests/common.bats` covers `require_cmd` and `require_auth` once.

## File layout

See [README.md](../README.md) for the directory map. The summary:

- `shell/` — sourced by `.zshrc`, never executed directly
- `agent/` — opencode-callable scripts
- `personal/` — solo utilities
- `lib/` — shared bash modules sourced by everything else
- `tests/` — bats suites
- `docs/` — this directory

## See also

- [`EXIT-CODES.md`](EXIT-CODES.md) — exit code reference
- [`ADDING-A-SCRIPT.md`](ADDING-A-SCRIPT.md) — onboarding checklist
- [`../README.md`](../README.md) — repo orientation
