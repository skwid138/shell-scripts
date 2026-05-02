# ~/code/scripts/Makefile
# Test runner, lint, and format for shell scripts.

BATS    := ./tests/test_helper/bats-core/bin/bats
TESTS   := tests/*.bats
# Collect shell scripts under the four script-bearing directories, split by
# dialect so each gets the right tooling (rev. 6 of the zsh-init refactor).
#
# `find` (rather than $(wildcard)) is used uniformly for two reasons:
#   1. Uniformity / readability — one idiom rather than mixed wildcard+find.
#   2. Recursion — personal/ has subdirs (e.g. personal/docker_rollback/),
#      and we don't want lint coverage to silently miss a script just because
#      someone nests it. The other dirs (shell/, agent/, lib/) are flat today
#      but recursion costs nothing if that ever changes.
# The 2>/dev/null protects against any of the dirs being absent.
#
# .sh = POSIX/bash-portable (linted by shellcheck in bash mode).
# .zsh = zsh-only (syntax-checked by `zsh -n`; shellcheck excluded by default,
#   per-file opt-in via `# shellcheck shell=bash` directive at top of file).
# Both extensions are formatted by shfmt, which auto-detects dialect from the
# file extension (shfmt v3+ supports `-ln zsh` natively; .zsh files are
# parsed under the zsh dialect, .sh under bash).
SH_FILES  := $(shell find shell agent lib personal -name '*.sh'  -type f 2>/dev/null)
ZSH_FILES := $(shell find shell agent lib personal -name '*.zsh' -type f 2>/dev/null)
SCRIPTS   := $(SH_FILES) $(ZSH_FILES)

# shfmt formatting flags (project convention):
#   -i 2  : 2-space indent (matches .editorconfig)
#   -ci   : indent switch case clauses
# Notably NOT -sr (we keep redirects unspaced, e.g. >/dev/null)
# Dialect (`-ln bash` / `-ln zsh`) is auto-detected from extension.
SHFMT_FLAGS := -i 2 -ci

.PHONY: help test install-bats lint lint-sh lint-zsh lint-strict fmt fmt-check check clean install-hook uninstall-hook refresh-paths

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install-bats: ## Initialize bats test framework submodules
	@if [ ! -f $(BATS) ]; then \
		echo "Initializing bats submodules..."; \
		git submodule update --init --recursive tests/test_helper; \
	fi

test: install-bats ## Run all bats tests
	$(BATS) $(TESTS)

# --- Lint targets (dialect-aware; rev. 6) ---------------------------------
# .sh files: shellcheck (bash mode). .zsh files: `zsh -n` parser check.
# `lint` runs both at warning severity (advisory); `lint-strict` runs both
# at error severity (CI gate). `lint-sh` and `lint-zsh` are the underlying
# per-dialect targets, exposed for targeted iteration.

lint-sh: ## Run shellcheck on .sh files (severity warning+; advisory)
	@if [ -n "$(SH_FILES)" ]; then \
		shellcheck -x --severity=warning $(SH_FILES); \
	else \
		echo "lint-sh: no .sh files found"; \
	fi

lint-zsh: ## Syntax-check .zsh files with `zsh -n`
	@command -v zsh >/dev/null 2>&1 || { echo "zsh not installed; cannot lint .zsh files"; exit 3; }
	@if [ -z "$(ZSH_FILES)" ]; then \
		echo "lint-zsh: no .zsh files found"; \
	else \
		fail=0; \
		for f in $(ZSH_FILES); do \
			zsh -n "$$f" || { echo "syntax error: $$f" >&2; fail=1; }; \
		done; \
		exit $$fail; \
	fi

lint: lint-sh lint-zsh ## Lint all shell files (advisory severity)

lint-strict: ## Stricter lint that gates CI: errors only
	@if [ -n "$(SH_FILES)" ]; then \
		shellcheck -x --severity=error $(SH_FILES); \
	fi
	@command -v zsh >/dev/null 2>&1 || { echo "zsh not installed; cannot lint .zsh files"; exit 3; }
	@if [ -n "$(ZSH_FILES)" ]; then \
		fail=0; \
		for f in $(ZSH_FILES); do \
			zsh -n "$$f" || { echo "syntax error: $$f" >&2; fail=1; }; \
		done; \
		exit $$fail; \
	fi

# --- Format targets (shfmt auto-detects dialect from extension) ----------

fmt: ## Apply shfmt formatting in place (2-space indent, switch-case indent)
	@command -v shfmt >/dev/null 2>&1 || { echo "shfmt not installed. Run: brew install shfmt"; exit 3; }
	shfmt $(SHFMT_FLAGS) -w $(SCRIPTS)

fmt-check: ## Verify shfmt formatting (CI gate; exits non-zero on diff)
	@command -v shfmt >/dev/null 2>&1 || { echo "shfmt not installed. Run: brew install shfmt"; exit 3; }
	@out="$$(shfmt $(SHFMT_FLAGS) -l $(SCRIPTS))"; \
	if [ -n "$$out" ]; then \
		echo "shfmt: the following files are not formatted:"; \
		echo "$$out" | sed 's/^/  /'; \
		echo ""; \
		echo "Run 'make fmt' to fix."; \
		exit 1; \
	fi

check: lint-strict fmt-check test ## Full CI gate: strict lint + format check + tests

install-hook: ## Enable .githooks/pre-commit (sets git core.hooksPath)
	@# Use git's native core.hooksPath (Git 2.9+) instead of symlinking
	@# .git/hooks/pre-commit. This:
	@#   1) auto-picks-up future .githooks/pre-commit edits (no re-install).
	@#   2) survives 'rm -rf .git/hooks' / fresh clones if re-run.
	@#   3) is per-repo (not global), so no risk to other repos.
	@# Bypass any time with: git commit --no-verify
	@if [ ! -x .githooks/pre-commit ]; then \
		echo "error: .githooks/pre-commit not found or not executable"; \
		exit 1; \
	fi
	@git config core.hooksPath .githooks
	@echo "✓ pre-commit hook enabled (git config core.hooksPath = .githooks)"
	@echo "  Bypass with: git commit --no-verify"
	@echo "  Disable with: make uninstall-hook"

uninstall-hook: ## Disable the pre-commit hook (unsets git core.hooksPath)
	@git config --unset core.hooksPath 2>/dev/null || true
	@echo "✓ pre-commit hook disabled (core.hooksPath unset; git falls back to .git/hooks/)"

# --- refresh-paths --------------------------------------------------------
# Regenerate the `_BREW_PREFIX=( … )` block in shell/env/paths.zsh from the
# current `brew --prefix` output, then write the freshness sentinel that the
# env-tier nag in paths.zsh checks (silences the "never refreshed" / 14-day
# stale notes until the next brew upgrade ages out).
#
# Why: env-tier paths.zsh hardcodes brew prefixes to avoid `brew --prefix`
# shellouts on every shell init (~150ms tax per shell). This target is the
# explicit refresh point. The brew() wrapper in rc/functions.zsh fires it
# automatically on path-affecting subcommands (install/upgrade/uninstall/
# reinstall/bundle/update); humans run it directly when the nag appears.
#
# Tracked formulas: must stay in sync with the gnubin _path_prepend calls
# in shell/env/paths.zsh. The 'gnused' alias is intentional — see the long
# comment above the assoc-array in paths.zsh for why the key isn't 'gnu-sed'.
# postgresql is probed by version-fallback so the active install wins
# (postgresql@17 → postgresql@14 → postgresql).
#
# Idempotent: re-running with no brew changes produces a byte-identical block.

REFRESH_PATHS_FILE      := shell/env/paths.zsh
REFRESH_PATHS_SENTINEL  := $(or $(XDG_CACHE_HOME),$(HOME)/.cache)/zsh/paths-refreshed

refresh-paths: ## Regenerate _BREW_PREFIX block in env/paths.zsh from `brew --prefix`
	@command -v brew >/dev/null 2>&1 || { echo "brew not installed; cannot refresh paths" >&2; exit 3; }
	@test -f "$(REFRESH_PATHS_FILE)" || { echo "missing $(REFRESH_PATHS_FILE)" >&2; exit 1; }
	@set -e; \
	pg=""; \
	for f in postgresql@17 postgresql@14 postgresql; do \
		if p="$$(brew --prefix "$$f" 2>/dev/null)" && [ -n "$$p" ]; then pg="$$p"; break; fi; \
	done; \
	[ -n "$$pg" ] || { echo "no postgresql formula installed (tried @17, @14, postgresql)" >&2; exit 1; }; \
	coreutils="$$(brew --prefix coreutils)"; \
	grep_p="$$(brew --prefix grep)"; \
	gnused="$$(brew --prefix gnu-sed)"; \
	gawk="$$(brew --prefix gawk)"; \
	findutils="$$(brew --prefix findutils)"; \
	today="$$(date +%Y-%m-%d)"; \
	tmp="$$(mktemp)"; \
	awk -v today="$$today" \
	    -v coreutils="$$coreutils" \
	    -v grep_p="$$grep_p" \
	    -v gnused="$$gnused" \
	    -v gawk_p="$$gawk" \
	    -v findutils="$$findutils" \
	    -v pg="$$pg" '\
	BEGIN { in_block = 0 } \
	/^# >>> generated by `make refresh-paths`/ { \
	  print "# >>> generated by `make refresh-paths` — do not edit by hand >>>"; \
	  print "# Last refreshed: " today; \
	  print "# Source: brew --prefix output for the six tracked formulas."; \
	  print "# Stale-after: 14 days (env-tier nag below; brew() wrapper in rc/functions.zsh"; \
	  print "# auto-fires `make refresh-paths` on common path-affecting subcommands)."; \
	  print "typeset -gA _BREW_PREFIX"; \
	  print "_BREW_PREFIX=("; \
	  print "  coreutils \"" coreutils "\""; \
	  print "  grep \"" grep_p "\""; \
	  print "  gnused \"" gnused "\""; \
	  print "  gawk \"" gawk_p "\""; \
	  print "  findutils \"" findutils "\""; \
	  print "  postgresql \"" pg "\""; \
	  print ")"; \
	  in_block = 1; \
	  next \
	} \
	in_block && /^# <<< end generated block <<</ { \
	  print; in_block = 0; next \
	} \
	in_block { next } \
	{ print }' "$(REFRESH_PATHS_FILE)" >"$$tmp"; \
	if cmp -s "$$tmp" "$(REFRESH_PATHS_FILE)"; then \
		rm -f "$$tmp"; \
		echo "refresh-paths: $(REFRESH_PATHS_FILE) already up to date"; \
	else \
		chmod --reference="$(REFRESH_PATHS_FILE)" "$$tmp" 2>/dev/null \
		  || chmod "$$(stat -f '%Lp' "$(REFRESH_PATHS_FILE)" 2>/dev/null || stat -c '%a' "$(REFRESH_PATHS_FILE)")" "$$tmp"; \
		mv "$$tmp" "$(REFRESH_PATHS_FILE)"; \
		echo "refresh-paths: regenerated _BREW_PREFIX block in $(REFRESH_PATHS_FILE)"; \
	fi; \
	mkdir -p "$$(dirname "$(REFRESH_PATHS_SENTINEL)")"; \
	touch "$(REFRESH_PATHS_SENTINEL)"; \
	echo "refresh-paths: sentinel touched at $(REFRESH_PATHS_SENTINEL)"

clean: ## Remove test artifacts
	rm -rf tests/test_helper/bats-core tests/test_helper/bats-support tests/test_helper/bats-assert
