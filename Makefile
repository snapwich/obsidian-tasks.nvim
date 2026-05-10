.PHONY: lint format test ci

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

# Test: run mini.test suite in headless nvim (no user config)
test:
	$(NVIM) --headless --noplugin -u tests/minit.lua

# CI: lint then test
ci: lint test
