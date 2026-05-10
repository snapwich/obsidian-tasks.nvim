-- lua/obsidian-tasks/cmd/refresh.lua
-- :ObsidianTask refresh — clear and re-render all ```tasks blocks in the current buffer.
--
-- Delegates to render.refresh_buffer(bufnr), which:
--   1. Clears all existing extmarks and inserted task lines.
--   2. Re-runs the full query→layout→draw pipeline from scratch.
--
-- Safe to call when no renders are active (no-op: both clear_buffer and
-- render_buffer guard against missing state / no tasks blocks).

local M = {}

--- Run the refresh command.
---
--- @param _args  table  extra arguments (unused)
--- @param _range table  range (unused; refresh always operates on the whole buffer)
function M.run(_args, _range)
  local render = require("obsidian-tasks.render")
  local bufnr = vim.api.nvim_get_current_buf()
  render.refresh_buffer(bufnr)
end

return M
