-- lua/obsidian-tasks/cmd/start.lua
-- :ObsidianTask start [DATE] — set/overwrite the start date on task(s).
-- Shared logic lives in cmd/_date_field.lua.

return require("obsidian-tasks.cmd._date_field").make("start")
