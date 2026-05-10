-- lua/obsidian-tasks/cmd/refresh.lua
-- :ObsidianTask refresh — clear and re-render all ```tasks blocks in the current buffer.
--
-- Delegates to render.refresh_buffer(bufnr, workspace), which:
--   1. Clears all existing extmarks and inserted task lines.
--   2. Re-runs the full query→layout→draw pipeline from scratch.
--
-- workspace is resolved via util.obsidian.workspace_for_path (same pattern as
-- autocmds.lua safe_workspace_for_path) so the lazy index-init in render/init.lua
-- can fire correctly.  workspace=nil is safe: the render still runs but the
-- lazy-init guard (gated on workspace != nil) is skipped.
--
-- Safe to call when no renders are active (no-op via clear_buffer + render_buffer
-- both guarding against missing state / no tasks blocks).

local M = {}

--- Resolve the obsidian.nvim workspace that owns *path*.
--- Returns nil on any error (obsidian not yet set up, path outside all vaults).
--- @param path string
--- @return table|nil
local function safe_workspace_for_path(path)
  local ok, result = pcall(function()
    return require("obsidian-tasks.util.obsidian").workspace_for_path(path)
  end)
  return ok and result or nil
end

--- Run the refresh command.
---
--- @param _args  table  extra arguments (unused)
--- @param _range table  range (unused; refresh always operates on the whole buffer)
function M.run(_args, _range)
  local render = require("obsidian-tasks.render")
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ws = safe_workspace_for_path(path)
  render.refresh_buffer(bufnr, ws)
end

return M
