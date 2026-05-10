-- lua/obsidian-tasks/task/recurrence.lua
-- v1: recurrence is opaque text — preserve only.
-- v2: full rrule computation (see next_occurrence stub below).

local M = {}

--- Return the raw recurrence string verbatim.
--- v1 contract: recurrence is opaque text; no parsing or transformation.
--- @param raw_string string
--- @return string
function M.preserve(raw_string)
  return raw_string
end

-- v2 design intent:
--  - Parse rrule via a Lua port (e.g., bring in lua-rrule, or implement a minimal subset)
--  - Honor `when done` semantics: base_on_today flag from raw string suffix
--  - Local-tz arithmetic via os.date; consider DST edge cases
--  - Return new Task with date fields advanced; preserve other fields

--- Compute the next occurrence of a recurring task.
--- NOT implemented in v1 — raises an error with a clear version message.
--- @param _task table  Task table (as returned by parse.parse)
--- @param _base_date string|nil  ISO date string to base recurrence on (defaults to today)
--- @return table  New Task with advanced date fields
function M.next_occurrence(_task, _base_date)
  error("obsidian-tasks: recurrence.next_occurrence is a v2 feature; not implemented in v1")
end

return M
