# `agent/` — opencode-callable scripts

These scripts are designed to be invoked by [opencode](https://opencode.ai)
skills and commands. They follow a strict contract: structured JSON output
on stdout, predictable exit codes, `--help` always supported, and no remote
side effects unless an explicit off-by-default mutation flag is passed. The
documented exception is `pi-ssh.sh`: it is a transparent SSH passthrough whose
stdout/exit status belong to `ssh` or the remote command, and allow-listed use
permits unprompted arbitrary Pi command execution, including remote `sudo`.
`launchd-shutdown-check.sh` is also not part of the JSON contract: it is an
opt-in manual exercise with a human-readable PASS/FAIL report.

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
| [`gh-label-sync.sh`](gh-label-sync.sh) | Converge GitHub labels on `skwid138`-owned repos to the declarative taxonomy. Dry-run default; `--apply` mutates. | `triage`, `to-issues` skills |
| [`gh-pr-checks-summary.sh`](gh-pr-checks-summary.sh) | Fetch GitHub PR check runs and roll them up to a single status (`passed`/`failed`/`running`/`not_found`). Filterable by check-name regex. | `sonarcloud`, `ticket-plan`, `pr-review` skills; consumed internally by `sonar-pr-issues.sh`. |
| [`gh-pr-comments.sh`](gh-pr-comments.sh) | Fetch all review comments, threads, reviews, and review metadata for a PR via gh's GraphQL API. Handles large diff hunks via `--rawfile`. | `gh-fetch-pr-comments` skill |
| [`jira-fetch-ticket.sh`](jira-fetch-ticket.sh) | Fetch a Jira ticket (description, AC, comments, links, attachments) via `acli`. Multiple output modes: full / summary / fields-only. | `jira-ticket`, `jira-enhance`, `ticket-plan` skills |
| [`jira-qa-results-build.sh`](jira-qa-results-build.sh) | Build a pure, versioned ADF preview envelope from completed QA evidence. No Jira/network calls or file writes. | `jira-qa-results` skill |
| [`jira-qa-results-publish.sh`](jira-qa-results-publish.sh) | Preview a saved QA-results envelope by default; `--write` sends one digest-checked ADF comment. Reports CLI success without claiming readback. | `jira-qa-results` skill |
| [`jira-sprint-tickets.sh`](jira-sprint-tickets.sh) | List a project's sprint tickets for an assignee (default `currentUser()`, open sprints) via read-only `acli jira workitem search`, with validated/escaped JQL, optional repeatable `--status` filter, and `--limit`. Emits `{version, jql, count, limited, tickets:[{key, summary, status, type}]}`. | `release-deploy-checks` skill |
| [`launchd-shutdown-check.sh`](launchd-shutdown-check.sh) | Opt-in manual exercise: run a throwaway copy of the gitleaks-audit or cache-prune LaunchAgent against stubs, stop it with `launchctl bootout` and `launchctl kill TERM`, and check nothing survives or half-publishes. Exact-service targets only; `--run` required. | Run by hand (see the top-level README) |
| [`opencode-deps-check.sh`](opencode-deps-check.sh) | Audit `~/.config/opencode/opencode.json` for outdated or unpinned MCP-server / plugin / agent dependencies. | `update-opencode-deps` command |
| [`pi-ssh.sh`](pi-ssh.sh) | Pi-only scoped SSH wrapper for agent use. Convenience/scoping exception: transparent SSH passthrough and unprompted arbitrary remote Pi execution when allow-listed. | Any Pi SSH operation; use instead of raw `ssh` |
| [`scripts-doctor.sh`](scripts-doctor.sh) | Health-check this repo (and the private wpro-shell mirror) against project conventions: required tooling, CI workflow, per-script `--help` / strict-mode / lib-source / bats coverage. Text and JSON output. | `scripts-doctor` slash command |
| [`sonar-pr-issues.sh`](sonar-pr-issues.sh) | Fetch SonarCloud issues for a PR, classified by severity and impact. Includes CI-status rollup via `gh-pr-checks-summary.sh`. | `sonarcloud` skill |

## Common invocation pattern

Every script accepts `--help`. Most produce JSON on stdout:

```bash
$ ./gh-current-pr.sh --json
{"version":1,"pr_number":275}

$ ./gh-pr-checks-summary.sh --filter sonar
{"version":1,"summary":{"passed":1,"failed":0,"running":0,...},"checks":[...]}

$ ./jira-fetch-ticket.sh BIXB-18835
{"version":1,"ticket_id":"BIXB-18835","plain_view":"...","description":"...",...}
```

For pipelines, redirect stderr if you don't want the `info` decoration:

```bash
$ ./sonar-pr-issues.sh 275 2>/dev/null | jq '.counts.total'
```

## Jira QA results

`jira-qa-results-build.sh` emits a version-1 local preview envelope from one
structured input document. `jira-qa-results-publish.sh` validates the saved
envelope and defaults to preview; an explicit `--write`, exact issue key, and
reviewed ADF digest are required for its single opt-in comment invocation. See
the private OpenCode `jira-qa-results` skill for report semantics and posting
authorization gates.

## Stable contract

All scripts in this directory:

- Output top-level JSON with `"version": 1` (or a human-readable text mode
  if explicitly requested).
- Use the shared `lib/common.sh` `die_*` family — exit codes are
  predictable per [`../docs/EXIT-CODES.md`](../docs/EXIT-CODES.md).
- Are read-only with respect to remote systems unless an explicit
  off-by-default mutation flag (`--apply`, `--post-jira`, etc.) is passed.
- Exception: `pi-ssh.sh` is intentionally not read-only and does not emit JSON;
  it is a Pi-scoped SSH passthrough whose allow-listed use permits arbitrary
  remote Pi commands, including `sudo`.
- Are covered by bats tests under [`../tests/`](../tests/).

## Testing

```bash
make test          # all bats suites (parallel by default)
make test-serial   # sequential (for debugging parallel-only failures)
make check         # lint + fmt + test (CI gate)
```

Per-script suites: `tests/<script-name>.bats`. Stub external commands
(`gh`, `acli`, `gcloud`) via env vars; see `tests/gh-pr-checks-summary.bats`
for the canonical pattern.
