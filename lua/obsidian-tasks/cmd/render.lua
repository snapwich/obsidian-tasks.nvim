-- lua/obsidian-tasks/cmd/render.lua
-- :ObsidianTask render — trigger a manual render of the current buffer.
--
-- Used when opts.auto_render = false (manual-render mode).  Delegates to
-- render.render_buffer(bufnr, workspace), which runs the full
-- query→layout→draw pipeline for every ```tasks block in the buffer.
--
-- workspace is resolved via util.obsidian.workspace_for_path (same pattern as
-- autocmds.lua safe_workspace_for_path).  If obsidian.nvim is not yet ready or
-- the buffer is not under any workspace the call still proceeds with workspace=nil,
-- which means lazy index-init is skipped (results may be empty on first render
-- until the index is populated by another path, e.g. BufReadPost on auto_render=true).
--
-- Safe to call on buffers with no ```tasks blocks (no-op).

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

--- Run the render command.
---
--- @param _args  table  extra arguments (unused)
--- @param _range table  range (unused; render always operates on the whole buffer)
function M.run(_args, _range)
  local render = require("obsidian-tasks.render")
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ws = safe_workspace_for_path(path)
  render.render_buffer(bufnr, ws)
end

return M
