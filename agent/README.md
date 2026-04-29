# `agent/` — opencode-callable scripts

These scripts are designed to be invoked by [opencode](https://opencode.ai)
skills and commands. They follow a strict contract: structured JSON output
on stdout, predictable exit codes, `--help` always supported, no
side-effects on remote systems.

For the rules every script in this directory follows, see
[`../docs/CONVENTIONS.md`](../docs/CONVENTIONS.md). For exit-code semantics,
see [`../docs/EXIT-CODES.md`](../docs/EXIT-CODES.md). To add a new script,
follow [`../docs/ADDING-A-SCRIPT.md`](../docs/ADDING-A-SCRIPT.md).

## Scripts

| Script | Purpose | Primary callers |
|---|---|---|
| [`branch-to-ticket.sh`](branch-to-ticket.sh) | Extract a Jira ticket ID (e.g. `BIXB-18835`) from a git branch name. | `ticket-plan`, `jira-enhance` skills |
| [`chrome_mcp.sh`](chrome_mcp.sh) | Launch / check / kill the Chrome instance used by the chrome-devtools MCP server. Foreground or background, configurable port and profile. | `chrome-devtools` skill |
| [`gh-current-pr.sh`](gh-current-pr.sh) | Resolve the current branch's open PR number. JSON or bare-number output. | `sonarcloud`, `ticket-plan`, `pr-review`, `gh-fetch-pr-comments` skills |
| [`gh-pr-checks-summary.sh`](gh-pr-checks-summary.sh) | Fetch GitHub PR check runs and roll them up to a single status (`passed`/`failed`/`running`/`not_found`). Filterable by check-name regex. | `sonarcloud`, `ticket-plan`, `pr-review` skills; consumed internally by `sonar-pr-issues.sh`. |
| [`gh-pr-comments.sh`](gh-pr-comments.sh) | Fetch all review comments, threads, reviews, and review metadata for a PR via gh's GraphQL API. Handles large diff hunks via `--rawfile`. | `gh-fetch-pr-comments` skill |
| [`jira-fetch-ticket.sh`](jira-fetch-ticket.sh) | Fetch a Jira ticket (description, AC, comments, links, attachments) via `acli`. Multiple output modes: full / summary / fields-only. | `jira-ticket`, `jira-enhance`, `ticket-plan` skills |
| [`opencode-deps-check.sh`](opencode-deps-check.sh) | Audit `~/.config/opencode/opencode.json` for outdated or unpinned MCP-server / plugin / agent dependencies. | `update-opencode-deps` command |
| [`sonar-pr-issues.sh`](sonar-pr-issues.sh) | Fetch SonarCloud issues for a PR, classified by severity and impact. Includes CI-status rollup via `gh-pr-checks-summary.sh`. | `sonarcloud` skill |

## Common invocation pattern

Every script accepts `--help`. Most produce JSON on stdout:

```bash
$ ./gh-current-pr.sh --json
{"version":1,"pr_number":275}

$ ./gh-pr-checks-summary.sh --filter sonar
{"version":1,"summary":{"passed":1,"failed":0,"running":0,...},"checks":[...]}

$ ./jira-fetch-ticket.sh BIXB-18835
{"version":1,"key":"BIXB-18835","summary":"...",...}
```

For pipelines, redirect stderr if you don't want the `info` decoration:

```bash
$ ./sonar-pr-issues.sh 275 2>/dev/null | jq '.summary'
```

## Stable contract

All scripts in this directory:

- Output top-level JSON with `"version": 1` (or a human-readable text mode
  if explicitly requested).
- Use the shared `lib/common.sh` `die_*` family — exit codes are
  predictable per [`../docs/EXIT-CODES.md`](../docs/EXIT-CODES.md).
- Are read-only with respect to remote systems: they query, they don't
  mutate. Any mutation flag (`--post-jira`, etc.) defaults off.
- Are covered by bats tests under [`../tests/`](../tests/).

## Testing

```bash
make test          # all bats suites
make check         # lint + fmt + test (CI gate)
```

Per-script suites: `tests/<script-name>.bats`. Stub external commands
(`gh`, `acli`, `gcloud`) via env vars; see `tests/gh-pr-checks-summary.bats`
for the canonical pattern.
