-- lua/obsidian-tasks/cmd/toggle.lua
-- :ObsidianTask toggle — cycle the status of the task(s) at cursor / in range.
-- Cycles via task.status.next() (respects user-merged status overrides).
-- Shared logic lives in cmd/_status_field.lua.

return require("obsidian-tasks.cmd._status_field").make({
  name = "toggle",
  cycle = true,
  on_completion_delete = true,
})
