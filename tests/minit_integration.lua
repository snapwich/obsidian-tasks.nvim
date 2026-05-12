-- tests/minit_integration.lua
-- Headless bootstrap for the "real-plugin" integration suite.
--
-- Differences from tests/minit.lua:
--   • Clones obsidian.nvim to .deps/ alongside mini.nvim.
--   • Sets up real obsidian.nvim against tests/fixtures/vault.
--   • Sets up obsidian-tasks against that vault.
--   • Sources tests/runner_integration.lua (which globs integration_real/).
--
-- This suite intentionally does NOT stub Obsidian / obsidian.*; it loads them
-- for real so load-order / ftplugin / autocmd-ordering bugs are observable.
--
-- External dependency: ripgrep (`rg`) on PATH — required by
-- obsidian.search.find_async / search_async.

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
local blink_path = deps_dir .. "/blink.cmp"

local function clone(url, dest, label, ref)
  vim.notify("obsidian-tasks integration: cloning " .. label .. "...", vim.log.levels.INFO)
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
if not vim.uv.fs_stat(blink_path) then
  -- Pin to v1.x latest; v2 HEAD requires nvim 0.12+ and a separate blink.lib dep.
  -- See lua/obsidian-tasks/cmp/source.lua header for the supported blink range.
  clone("https://github.com/Saghen/blink.cmp", blink_path, "blink.cmp", "v1.10.2")
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(obsidian_path)
vim.opt.rtp:prepend(blink_path)
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

-- ── Set up real blink.cmp with our provider registered ──────────────────────
-- fuzzy.implementation = "lua" avoids the Rust binary download path that
-- otherwise fails in offline / headless CI.

require("blink.cmp").setup({
  fuzzy = { implementation = "lua" },
  sources = {
    default = { "obsidian-tasks" },
    providers = {
      ["obsidian-tasks"] = {
        module = "obsidian-tasks.cmp.source",
        name = "ObsidianTasks",
      },
    },
  },
})

-- ── Run integration_real/test_*.lua ──────────────────────────────────────────

dofile(root .. "/tests/runner_integration.lua")
