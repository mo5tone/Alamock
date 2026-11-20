# Alamock — developer tasks
#
# Run `make` (or `make help`) for the list of targets.
# `make verify` is the same gate CI runs: SwiftLint, the swift-format check and
# the test suite.

SHELL := /bin/bash
.DEFAULT_GOAL := help

SWIFT := swift

.PHONY: help format lint format-check test test-release verify hooks

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

format: ## Rewrite Sources, Tests and Package.swift with swift-format
	./scripts/format.sh fix

format-check: ## Verify the sources are formatted (no changes made)
	./scripts/format.sh check

lint: ## Run SwiftLint --strict and the swift-format check
	./scripts/lint.sh

test: ## Run the test suite in parallel
	$(SWIFT) test --parallel

test-release: ## Run the test suite in release configuration
	$(SWIFT) test -c release --parallel

verify: lint format-check test ## Run everything CI enforces: lint + format check + tests

hooks: ## Install the repository's git hooks (core.hooksPath=.githooks)
	git config core.hooksPath .githooks
	@echo "hooks installed: commit-msg validates Conventional Commits (bypass with git commit --no-verify)"
