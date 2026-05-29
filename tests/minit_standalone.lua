-- tests/minit_standalone.lua
-- Headless bootstrap for the STANDALONE suite: proves obsidian-tasks runs with
-- NO Neovim-plugin dependencies — only mini.nvim (the test framework) and the
-- repo itself are on the runtimepath. obsidian.nvim and blink.cmp are
-- deliberately NOT cloned or loaded, so vault detection and scanning must rely
-- entirely on the native `.obsidian/` marker + ripgrep path.
--
-- External dependency: ripgrep (`rg`) on PATH — the plugin's only hard system
-- requirement.

-- nvim's bundled ftplugin/markdown.lua calls vim.treesitter.start(); CI runners
-- have no parsers installed so it asserts. Swallow that so bufload of .md files
-- doesn't blow up the test.
do
  local orig = vim.treesitter.start
  vim.treesitter.start = function(...)
    pcall(orig, ...)
  end
end

local root = vim.fn.getcwd()
local deps_dir = root .. "/.deps"
local mini_path = deps_dir .. "/mini.nvim"

if not vim.uv.fs_stat(mini_path) then
  vim.notify("obsidian-tasks standalone: cloning mini.nvim...", vim.log.levels.INFO)
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

-- Only mini.nvim + the repo. No obsidian.nvim, no blink.cmp.
vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(root)

-- Set up obsidian-tasks with no obsidian.nvim present. setup() must not require
-- it; the checkbox bridge simply no-ops.
require("obsidian-tasks").setup({
  global_filter = "#task",
})

dofile(root .. "/tests/runner_standalone.lua")
