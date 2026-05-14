-- tests/unit/test_query_filter_status_type.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/StatusTypeField.test.ts
--
-- `status.type is <TYPE>` matches tasks whose status entry type equals the
-- given enum string.  Types are upper-case enum strings:
--   TODO | DONE | IN_PROGRESS | CANCELLED | ON_HOLD | NON_TASK | EMPTY
--
-- KNOWN GAP vs upstream: `group by status.type` is not yet supported (we
-- only have `group by status`).  Tracked for Bucket B / Phase 2.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(filter_line, task)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

T["status.type is TODO: matches [ ]"] = function()
  eq(matches("status.type is TODO", pt("- [ ] Task")), true)
end

T["status.type is DONE: matches [x]"] = function()
  eq(matches("status.type is DONE", pt("- [x] Task ✅ 2024-01-10")), true)
end

T["status.type is IN_PROGRESS: matches [/]"] = function()
  eq(matches("status.type is IN_PROGRESS", pt("- [/] Task")), true)
end

T["status.type is CANCELLED: matches [-]"] = function()
  eq(matches("status.type is CANCELLED", pt("- [-] Task")), true)
end

T["status.type is ON_HOLD: matches [h]"] = function()
  eq(matches("status.type is ON_HOLD", pt("- [h] Task")), true)
end

T["status.type is TODO: false for [x]"] = function()
  eq(matches("status.type is TODO", pt("- [x] Task ✅ 2024-01-10")), false)
end

T["status.type is todo: query lowercase is normalised to TODO"] = function()
  eq(matches("status.type is todo", pt("- [ ] Task")), true)
end

return T
