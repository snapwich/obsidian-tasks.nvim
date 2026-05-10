-- tests/minit.lua
-- Minimal headless nvim init for test runs.
-- Does NOT source user config. Pins plugin paths to repo-local checkouts.
-- Clones mini.nvim to .deps/mini.nvim on first run.

local root = vim.fn.getcwd()
local deps_dir = root .. "/.deps"
local mini_path = deps_dir .. "/mini.nvim"

-- Clone mini.nvim (includes mini.test) if not already present
if not vim.uv.fs_stat(mini_path) then
  vim.notify("obsidian-tasks tests: cloning mini.nvim...", vim.log.levels.INFO)
  local out = vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/echasnovski/mini.nvim",
    mini_path,
  })
  if vim.v.shell_error ~= 0 then
    error("Failed to clone mini.nvim:\n" .. out)
  end
end

-- Prepend deps and plugin root so require() finds them
vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(root)

-- Run tests
dofile(root .. "/tests/runner.lua")
