-- lua/obsidian-tasks/cmd/due.lua
-- :ObsidianTask due [DATE] — set/overwrite the due date on task(s) at cursor / in range.
-- Shared logic lives in cmd/_date_field.lua.

return require("obsidian-tasks.cmd._date_field").make("due")
