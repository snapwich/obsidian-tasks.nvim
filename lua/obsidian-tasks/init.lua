-- lua/obsidian-tasks/init.lua
-- Public API. setup() is the single entry point.

local M = {}

--- Merged opts stored after setup(). Available as obsidian-tasks.opts.
M.opts = {}

--- Bootstrap the plugin.
--- @param opts table? User configuration (see config.lua for schema).
function M.setup(opts)
  opts = opts or {}
  local config = require("obsidian-tasks.config")
  M.opts = config.merge(opts)
end

return M
