.PHONY: lint format test test-standalone test-integration test-obsidian ci

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

# Test (standalone): prove the plugin runs with NO plugin deps — only mini.nvim
# + the repo (obsidian.nvim / blink.cmp NOT loaded). Requires ripgrep on PATH.
test-standalone:
	$(NVIM) --headless --noplugin -u tests/minit_standalone.lua

# Test (real plugin, no obsidian): run integration suite WITHOUT obsidian.nvim
# (blink.cmp still loaded for the cmp tests). Requires ripgrep (`rg`) on PATH.
test-integration:
	$(NVIM) --headless --noplugin -u tests/minit_integration.lua

# Test (obsidian integration): isolated suite that DOES load real obsidian.nvim.
# Clones obsidian.nvim to .deps/ on first run. Requires ripgrep (`rg`) on PATH.
test-obsidian:
	$(NVIM) --headless --noplugin -u tests/minit_obsidian.lua

# CI: lint then all test targets
ci: lint test test-standalone test-integration test-obsidian
