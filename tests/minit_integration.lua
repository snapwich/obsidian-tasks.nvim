-- tests/minit_integration.lua
-- Headless bootstrap for the "real-plugin" integration suite.
--
-- This suite runs WITHOUT obsidian.nvim — it proves the full render / edit /
-- sentinel / insert behavior works while obsidian.nvim is absent (the plugin is
-- standalone). blink.cmp IS loaded because the cmp tests exercise it as the
-- optional completion integration. Vault detection here is native (the fixture
-- vault carries a `.obsidian/` marker) and content scanning uses ripgrep.
--
-- Differences from tests/minit.lua:
--   • Clones blink.cmp to .deps/ alongside mini.nvim.
--   • Sets up obsidian-tasks against the fixture vault.
--   • Sources tests/runner_integration.lua (which globs integration_real/).
--
-- The obsidian.nvim-integration validations live in the separate
-- `make test-obsidian` suite (tests/minit_obsidian.lua) so this suite stays free
-- of any obsidian.nvim load.
--
-- External dependency: ripgrep (`rg`) on PATH — the plugin's only hard system
-- requirement (used by the native content scan).

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
if not vim.uv.fs_stat(blink_path) then
  -- Pin to v1.x latest; v2 HEAD requires nvim 0.12+ and a separate blink.lib dep.
  -- See lua/obsidian-tasks/cmp/source.lua header for the supported blink range.
  clone("https://github.com/Saghen/blink.cmp", blink_path, "blink.cmp", "v1.10.2")
end

vim.opt.rtp:prepend(mini_path)
vim.opt.rtp:prepend(blink_path)
vim.opt.rtp:prepend(root)

-- ── Set up obsidian-tasks (no obsidian.nvim present) ─────────────────────────

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
