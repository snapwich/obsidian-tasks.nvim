-- tests/unit/test_query_filter_cancelled_date.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/CancelledDateField.test.ts
-- See tests/unit/helpers/date_field.lua for the shared operator matrix.
--
-- The cancelled-date emoji is ❌ (set when a task is cancelled via
-- :ObsidianTask cancel).  It is NOT the same as the on-completion 🏁 emoji.

return require("unit.helpers.date_field").make_tests("cancelled", "❌")
