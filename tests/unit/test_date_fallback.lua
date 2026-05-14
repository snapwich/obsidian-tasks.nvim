-- tests/unit/test_date_fallback.lua
-- Parity with .deps/obsidian-tasks/tests/DateTime/DateFallback.test.ts
--
-- When opts.use_filename_as_scheduled_date is true, tasks parsed from files
-- whose basename contains a YYYY-MM-DD date inherit that date as their
-- scheduled date (only when the task has none of its own).
--
-- Gated by config flag; mirrors upstream's `useFilenameAsScheduledDate`
-- (off by default).
--
-- The integration with index parse_file is tested in
-- tests/integration_real/ (real obsidian.nvim required for refresh_file).
-- This file tests the date_from_basename helper unit-style.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local index = require("obsidian-tasks.index")

T["date_from_basename: pure YYYY-MM-DD.md"] = function()
  eq(index._date_from_basename("/vault/2024-03-15.md"), "2024-03-15")
end

T["date_from_basename: prefix-YYYY-MM-DD.md"] = function()
  eq(index._date_from_basename("/vault/daily-2024-03-15.md"), "2024-03-15")
end

T["date_from_basename: YYYY-MM-DD-suffix.md"] = function()
  eq(index._date_from_basename("/vault/2024-03-15-meeting.md"), "2024-03-15")
end

T["date_from_basename: filename without date pattern → nil"] = function()
  eq(index._date_from_basename("/vault/daily-notes.md"), nil)
end

T["date_from_basename: invalid month rejected"] = function()
  eq(index._date_from_basename("/vault/2024-13-01.md"), nil)
end

T["date_from_basename: invalid day rejected"] = function()
  eq(index._date_from_basename("/vault/2024-03-32.md"), nil)
end

T["date_from_basename: nested-directory path with date filename"] = function()
  eq(index._date_from_basename("/vault/daily-notes/2024-03-15.md"), "2024-03-15")
end

T["date_from_basename: file without .md extension still works"] = function()
  eq(index._date_from_basename("/vault/2024-03-15"), "2024-03-15")
end

return T
