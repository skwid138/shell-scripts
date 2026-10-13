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

The rc tier (`rc/zsh_config.zsh`) forces zsh's emacs keymap (with
`EDITOR=vim` zsh would otherwise pick vi mode), binds fn+←/fn+→ to
beginning/end of line with a reminder to use Ctrl+A / Ctrl+E, and enables
`HIST_IGNORE_SPACE` so commands typed with a leading space are left out of
history (they still show up in `ps` and other process listings). Completion
is initialized by zplug (`rc/zsh_plugins.zsh`) when it's installed; if
completion isn't initialized by then, `init_rc.zsh` runs a fallback
`compinit`.

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
`shell/rc/aliases.zsh`; others are run directly:

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
- `personal/cache-prune.sh` (no alias) — conservative
  developer-cache cleanup (uv, pnpm, npm, Docker via OrbStack). Dry-run
  by default; `--apply` prunes. `--install` / `--uninstall` manage a monthly
  LaunchAgent (day 1, 10:00) that runs `--apply`. Logs to
  `~/Library/Logs/cache-prune.log`. Each mutating command runs in its own
  process group, so a TERM/INT stops it at once (TERM, a grace period, then
  KILL; exit 143/130, lock released). launchd's job-group cleanup no longer
  reaches those groups; the script's own cleanup plus the agent's
  `ExitTimeOut` (30s) replace it. Killing the docker CLI does not cancel or
  roll back work the daemon already accepted: an interrupted run may leave a
  removal or prune partly done, and the next run re-inventories.
- `personal/gitleaks-hook.sh` (no alias) — global pre-commit secret scan.
  Registered in the dotfiles `~/.gitconfig` as a git config hook
  (`hook.gitleaks.command` / `hook.gitleaks.event = pre-commit`), so it runs
  in every repo *before* the repo's own `.git/hooks/pre-commit` or
  `core.hooksPath` hook (which still run). The registration skips with a warning
  only when the script is absent; a present but non-executable script
  blocks the commit. `--run` scans exactly what is being
  committed (`gitleaks git --pre-commit --staged`, honoring git's
  `GIT_INDEX_FILE`); findings block the commit with rotate-first guidance,
  gitleaks errors block as "scan error (not a finding)", and a missing
  gitleaks binary warns and allows. `--status` shows the registration.
  Opt a repo out with `git config hook.gitleaks.enabled false`.
- `personal/gitleaks-audit.sh` (no alias) — daily gitleaks *history* audit of
  the repos under `~/code` (depth ≤ 3). Dry-run by default; `--run` rescans
  only repos whose refs/HEAD/stash, linked-worktree HEADs,
  `.gitleaks.toml`/`.gitleaksignore` (and its `[extend]` chain), or gitleaks
  version changed (everything weekly); `--report` prints the reduced
  findings (rule, file:line, commit — never the secret). Existing findings are
  baselined on first scan; afterwards only new fingerprints or errors notify.
  An undelivered baseline/NEW notification stays pending (one line per
  fingerprint: repo, commit, file, rule, line — never a secret value — in the
  600 state dir) and is retried on
  every later run.
  Private excludes live in `~/.config/gitleaks-audit/config`. LaunchAgent
  runs `--run` daily at 11:00. Logs to `~/Library/Logs/gitleaks-audit.log`.
