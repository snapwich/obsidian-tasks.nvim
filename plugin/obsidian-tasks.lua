-- plugin/obsidian-tasks.lua
-- Plugin entry point.
--
-- The :ObsidianTask command is registered by obsidian-tasks.cmd.setup(), which
-- is called from obsidian-tasks.setup().  No stub is registered here — the
-- command only becomes available after the user calls require('obsidian-tasks').setup().

if vim.g.loaded_obsidian_tasks then
  return
end
vim.g.loaded_obsidian_tasks = true
