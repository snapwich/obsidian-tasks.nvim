-- tests/unit/test_query_filter_created_date.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/CreatedDateField.test.ts
-- See tests/unit/helpers/date_field.lua for the shared operator matrix.

return require("unit.helpers.date_field").make_tests("created", "➕")
