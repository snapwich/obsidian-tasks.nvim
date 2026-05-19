-- lua/obsidian-tasks/cmd/scheduled.lua
-- :ObsidianTask scheduled [DATE] — set/overwrite the scheduled date on task(s).
-- Shared logic lives in cmd/_date_field.lua.

return require("obsidian-tasks.cmd._date_field").make("scheduled")
