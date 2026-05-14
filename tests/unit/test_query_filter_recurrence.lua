-- tests/unit/test_query_filter_recurrence.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/RecurrenceField.test.ts
--
-- `recurrence includes <text>` matches against the raw recurrence string
-- preserved on the task.

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

T["recurrence includes: matches substring of recurrence string"] = function()
  eq(matches("recurrence includes week", pt("- [ ] Task 🔁 every week")), true)
end

T["recurrence includes: false when substring absent"] = function()
  eq(matches("recurrence includes month", pt("- [ ] Task 🔁 every day")), false)
end

T["recurrence includes: false when task has no recurrence"] = function()
  eq(matches("recurrence includes week", pt("- [ ] Task without recurrence")), false)
end

T["recurrence does not include: inverse"] = function()
  eq(matches("recurrence does not include month", pt("- [ ] Task 🔁 every week")), true)
  eq(matches("recurrence does not include week", pt("- [ ] Task 🔁 every week")), false)
end

return T
