-- lua/obsidian-tasks/cmd/onHold.lua
-- :ObsidianTask onHold — mark the task(s) at cursor / in range as On Hold ('h').
-- No date stamp.  Shared logic lives in cmd/_status_field.lua.

return require("obsidian-tasks.cmd._status_field").make({
  name = "onHold",
  symbol = "h",
})
