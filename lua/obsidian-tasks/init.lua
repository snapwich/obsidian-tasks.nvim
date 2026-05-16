-- lua/obsidian-tasks/init.lua
-- Public API. setup() is the single entry point.

local M = {}

--- Merged opts stored after setup(). Available as obsidian-tasks.opts.
M.opts = {}

--- Register default highlight groups.  `default = true` lets user colorschemes
--- win — call this in setup AND on ColorScheme (some colorschemes nuke user
--- highlights on reload).
local function register_default_hls()
  vim.api.nvim_set_hl(0, "ObsidianTasksLinger", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ObsidianTasksFieldInvalid", { link = "DiagnosticUnderlineError", default = true })
end

--- Bootstrap the plugin.
--- @param opts table? User configuration (see config.lua for schema).
function M.setup(opts)
  opts = opts or {}
  local config = require("obsidian-tasks.config")
  M.opts = config.merge(opts)
  register_default_hls()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("obsidian_tasks_highlights", { clear = true }),
    callback = register_default_hls,
  })
  -- Merge user status overrides so toggle/done/cancel respect custom statuses.
  local status_mod = require("obsidian-tasks.task.status")
  status_mod.merge(M.opts.statuses)
  -- Bridge obsidian.nvim's checkbox.order so symbols it cycles through (e.g.
  -- ~, !, > in the default { " ", "~", "!", ">", "x" }) are accepted by our
  -- status-edit detector instead of getting reverted as foreign edits.
  -- If obsidian.nvim sets up AFTER us, we re-bridge on its workspace event.
  status_mod.bridge_obsidian_checkbox_order()
  vim.api.nvim_create_autocmd("User", {
    pattern = "ObsidianWorkpspaceSet", -- typo intentional (matches obsidian.nvim)
    callback = function()
      status_mod.bridge_obsidian_checkbox_order()
    end,
  })
  -- Propagate opts to the render orchestrator (default_folded, etc.).
  require("obsidian-tasks.render").configure(M.opts)
  -- Wire autocmds (BufReadPost / FocusGained / BufWritePost / BufDelete).
  require("obsidian-tasks.autocmds").setup(M.opts)
  -- Register :ObsidianTask dispatcher (replaces plugin/ stub).
  require("obsidian-tasks.cmd").setup()
end

return M
