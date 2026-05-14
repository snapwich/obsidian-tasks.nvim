-- tests/unit/test_query_filter_status_name.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/StatusNameField.test.ts
--
-- `status.name is <name>` matches tasks whose status entry name equals the
-- given value.  Case-sensitive (preserves user-typed case in queries).
--
-- KNOWN GAP vs upstream: `group by status.name` is not yet supported (we
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

T["status.name is Todo: matches [ ]"] = function()
  eq(matches("status.name is Todo", pt("- [ ] Task")), true)
end

T["status.name is Done: matches [x]"] = function()
  eq(matches("status.name is Done", pt("- [x] Task ✅ 2024-01-10")), true)
end

T["status.name is In Progress: matches [/]"] = function()
  eq(matches("status.name is In Progress", pt("- [/] Task")), true)
end

T["status.name is Cancelled: matches [-]"] = function()
  eq(matches("status.name is Cancelled", pt("- [-] Task")), true)
end

T["status.name is On Hold: matches [h]"] = function()
  eq(matches("status.name is On Hold", pt("- [h] Task")), true)
end

T["status.name is Done: does NOT match [ ]"] = function()
  eq(matches("status.name is Done", pt("- [ ] Task")), false)
end

T["status.name is X: false for unknown name"] = function()
  eq(matches("status.name is Nonexistent", pt("- [ ] Task")), false)
end

T["status.name preserves case from filter query"] = function()
  -- Parity: status names are case-sensitive in filter comparison.
  eq(matches("status.name is Todo", pt("- [ ] Task")), true)
  eq(matches("status.name is todo", pt("- [ ] Task")), false)
end

return T
