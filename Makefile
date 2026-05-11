.PHONY: lint format test test-integration ci

NVIM    ?= nvim
SELENE  ?= selene
STYLUA  ?= stylua

# Lint: selene static analysis + stylua format check
lint:
	$(SELENE) lua/ plugin/
	$(STYLUA) --check lua/ plugin/ tests/

# Format: apply stylua formatting in-place
format:
	$(STYLUA) lua/ plugin/ tests/

# Test: run mini.test unit + stubbed-integration suite in headless nvim
test:
	$(NVIM) --headless --noplugin -u tests/minit.lua

# Test (real plugins): run integration suite with real obsidian.nvim loaded.
# Clones obsidian.nvim to .deps/ on first run. Requires ripgrep (`rg`) on PATH.
test-integration:
	$(NVIM) --headless --noplugin -u tests/minit_integration.lua

# CI: lint then both test targets
ci: lint test test-integration
