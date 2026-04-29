# shell-scripts

Personal shell scripts and zsh configuration. Public mirror of `~/code/scripts/`.

This repo contains two distinct things:

1. **Interactive-shell setup** (`shell/`) — sourced by `~/.zshrc` to compose
   the prompt, paths, aliases, plugins, and secrets-from-Keychain.
2. **Standalone scripts** (`agent/`, `personal/`) — invoked directly. The
   `agent/` ones are designed to be called by [opencode](https://opencode.ai)
   skills/commands; the `personal/` ones are utilities I use myself.

## Layout

```
shell/         # sourced by .zshrc — not directly executed
agent/         # opencode-coupled tools; call directly
lib/           # shared helpers sourced by agent/ and shell/
personal/      # personal utilities (gist-linked tools, helpers)
tests/         # bats test suites + bats submodules
```

`lib/common.sh` provides `die`, `warn`, `info`, `require_cmd`, `require_auth`.
`lib/keychain.sh` wraps macOS `security` for secret retrieval.
`lib/detect.sh` provides git-aware helpers (`detect_branch`, `detect_owner_repo`, `detect_pr_number`).

## Requirements

- macOS (primary). Linux works for most things; Keychain-backed secrets are
  macOS-only.
- `zsh` 5.8+ (only for `shell/`)
- `bash` 4+ (for the standalone scripts under `agent/` and `personal/`)
- Optional per-script: `gh`, `jq`, `acli` (Atlassian), `gcloud`, Chrome.

## Setup

Clone, then symlink the relevant files from your dotfiles, or source `shell/init.sh` from your `.zshrc`:

```bash
git clone --recurse-submodules git@github.com:skwid138/shell-scripts.git ~/code/scripts

# Add to ~/.zshrc:
[[ -f "$HOME/code/scripts/shell/init.sh" ]] && source "$HOME/code/scripts/shell/init.sh"
```

For secrets, populate macOS Keychain entries (see `shell/vars.sh` for the
expected entry names — they all use `keychain_get`). For local-only overrides
or extra variables, create `shell/vars.local.sh` (gitignored; auto-sourced).

## Usage examples

```bash
# Standalone tools
agent/gh-pr-comments.sh wpromote/polaris-web#275
agent/jira-fetch-ticket.sh BIXB-18835 --all
agent/sonar-pr-issues.sh --severity MAJOR 275
agent/branch-to-ticket.sh
agent/chrome_mcp.sh --check
```

Every script takes `-h` / `--help`.

## Development

```bash
make lint           # shellcheck (advisory; warning-level findings shown)
make lint-strict    # shellcheck (CI gate; errors only)
make test           # bats — auto-installs submodules on first run
make help           # list all targets
```

CI runs `lint-strict` and `test` on every push and PR.

## Conventions

- All scripts start with `#!/usr/bin/env bash` and `set -euo pipefail`.
- All scripts accept `-h`/`--help`.
- All scripts exit non-zero on error with a clear message to **stderr**.
- Data-retrieval scripts emit JSON to stdout; nothing else.
- Scripts never commit, push, deploy, delete, or mutate remote systems.
- Scripts validate their own dependencies up front (`require_cmd`, `require_auth`).

## License

[MIT](LICENSE)
