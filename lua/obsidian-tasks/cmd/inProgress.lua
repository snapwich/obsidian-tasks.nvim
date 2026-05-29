-- lua/obsidian-tasks/cmd/inProgress.lua
-- :ObsidianTask inProgress — mark the task(s) at cursor / in range as In Progress ('/').
-- No date stamp.  Shared logic lives in cmd/_status_field.lua.

return require("obsidian-tasks.cmd._status_field").make({
  name = "inProgress",
  symbol = "/",
})
