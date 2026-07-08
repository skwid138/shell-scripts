# shell-scripts

Personal shell scripts and zsh configuration. Public mirror of `~/code/scripts/`.

This repo contains two distinct things:

1. **Interactive-shell setup** (`shell/`) — sourced by zsh via a three-tier
   init (env/login/rc barrels — see below) to compose the prompt, paths,
   aliases, plugins, and lazy Keychain-backed secrets.
2. **Standalone scripts** (`agent/`, `personal/`) — invoked directly. The
   `agent/` ones are designed to be called by [opencode](https://opencode.ai)
   skills/commands; the `personal/` ones are utilities I use myself.

## Layout

```
shell/         # sourced by zsh — three-tier init (env/login/rc), see below
agent/         # opencode-coupled tools; call directly
data/          # declarative manifests/templates consumed by agent scripts
lib/           # shared helpers sourced by agent/ and shell/
personal/      # personal utilities (gist-linked tools, helpers)
tests/         # bats test suites + bats submodules
docs/          # project docs (CONVENTIONS, EXIT-CODES, ADDING-A-SCRIPT)
```

`lib/common.sh` provides `die`, `warn`, `info`, `require_cmd`, `require_auth`.
`lib/keychain.sh` wraps macOS `security` for secret retrieval.
`lib/detect.sh` provides git-aware helpers (`detect_branch`, `detect_owner_repo`, `detect_pr_number`).

## Shell init layers (`shell/`)

The `shell/` tree is split into three tiers, each driven by a small barrel
file that sources every `*.zsh` in its tier directory:

```
shell/
├── init_env.zsh        # env tier — sourced from ~/.zshenv (every shell)
├── init_profile.zsh    # login tier — sourced from ~/.zprofile
├── init_rc.zsh         # interactive tier — sourced from ~/.zshrc
├── init.zsh            # legacy single-source shim (kept for back-compat)
├── env/                # PATH, exported vars; must be silent + side-effect-free
│   ├── paths.zsh
│   └── vars.zsh
├── login/              # heavy login-once work (nvm, conda, gcloud)
│   ├── conda.zsh
│   ├── gcloud.zsh
│   └── nvm.zsh
├── rc/                 # interactive-only (aliases, plugins, completions)
│   ├── aliases.zsh
│   ├── functions.zsh
│   ├── docker.zsh
│   └── …
└── lib/                # helpers sourced by tiers above
    ├── auto_nvm.zsh
    └── secrets.sh
```

**Why the split?** Non-interactive `zsh -c '…'` invocations (agent scripts,
CI, cron) only run the env tier — they get PATH and exported vars and skip
the login/rc cost. Login shells run env + login. Interactive shells run all
three. See the dotfiles `README.md` for how the wiring lives in
`~/.zshenv` / `~/.zprofile` / `~/.zshrc`.

### `.zsh` vs `.sh` extension convention

- **`.sh`** — POSIX/bash-portable. Linted by `shellcheck` in bash mode
  (`make lint-sh`). Used for files that must source-run under `bash` too,
  e.g. `lib/secrets.sh` is bash-portable so MCP launch wrappers can do
  `bash -c '. lib/secrets.sh; secret_load …; exec …'`.
- **`.zsh`** — zsh-only. Syntax-checked with `zsh -n` (`make lint-zsh`).
  Excluded from shellcheck by default; opt-in per-file with a top-of-file
  `# shellcheck shell=bash` directive when bash-overlap coverage is wanted.
- Both extensions are formatted by `shfmt`, which auto-detects the dialect
  from the extension (`-ln zsh` for `.zsh`, default for `.sh`).

### Lazy secrets (`lib/secrets.sh`)

Secrets are **not** loaded at shell startup. Nothing in the env tier reads
Keychain. Instead, scripts that need a secret call `secret_load` (or
`secret_get`) at the moment they need it. The result is memoized in-process,
so repeated calls in the same shell are cheap.

```bash
# Recommended: secret_load exports the env var and short-circuits on
# subsequent calls via an env-var fast path.
source ~/code/scripts/shell/lib/secrets.sh
secret_load WPRO_OPEN_AI_API_SECRET wpro-openai \
  || die_unauthed "wpro-openai not in keychain"
curl -H "Authorization: Bearer $WPRO_OPEN_AI_API_SECRET" …
```

`secret_get` exists for callers that don't want the secret in env, but be
aware of the **subshell quirk**: each `$(secret_get …)` runs in its own
subshell, so the cache write dies with that subshell and the next `$()`
re-queries Keychain. If you find yourself calling `$(secret_get …)` more
than once, switch to `secret_load`. The full API contract — including the
two-layer memoization (env-var fast path → in-process cache → Keychain) and
the `unset VAR` + `secret_clear ENTRY` re-load pattern after rotations — is
documented in the header comment at the top of
[`shell/lib/secrets.sh`](shell/lib/secrets.sh), which is the source of truth.

## Requirements

- macOS (primary). Linux works for most things; Keychain-backed secrets are
  macOS-only.
- `zsh` 5.8+ (only for `shell/`)
- `bash` 3.2+ for the standalone scripts under `agent/` and `personal/`.
  Most agent scripts work under macOS `/bin/bash` (3.2). Scripts that
  genuinely require bash 4+ (e.g. for `declare -A` associative arrays)
  guard with an explicit `BASH_VERSINFO` check and emit a `brew install bash`
  hint on failure. See `docs/CONVENTIONS.md` for the portability rule.
- Optional per-script: `gh`, `jq`, `acli` (Atlassian), `gcloud`, Chrome.

## Setup

Clone, then either symlink the relevant dotfiles (recommended; see the
[`dotfiles`](https://github.com/skwid138/dotfiles) repo) or wire the three
init barrels into your zsh startup files yourself:

```bash
git clone --recurse-submodules git@github.com:skwid138/shell-scripts.git ~/code/scripts

# In ~/.zshenv:
[[ -f "$HOME/code/scripts/shell/init_env.zsh" ]] && source "$HOME/code/scripts/shell/init_env.zsh"
# In ~/.zprofile:
[[ -f "$HOME/code/scripts/shell/init_profile.zsh" ]] && source "$HOME/code/scripts/shell/init_profile.zsh"
# In ~/.zshrc:
[[ -f "$HOME/code/scripts/shell/init_rc.zsh" ]] && source "$HOME/code/scripts/shell/init_rc.zsh"
```

The legacy `shell/init.zsh` shim still works (sources all three tiers in
order) for any external consumer; new setups should source the three
barrels directly so non-interactive shells skip the login/rc cost.

For secrets, populate macOS Keychain entries (see `~/code/dotfiles/secrets-bootstrap/README.md`
for the inventory). Secrets are read lazily via `secret_load`/`secret_get`
from `shell/lib/secrets.sh`; nothing is loaded into env at shell startup.
For local-only overrides or extra non-secret env vars, create
`shell/env/vars.local.zsh` (gitignored; auto-sourced).

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

### Personal launchers (`personal/`)

A few scripts here are interactive launchers wired up via aliases in
`shell/rc/aliases.zsh`:

- `openweb` → `personal/opencode-web.sh` — start opencode's web UI for remote
  access via Tailscale (loads password lazily from Keychain, wraps in
  `caffeinate -is`).
- `openattach` → `personal/opencode-attach.sh` — attach a local TUI to the
  running `openweb` backend so web + terminal clients share one session pool.
  Loads the same Keychain password so basic-auth succeeds without env setup.
  See `~/.config/opencode/README-remote-access.md` for the full setup.
- `local-models` → `personal/local-models.sh` — start/verify/load/unload LM
  Studio local models surfaced through OpenCode's static `lmstudio` provider.
  `opensession --local` calls `local-models start` only; it does not load a
  model or imply `--restart`. See [`docs/local-models.md`](docs/local-models.md).

## Development

```bash
make lint           # shellcheck (advisory)
make lint-strict    # shellcheck (CI gate; errors only)
make fmt            # apply shfmt formatting
make test           # bats (parallel by default; requires GNU parallel)
make test-serial    # bats sequentially (escape hatch)
make test-parallel  # alias for `make test`
make check          # full CI gate: lint-strict + fmt-check + test (parallel)
make check-serial   # sequential variant of `make check`
make help           # list all targets
```

CI runs `lint-strict`, `fmt-check`, and **both** `test-serial` and
`test-parallel` as side-by-side blocking jobs (macOS + Ubuntu matrix),
plus a separate gitleaks job for secret scanning. Two test jobs let us
distinguish serial-only regressions from parallel-only regressions.

Parallel test execution requires GNU `parallel` on PATH (preinstalled on
GitHub-hosted runners; `brew install parallel` for local dev). The
`JOBS` env var controls worker count and defaults to the CPU count
(`sysctl -n hw.ncpu` on macOS, `nproc` on Linux, fallback 4); override
with `JOBS=N make test` for debugging.

### Pre-commit hook (optional)

Install a fast pre-commit hook that lints, format-checks, and
secret-scans only the **staged** shell files (no full-tree work):

```bash
make install-hook   # enables .githooks/pre-commit via core.hooksPath
make uninstall-hook # disables it
```

The hook is a no-op when no shell files are staged. It runs `shellcheck`
(errors only — matches CI), `shfmt -d` (formatting drift), and
`gitleaks protect --staged` (if installed). Bypass with
`git commit --no-verify` for emergency commits.

## Conventions

- All scripts start with `#!/usr/bin/env bash` and `set -uo pipefail` (not
  `-e`; see `docs/CONVENTIONS.md`).
- All scripts accept `-h`/`--help`.
- All scripts exit non-zero on error with a clear message to **stderr**.
- Data-retrieval scripts emit JSON to stdout; nothing else.
- Scripts are read-only with respect to remote systems unless you pass an
  explicit, off-by-default opt-in flag (e.g. `--apply`, `--post-jira`); see
  `docs/CONVENTIONS.md`.
- Scripts validate their own dependencies up front (`require_cmd`, `require_auth`).

## License

[MIT](LICENSE)
