-- tests/unit/test_query_filter_scheduled_date.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/ScheduledDateField.test.ts
--
-- All v1 date filters share the same code path (parameterized over field
-- name); see tests/unit/helpers/date_field.lua for the operator matrix
-- (has/no/before/after/on/date_invalid).  Field-specific edge cases — if any
-- emerge — are appended after the shared tests below.

return require("unit.helpers.date_field").make_tests("scheduled", "⏳")
