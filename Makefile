# ~/code/scripts/Makefile
# Test runner and lint for shell scripts

BATS := ./tests/test_helper/bats-core/bin/bats
TESTS := tests/*.bats
SCRIPTS := $(wildcard shell/*.sh) $(wildcard agent/*.sh) $(wildcard lib/*.sh)

.PHONY: test install-bats lint clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install-bats: ## Initialize bats test framework submodules
	@if [ ! -f $(BATS) ]; then \
		echo "Initializing bats submodules..."; \
		git submodule update --init --recursive tests/test_helper; \
	fi

test: install-bats ## Run all bats tests
	$(BATS) $(TESTS)

lint: ## Run shellcheck (severity warning+; for CI use lint-strict)
	shellcheck -x --severity=warning $(SCRIPTS)

lint-strict: ## Stricter lint that gates CI: errors only
	shellcheck -x --severity=error $(SCRIPTS)

clean: ## Remove test artifacts
	rm -rf tests/test_helper/bats-core tests/test_helper/bats-support tests/test_helper/bats-assert
