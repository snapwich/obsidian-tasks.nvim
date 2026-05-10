-- lua/obsidian-tasks/util/extmark.lua
-- Shared extmark namespace for obsidian-tasks.nvim.
-- All modules that write extmarks MUST use this namespace to avoid
-- stomping on obsidian.nvim or render-markdown.nvim extmarks.

local M = {}

--- Unique extmark namespace for the entire plugin.
--- Declared once here and imported wherever extmarks are set.
M.NS = vim.api.nvim_create_namespace("obsidian_tasks")

return M
