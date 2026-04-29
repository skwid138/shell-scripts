# Adding a Script

A checklist for adding a new script to `agent/` or `personal/`. Following
this end-to-end produces a script that is safe to invoke from an agent,
testable in isolation, and consistent with the rest of the repo.

If you're skimming, the headline rules are in
[CONVENTIONS.md](CONVENTIONS.md). This file is the step-by-step.

## 1. Decide where it lives

| Directory   | Purpose                                                    |
|-------------|------------------------------------------------------------|
| `agent/`    | Designed to be invoked by an opencode skill or command.    |
| `personal/` | Solo utility you run yourself; not invoked by agents.      |
| `lib/`      | A shared module, sourced by other scripts. No `main`.      |

If an opencode skill will ever call it, it goes in `agent/`. The bar for
`agent/` scripts is higher: stable contract, structured output, exit-code
discipline, bats coverage, `--help`.

## 2. Skeleton

```bash
#!/usr/bin/env bash
# my-script — one-line summary
#
# Longer description: what the script does, what it returns, when to use it.

set -uo pipefail
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/detect.sh"   # if you need git/PR helpers

usage() {
  cat <<'EOF'
Usage: my-script [OPTIONS] <required-arg>

Description of what the script does.

Options:
  -h, --help        Show this help.
      --some-flag   Description.

Examples:
  my-script foo
  my-script --some-flag bar
EOF
}

# --- arg parsing ---
SOME_FLAG=0
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --some-flag) SOME_FLAG=1; shift ;;
    --) shift; ARGS+=("$@"); break ;;
    -*) die_usage "unknown flag: $1" ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

[[ ${#ARGS[@]} -ge 1 ]] || die_usage "$(usage)"

# --- preflight ---
require_cmd "jq"
require_cmd "gh"
require_auth "gh" "gh auth status" "gh auth login"

# --- main ---
# ... do work ...

# Output: JSON to stdout, with a top-level "version".
jq -n --arg foo "${ARGS[0]}" '{version: 1, foo: $foo}'
```

## 3. Argument and flag handling

- Always parse with a `while`/`case` loop. Don't use `getopts` (no support
  for long flags).
- Defer dispatch until after parsing: don't run side effects from inside
  the parsing loop. (See `agent/chrome_mcp.sh` for an example: it sets an
  `ACTION` flag during parse, then dispatches once at the end.)
- Validate that required args are present and emit a `die_usage` with the
  full usage text on failure.

## 4. Dependencies

List every external binary the script touches at the top of `main`:

```bash
require_cmd "jq"
require_cmd "gh"
require_auth "gh" "gh auth status" "gh auth login"
```

This produces clean exit 3 / exit 4 errors with install / login hints. The
agent can parse exit code and surface the hint without re-running the
binary itself.

## 5. Output contract

- **JSON to stdout, text/logs to stderr.** Pipelines should be able to
  consume stdout cleanly.
- Top-level JSON output MUST include `"version": 1`. If the schema
  changes incompatibly, bump the version; agents can branch on it.
- For human-friendly summaries, also support a `--format text` or print
  to stderr. Don't mix human prose into the JSON channel.

## 6. Exit codes

See [EXIT-CODES.md](EXIT-CODES.md). The short version: use `die_*` from
`lib/common.sh` and never invent your own codes.

## 7. Tests

Add a bats suite at `tests/<script-name>.bats`. Cover:

- `--help` exits 0 and prints usage
- Each happy-path scenario (stub external binaries with env vars)
- Each documented error path with the right exit code
- Argument-parsing edge cases (empty args, malformed args, unknown flags)
- Output structure: at minimum, assert top-level `version: 1` and the
  expected keys

Stub external commands with env-controlled fixtures, e.g.:

```bash
@test "my-script: emits version 1" {
  GH_OUT='[{"name":"x"}]' GH_RC=0 run my-script foo
  assert_success
  json="$(echo "$output" | awk '/^\{/,/^\}$/')"
  [[ "$(jq -r .version <<<"$json")" == "1" ]]
}
```

The `gh` stub itself lives in `tests/test_helper/stubs/gh` (or similar);
look at `tests/gh-pr-checks-summary.bats` for the established pattern.

## 8. Format and lint

```bash
make fmt          # apply shfmt
make lint-strict  # error-level shellcheck (CI gates on this)
make test         # run all bats
make check        # all of the above
```

`make check` MUST be clean before you commit. CI runs the same gate.

## 9. Wire into opencode (if `agent/`)

If the script is for agent consumption, also do these:

1. **Document it** in `~/.config/opencode/instruction/script-usage.md`
   under the appropriate section. Include the one-liner purpose, an
   example invocation, and the JSON output shape.
2. **Wire it into the relevant skill** at `~/.config/opencode/skill/<skill>/SKILL.md`.
   Replace any inline `gh`/`acli`/`jq` chain in the skill with a call to
   the new script.
3. **Commit both repos.** Use a `refactor(skills): route X through agent/Y.sh`
   commit message in `~/.config/opencode/`, mirroring `e3617d6` and `f3af0c0`.

## 10. Commit hygiene

Use conventional commits. Examples from this repo:

- `feat(agent): add gh-pr-checks-summary` (new script)
- `feat(lib): make branch-to-ticket regex flexible` (lib improvement)
- `fix(agent): defer chrome_mcp action dispatch until after arg parse`
- `test(agent): bats coverage for sonar-pr-issues`
- `docs: add EXIT-CODES.md and CONVENTIONS.md`
- `refactor(skills): route current-PR detection through agent/gh-current-pr.sh`

Split format/logic/test commits when possible to keep `git bisect` useful.

## See also

- [`CONVENTIONS.md`](CONVENTIONS.md) — full project rules
- [`EXIT-CODES.md`](EXIT-CODES.md) — exit code reference
- [`../agent/README.md`](../agent/README.md) — index of existing agent scripts
- [`../lib/common.sh`](../lib/common.sh) — `die_*`, `require_cmd`, `require_auth`