- **Private gitleaks suppressions** (`lib/gitleaks-private.sh`, shared by the
  hook and the audit) — per-repo false-positive suppressions that live only
  on this machine, for repos whose teammates do not run these scripts:
  `~/.config/gitleaks-audit/repos/<rel>/gitleaks.toml` (passed as
  `--config`) and `.../gitleaksignore` (passed as `--gitleaks-ignore-path`),
  where `<rel>` is the repo's path under `~/code` (linked worktrees share the
  main repo's store; submodules have their own; repos outside `~/code` have
  none). Every path from `$HOME` down to each file must be a non-symlink
  owned by you, not group/other writable, with no ACL entry letting anyone
  else write. `gitleaks.toml` is limited to `[extend] useDefault = true` plus
  `[[allowlists]]` blocks that each target one rule with `condition = "AND"`,
  anchored `paths`, and anchored `regexTarget = "line"` regexes (gitleaks'
  line target starts with a newline except on a fragment's first line, so
  line regexes begin `^\n?`); `gitleaksignore` holds only full-SHA history
  fingerprints. A violation blocks the commit (hook) or is a per-repo ERROR
  (audit). The audit also requires `~/.config/gitleaks-audit/protected`
  (`<rel> <full fingerprint>` lines: rotate-first findings that must never
  disappear) whenever the store exists, checks it every run, and records
  which private files each scan used (`--report` marks stale or unsettled
  results). Details for one repo with its private files:
  `gitleaks git --redact=100 -v --config <store>/gitleaks.toml
  --gitleaks-ignore-path <store>/gitleaksignore .` (add `--pre-commit
  --staged` for what the hook scans; pass only the flags whose files exist).
  Regexes use a strict, fail-closed RE2 subset: anchored `^…$` with no
  quantified or mid-pattern anchor (the only optional prefix is exactly
  `^\n?`), whitelisted escapes only (no `\Q…\E`, `\p`, `\x`, `\s`, or the
  negated `\D`/`\S`/`\W`), no wildcards (no unescaped `.`, no negated
  classes `[^…]`, no `\s` — write `[ \t]`), only `(…)`/`(?:…)` groups, and
  no top-level `|`. The validator enforces structure; how narrow each path,
  class, and line shape is remains a review responsibility. Breadth to avoid
  in review: whole-printable ranges like `[ -~]` or `[!-~]`, `\w+` (or any
  broad class with `+`/`*`) standing for most of a line, and path regexes
  that match whole directories instead of named files. Private
  suppressions require macOS (BSD `stat`, `ls -le` ACLs); elsewhere an
  existing store blocks the hook with a "require macOS" error. The audit
  announces each NEW fingerprint once across process crashes and failed
  state writes, with three exceptions: power loss (no fsync); a crash right
  after a notification is shown, before the pending file is rewritten
  (repeats it once); and a failed pending-file write after a notification
  has been shown (may repeat that announcement once; the run exits 1).
  A delivered announcement whose fingerprint never reaches that repo's
  known (finding gone or suppressed before recovery, repo excluded or
  removed) stays in the pending file, marked delivered, indefinitely, so a
  later reappearance is not reported as NEW. `--report` lists those
  delivered entries (repo, rule, file:line, with counts; entries whose
  fingerprint is already in known are marked, since the next `--run` drops
  them). `gitleaks-audit.sh --prune-delivered` removes both delivered kinds
  under the audit lock, whatever known says, and keeps every other row
  byte-for-byte (the next `--run` still announces them); it never notifies,
  exits 75 when the lock is busy, and exits 1 with the pending file
  untouched on any read/write/rename/log failure. Afterwards a pruned
  fingerprint already in its repo's known stays known (never re-announced);
  one that is not reappears as NEW if the repo has a known file, or is
  baselined if not. Preview with `--prune-delivered --dry-run` (no lock,
  log, or state writes). The audit trusts a repo as
  unchanged only when its findings, provenance, and
  snapshot agree, and rescans it as "unsettled" otherwise (the first run
  after upgrading rescans every repo once, since older state has no
  provenance). Accepted limitation: validation and use are not atomic. Both
  the hook and the audit validate the store again after gitleaks returns
  (a store that no longer validates blocks the commit / publishes nothing,
  and a mid-scan content change keeps the audit snapshot from advancing),
  but an accidental edit made and undone entirely within one scan window
  cannot be seen. The threat model is accidents, not same-user tampering.
  The store is local-only: back it up with `--export-store` (below).

#### Backing up and restoring the private store

The store (`~/.config/gitleaks-audit/repos/`, `protected`, and `config`) is
backed up with an encrypted archive and restored by hand:

```bash
gitleaks-audit.sh --set-export-passphrase       # once, in Terminal
gitleaks-audit.sh --export-store <dest-dir>     # gitleaks-store-<UTC>.tar.gz.enc
gitleaks-audit.sh --import-store <archive>      # verify + unpack to restore-<UTC>/
```

- **Passphrase.** `--set-export-passphrase` runs `security
  add-generic-password -U -s gitleaks-audit-export -a "$USER" -w` (it needs a
  terminal; `security` prompts twice, and the passphrase never appears in
  argv). A new item goes to your default keychain; with `-U` an existing
  matching item anywhere in the keychain search list is updated where it
  is. A `security` CLI generic password lives in the **file-based login
  keychain, not in iCloud Keychain** (which syncs through the Passwords
  app), so it does **not** sync to your other devices. Keep a copy of the
  passphrase off this Mac (e.g. in a password manager): without it the
  archives cannot be opened after losing this Mac. Export reads it with
  `find-generic-password` (30 s watchdog; "not found" says how to set it).
- **Export.** Validates the whole store first, independent of repo
  discovery (only directories and `repos/<rel>/gitleaks.toml|gitleaksignore`,
  every grammar, owner/mode/ACL checks, member names up to 100 bytes);
  anything unexpected means no artifact. The archive (ustar + gzip with a
  `MANIFEST` of sha256 sums; never `review/`, `restore-*/`, or audit state)
  is encrypted with `openssl enc -aes-256-cbc -pbkdf2 -iter 600000`, the
  passphrase passed on a file descriptor only, and published atomically
  into `<dest-dir>` (an existing real directory you own) as a 600 file with
  no ACL; the path and sha256 are printed. The archive must pass the
  import's own checks and limits (at most 2000 members, 6 MiB of tar,
  compressed size below 6 MiB) or nothing is published. Intermediates live in
  a private work dir whose ACL is stripped before anything is written. It
  runs under the audit lock (exit 75 when busy). `--plain` skips encryption:
  avoid it.
