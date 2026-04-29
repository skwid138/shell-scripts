# ~/code/scripts/Makefile
# Test runner and lint for shell scripts

BATS := ./tests/test_helper/bats-core/bin/bats
TESTS := tests/*.bats
SCRIPTS := $(wildcard *.sh) $(wildcard lib/*.sh)

.PHONY: test install-bats lint clean help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

install-bats: ## Install bats test framework (git submodules)
	@if [ ! -f $(BATS) ]; then \
		echo "Installing bats-core..."; \
		git submodule add -f https://github.com/bats-core/bats-core.git tests/test_helper/bats-core 2>/dev/null || true; \
		git submodule add -f https://github.com/bats-core/bats-support.git tests/test_helper/bats-support 2>/dev/null || true; \
		git submodule add -f https://github.com/bats-core/bats-assert.git tests/test_helper/bats-assert 2>/dev/null || true; \
		git submodule update --init --recursive tests/test_helper; \
	fi

test: install-bats ## Run all bats tests
	$(BATS) $(TESTS)

lint: ## Run shellcheck on all scripts
	shellcheck -x $(SCRIPTS)

clean: ## Remove test artifacts
	rm -rf tests/test_helper/bats-core tests/test_helper/bats-support tests/test_helper/bats-assert
