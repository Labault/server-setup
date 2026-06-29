# Managed by bootstrap (shell profile). Standard quality targets.
# Tools come from your machine (mac-setup), never from here.
.DEFAULT_GOAL := help

# Project-local targets: drop them in an (optional, unmanaged) Makefile.local.
# Bootstrap never touches that file, so your custom targets survive re-apply.
-include Makefile.local

.PHONY: help qa lint fix test fmt hooks

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

qa: lint test ## Run all quality checks (lint + test)

lint: ## Run every pre-commit hook + a shell formatting check
	pre-commit run --all-files
	shfmt -d .

fix: ## Re-run hooks applying auto-fixes + format shell scripts in place
	pre-commit run --all-files || true
	shfmt -w .

fmt: ## Format shell scripts in place (shfmt)
	shfmt -w .

test: ## Run the bats test suite
	bats tests/

hooks: ## Install git hooks (pre-commit + commit-msg)
	pre-commit install
	pre-commit install --hook-type commit-msg
