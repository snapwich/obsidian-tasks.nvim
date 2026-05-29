-- lua/obsidian-tasks/cmd/done.lua
-- :ObsidianTask done — mark the task(s) at cursor / in range as Done ('x'),
-- stamping the done date when unset (idempotent).
-- Shared logic lives in cmd/_status_field.lua.

return require("obsidian-tasks.cmd._status_field").make({
  name = "done",
  symbol = "x",
  date_field = "done",
  on_completion_delete = true,
})
