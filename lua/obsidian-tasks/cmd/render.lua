-- lua/obsidian-tasks/cmd/render.lua
-- :ObsidianTask render — trigger a manual render of the current buffer.
--
-- Used when opts.auto_render = false (manual-render mode).  Delegates to
-- render.render_buffer(bufnr), which runs the full query→layout→draw pipeline
-- for every ```tasks block in the buffer.
--
-- Safe to call on buffers with no ```tasks blocks (no-op).

local M = {}

--- Run the render command.
---
--- @param _args  table  extra arguments (unused)
--- @param _range table  range (unused; render always operates on the whole buffer)
function M.run(_args, _range)
  local render = require("obsidian-tasks.render")
  local bufnr = vim.api.nvim_get_current_buf()
  render.render_buffer(bufnr)
end

return M
