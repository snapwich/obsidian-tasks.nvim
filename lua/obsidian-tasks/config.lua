-- lua/obsidian-tasks/config.lua
-- Stub: minimal validation scaffold. Replaced in full by T2 (ot-za8r).

local M = {}

--- Default opts. T2 will expand this.
M.defaults = {}

--- Validate and merge opts with defaults.
--- @param opts table User-supplied opts (may be empty).
--- @return table Merged opts table.
function M.validate(opts)
  opts = opts or {}
  return vim.tbl_deep_extend("force", M.defaults, opts)
end

return M
