# ~/code/scripts/Makefile
# Test runner, lint, and format for shell scripts.

BATS    := ./tests/test_helper/bats-core/bin/bats
TESTS   := tests/*.bats
SCRIPTS := $(wildcard shell/*.sh) $(wildcard agent/*.sh) $(wildcard lib/*.sh)

# shfmt formatting flags (project convention):
#   -i 2  : 2-space indent (matches .editorconfig)
#   -ci   : indent switch case clauses
# Notably NOT -sr (we keep redirects unspaced, e.g. >/dev/null)
SHFMT_FLAGS := -i 2 -ci

.PHONY: help test install-bats lint lint-strict fmt fmt-check check clean install-hook uninstall-hook

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install-bats: ## Initialize bats test framework submodules
	@if [ ! -f $(BATS) ]; then \
		echo "Initializing bats submodules..."; \
		git submodule update --init --recursive tests/test_helper; \
	fi

test: install-bats ## Run all bats tests
	$(BATS) $(TESTS)

lint: ## Run shellcheck (severity warning+; advisory)
	shellcheck -x --severity=warning $(SCRIPTS)

lint-strict: ## Stricter lint that gates CI: errors only
	shellcheck -x --severity=error $(SCRIPTS)

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

clean: ## Remove test artifacts
	rm -rf tests/test_helper/bats-core tests/test_helper/bats-support tests/test_helper/bats-assert
