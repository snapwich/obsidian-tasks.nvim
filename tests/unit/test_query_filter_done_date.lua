-- tests/unit/test_query_filter_done_date.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/DoneDateField.test.ts
-- See tests/unit/helpers/date_field.lua for the shared operator matrix.

return require("unit.helpers.date_field").make_tests("done", "✅")
