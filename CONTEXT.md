# Shell Scripts

Personal shell scripts and zsh configuration repository. Provides interactive shell setup (sourced by zsh) and standalone scripts callable by opencode skills or used directly.

## Language

### Shell Init

**Barrel**:
An init entrypoint file that sources a fixed list of named files for its tier in explicit order.
_Avoid_: loader, bootstrap

**Env Tier**:
The zsh startup layer sourced by `~/.zshenv`; runs for every shell invocation including non-interactive. Must be fast, silent, and side-effect-free.
_Avoid_: base layer, global tier

**Login Tier**:
The zsh startup layer sourced by `~/.zprofile`; handles heavier login-once setup (nvm, conda, gcloud).
_Avoid_: profile tier

**RC Tier**:
The zsh startup layer sourced by `~/.zshrc`; interactive-only. Aliases, plugins, prompt, completions.
_Avoid_: interactive tier (acceptable synonym but RC Tier is canonical)

**Legacy Shim**:
`shell/init.zsh`; sources all three tiers sequentially. Preserved for backward compatibility with external consumers.
_Avoid_: old init, monolithic init

**path_helper Damage**:
macOS login-shell behavior where `/usr/libexec/path_helper` rewrites PATH, demoting Homebrew entries. Repaired by re-sourcing the env tier in the login tier.

**Hardcoded Brew Prefixes**:
Pre-computed Homebrew prefix paths embedded in `shell/env/paths.zsh` to avoid calling `brew --prefix` at shell startup.

**refresh-paths**:
Makefile target that regenerates the hardcoded brew prefix block. A 14-day interactive nag reminds the user to run it.

### Secrets

**Lazy Secret**:
A secret not loaded at shell startup; fetched from Keychain on first use via `secret_load` or `secret_get`.
_Avoid_: eager secret, preloaded secret

**secret_load**:
Preferred secret API (in `shell/lib/secrets.sh`). Exports a Keychain value to a named env var and short-circuits on subsequent calls via three-layer memoization (env-var fast path → in-process cache → Keychain).
_Avoid_: secret_get (when the value is needed more than once)

**secret_get**:
Fetches a Keychain entry to stdout without exporting. Subject to the subshell quirk.

**Subshell Quirk**:
`$(secret_get ...)` runs in a subshell, so cache writes disappear after substitution. Use `secret_load` instead when calling more than once.

**Keychain Entry**:
A macOS Keychain service/account item accessed via the `security` CLI.

### Script Categories

**Agent-Callable Script**:
A script in `agent/` designed to be invoked by opencode skills/commands. Has a stable JSON/exit-code contract.
_Avoid_: tool, command, plugin

**Personal Utility**:
A script in `personal/` used directly by the user. Not necessarily part of opencode automation.
_Avoid_: helper (ambiguous with lib/)

**Shared Library**:
A sourced bash module in `lib/` providing common functions. Has no `main`; never executed directly.
_Avoid_: utility, helper script

### Script Contracts

**Read-Only Remote Policy**:
Scripts may query remote systems but must not push, merge, deploy, delete, or mutate without explicit opt-in.
_Avoid_: safe mode (too vague)

**Soft No**:
The script ran correctly but the answer is "no" (e.g., no PR for this branch). Exit code `1`.
_Avoid_: error (which implies something broke)

**Upstream Failure**:
An external service/API failure. Exit code `5`.

### Opencode Session

**Opencode Daemon**:
A long-lived self-daemonized `opencode web` backend process.
_Avoid_: server, service

**Sidecar**:
A file recording the config hash at daemon start, used to detect staleness.

**Stale Daemon**:
A running daemon whose startup config hash differs from the current config hash; should be restarted.

**Listener PID**:
The process bound to the opencode TCP port, discovered via `lsof`.

**Foreign Listener**:
A process on the opencode port that is not the opencode executable.

## Relationships

- A **Barrel** sources files in exactly one **Tier** (Env, Login, or RC).
- The **Login Tier** re-sources the **Env Tier** to repair **path_helper Damage**.
- **Agent-Callable Scripts** source **Shared Libraries** from `lib/`.
- **Lazy Secrets** live in `shell/lib/secrets.sh` (not `lib/`); they wrap the low-level **Keychain Entry** access from `lib/keychain.sh`.
- An **Opencode Daemon** has exactly one **Sidecar**; a mismatched sidecar hash makes it a **Stale Daemon**.

## Example dialogue

> **Dev:** "Why doesn't the agent script have access to my API key?"
> **Domain expert:** "Secrets are **Lazy** — they're not in env at startup. The script needs to call **secret_load** explicitly before using the key."

> **Dev:** "I added a new Homebrew package but `which` still shows the system one."
> **Domain expert:** "Run `make refresh-paths` to update the **Hardcoded Brew Prefixes**, or wait for the 14-day nag."

> **Dev:** "The daemon is running but my config changes aren't reflected."
> **Domain expert:** "That's a **Stale Daemon** — the **Sidecar** hash doesn't match. Restart it."

## Flagged ambiguities

- "helper" — used for both `lib/` shared modules and `shell/lib/` zsh helpers. Resolved: use **Shared Library** for `lib/` (bash, sourced by scripts) and refer to `shell/lib/` files by name.
- "init" — could mean the legacy shim or the three-tier barrel system. Resolved: **Legacy Shim** for `init.zsh`; **Barrel** + tier name for the current system.
