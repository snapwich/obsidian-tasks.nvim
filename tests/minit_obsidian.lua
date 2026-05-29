-- tests/minit_obsidian.lua
-- Headless bootstrap for the isolated optional-obsidian.nvim-integration suite.
--
-- Unlike tests/minit_integration.lua (which proves the plugin runs WITHOUT
-- obsidian.nvim), this suite DOES load real obsidian.nvim against the fixture
-- vault. It covers the genuinely obsidian.nvim-specific behaviors: the `Obsidian`
-- global, the <CR> smart_action coexistence, and the checkbox-symbol bridge.
--
-- blink.cmp is NOT needed here.
--
-- External dependency: ripgrep (`rg`) on PATH.

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
local obsidian_path = deps_dir .. "/obsidian.nvim"

local function clone(url, dest, label, ref)
  vim.notify("obsidian-tasks obsidian-suite: cloning " .. label .. "...", vim.log.levels.INFO)
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", url, dest })
  if vim.v.shell_error ~= 0 then
    error("Failed to clone " .. label .. ":\n" .. out)
  end
  if ref then
    out = vim.fn.system({ "git", "-C", dest, "checkout", "--quiet", ref })
    if vim.v.shell_error ~= 0 then
      error("Failed to checkout " .. ref .. " in " .. label .. ":\n" .. out)
    end
  end
end

if not vim.uv.fs_stat(mini_path) then
  clone("https://github.com/echasnovski/mini.nvim", mini_path, "mini.nvim")
end
if not vim.uv.fs_stat(obsidian_path) then
  clone("https://github.com/obsidian-nvim/obsidian.nvim", obsidian_path, "obsidian.nvim")
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(obsidian_path)
vim.opt.rtp:prepend(root)

-- ── Set up real obsidian.nvim against the fixture vault ──────────────────────

local fixture_vault = root .. "/tests/fixtures/vault"

require("obsidian").setup({
  workspaces = {
    { name = "test-vault", path = fixture_vault },
  },
  log_level = vim.log.levels.ERROR,
  -- Keep features minimal — we only need core API + ftplugin keymaps.
  completion = { nvim_cmp = false, blink = false },
  picker = { name = nil },
  ui = { enable = false },
})

-- ── Set up obsidian-tasks ────────────────────────────────────────────────────

require("obsidian-tasks").setup({
  global_filter = "#task",
})

-- ── Run integration_obsidian/test_*.lua ──────────────────────────────────────

dofile(root .. "/tests/runner_obsidian.lua")
