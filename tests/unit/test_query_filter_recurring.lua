-- tests/unit/test_query_filter_recurring.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/RecurringField.test.ts

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

T["is recurring: true when 🔁 set"] = function()
  eq(matches("is recurring", pt("- [ ] Task 🔁 every day")), true)
end

T["is recurring: false when no recurrence"] = function()
  eq(matches("is recurring", pt("- [ ] Task")), false)
end

T["is not recurring: inverse of is recurring"] = function()
  eq(matches("is not recurring", pt("- [ ] Task")), true)
  eq(matches("is not recurring", pt("- [ ] Task 🔁 every week")), false)
end

return T
