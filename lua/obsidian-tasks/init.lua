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
  -- Merge user status overrides so toggle/done/cancel respect custom statuses.
  require("obsidian-tasks.task.status").merge(M.opts.statuses)
  -- Propagate opts to the render orchestrator (default_folded, etc.).
  require("obsidian-tasks.render").configure(M.opts)
  -- Wire autocmds (BufReadPost / FocusGained / BufWritePost / BufDelete).
  require("obsidian-tasks.autocmds").setup(M.opts)
  -- Register :ObsidianTask dispatcher (replaces plugin/ stub).
  require("obsidian-tasks.cmd").setup()
  -- Start per-workspace libuv file watcher (opt-out via opts.watcher = false).
  if M.opts.watcher then
    require("obsidian-tasks.index.watch").setup()
  end
end

return M