- **What the archive holds.** Sensitive metadata: repo names and paths,
  rules, and full fingerprints (commit:file:rule:line) of findings,
  including unrotated secrets, but no secret values.
- **iCloud.** An encrypted archive may live in iCloud Drive. With standard
  iCloud data protection Apple holds the keys for iCloud Drive; with
  Advanced Data Protection only your devices do. Never put the live store
  itself in iCloud or any synced folder (its validation requires a local,
  non-symlinked, owner-only path). How iCloud Drive's File Provider treats
  the export folder (e.g. evicting local copies) is verified when the
  backup is activated.
- **Import** never touches the live `repos/`, `protected`, or `config` and
  takes no lock. It decrypts (keychain passphrase, else a terminal prompt;
  no terminal is an error) and decompresses under 6 MiB caps, checks every
  tar header before anything is extracted (strict ustar, regular files and
  directories only, allowlisted names, no links, `..`, duplicates, or
  hidden name suffixes), verifies `MANIFEST` both ways, validates the result
  like a live store, and moves it to `~/.config/gitleaks-audit/restore-<UTC>/`.
  The store base must pass the live-store chain checks (no symlinks, owned
  by you, not group/other writable); the restore dir is private (700, no
  ACL) before anything moves in, the final tree is 700/600 without ACLs, and
  an interrupted import removes its unfinished restore dir.
- **Install (manual), as printed by the import.** Fresh machine:
  `mv restore-<UTC>/repos ~/.config/gitleaks-audit/repos`, the same for
  `protected`, and `config` only if none exists. Existing store: first move
  the live `repos/` and `protected` into a `backup-<UTC>/` dir, then move the
  restored ones in, then run `gitleaks-audit.sh --full`.
- **Restore scope and consequences.** Only the store is restored. Audit
  state is not: the first scan afterwards baselines (no NEW
  notifications), and pending announcements are not restored. While
  `repos/` exists without `protected` the audit reports a run ERROR, so
  move them together. During the move the commit hook sees no store: that
  only adds blocking for a valid store, but a commit blocked only by a
  store error can pass in that window.

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
plus a separate gitleaks job for secret scanning (`gitleaks git` over the
full history). Two test jobs let us distinguish serial-only regressions
from parallel-only regressions. Ubuntu jobs install gitleaks through
`.github/actions/install-gitleaks` (one pinned version and SHA256 in the
workflow env, verified before extracting); macOS jobs use Homebrew. Every
test job keeps its TAP output and fails unless the four real-gitleaks hook
tests in `tests/gitleaks-hook.bats` ran (`ok`, never `# skip`), checked by
`.github/scripts/require-real-gitleaks-tests.sh`.

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

The global gitleaks config hook (`personal/gitleaks-hook.sh`, registered in
the dotfiles `~/.gitconfig`) runs before this repo hook on every commit; both
run. `git commit --no-verify` skips both.

### LaunchAgents (macOS)

```bash
make install-agents   # <agent>.sh --install for every agent in AGENTS
make uninstall-agents # <agent>.sh --uninstall for each
make agents-status    # <agent>.sh --status for each (loaded / plist path)
```

`AGENTS` is an explicit list in the Makefile: `cache-prune` (monthly,
day 1 10:00, `--apply`) and `gitleaks-audit` (daily 11:00, `--run`). Every
agent is attempted even if an earlier one fails; the target then exits
nonzero and names the failures. Agents are per-user (`gui/<uid>`), render
their plist with absolute paths from the current `$HOME`, use
`RunAtLoad false`, and are never kickstarted on install.

Shutdown exercise (opt-in, manual, talks to your launchd; a few minutes):

```bash
agent/launchd-shutdown-check.sh --target gitleaks-audit          # describe only
agent/launchd-shutdown-check.sh --target gitleaks-audit --run
agent/launchd-shutdown-check.sh --target cache-prune --run
```

It bootstraps a throwaway `com.skwid138.shutdowntest.<pid>` job (refusing
if that label exists) that runs the real script with a temp `HOME`, a
stub-first base PATH (no Homebrew or OrbStack), a fake nvm default, and a
production-like plist, after checking each tool's resolution explicitly.
A stubbed step (`gitleaks git` / `uv cache prune`) marks itself, spawns a
descendant, and hangs; the exercise stops it with `launchctl bootout` and
with `launchctl kill TERM` (always the exact service `gui/<uid>/<label>`),
then checks that the step's and the job's process groups empty within the
stop timeout counted from the stop request, the lock is released or
reclaimable, nothing is published, and the next run exits 0. A `ps` that
fails is a failed check, never "nothing left". All checks
are reported before the cleanup trap, which only touches this run's job,
processes, and temp dir. The real agents are only read with `launchctl
print` (before and after; they must match).

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
