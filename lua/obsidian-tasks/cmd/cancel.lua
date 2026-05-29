-- lua/obsidian-tasks/cmd/cancel.lua
-- :ObsidianTask cancel — mark the task(s) at cursor / in range as Cancelled ('-'),
-- stamping the cancelled date when unset (idempotent).
-- Shared logic lives in cmd/_status_field.lua.

return require("obsidian-tasks.cmd._status_field").make({
  name = "cancel",
  symbol = "-",
  date_field = "cancelled",
})
