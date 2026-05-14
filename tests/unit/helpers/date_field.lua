-- tests/unit/helpers/date_field.lua
-- Shared template for per-field date filter parity tests.
--
-- Upstream's tests/Query/Filter/{DueDate,ScheduledDate,...}.test.ts each have
-- their own file mirroring a single field.  Our v1 filter code parameterizes
-- the field, so behavior is shared.  This helper builds a per-field test set
-- that exercises the supported operator matrix (has/no/before/after/on/in/
-- date_invalid) so each per-field test file remains thin while preserving
-- the 1:1 file-name mapping to upstream.
--
-- Usage from a per-field test file:
--   return require("tests.unit.helpers.date_field").make_tests("scheduled", "⏳")
--
-- For DueDateField.test.ts mirror, see tests/unit/test_query_filter_due_date.lua
-- which adds the full operator-edge-case matrix on top of these shared tests.

local M = {}

local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function pt(line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  return t
end

local function matches(filter_line, task)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

--- Build a MiniTest set for the given date field name + emoji.
--- @param field string  field name as used in filter syntax (e.g. "scheduled")
--- @param emoji string  emoji used in task line input (e.g. "⏳")
--- @return table  MiniTest set
function M.make_tests(field, emoji)
  local T = MiniTest.new_set()

  local with_date = string.format("- [ ] Task %s 2024-04-20", emoji)
  local without_date = "- [ ] Task without date"

  T[string.format("has %s date: true when field set", field)] = function()
    eq(matches(string.format("has %s date", field), pt(with_date)), true)
  end

  T[string.format("has %s date: false when no field", field)] = function()
    eq(matches(string.format("has %s date", field), pt(without_date)), false)
  end

  T[string.format("no %s date: true when no field", field)] = function()
    eq(matches(string.format("no %s date", field), pt(without_date)), true)
  end

  T[string.format("no %s date: false when field set", field)] = function()
    eq(matches(string.format("no %s date", field), pt(with_date)), false)
  end

  T[string.format("%s before: matches earlier date", field)] = function()
    eq(matches(string.format("%s before 2024-04-21", field), pt(with_date)), true)
  end

  T[string.format("%s before: false when equal (strict)", field)] = function()
    eq(matches(string.format("%s before 2024-04-20", field), pt(with_date)), false)
  end

  T[string.format("%s before: false when no field", field)] = function()
    eq(matches(string.format("%s before 2024-04-21", field), pt(without_date)), false)
  end

  T[string.format("%s after: matches later date", field)] = function()
    eq(matches(string.format("%s after 2024-04-19", field), pt(with_date)), true)
  end

  T[string.format("%s after: false when equal (strict)", field)] = function()
    eq(matches(string.format("%s after 2024-04-20", field), pt(with_date)), false)
  end

  T[string.format("%s on: matches exact date", field)] = function()
    eq(matches(string.format("%s on 2024-04-20", field), pt(with_date)), true)
  end

  T[string.format("%s on: false when one day off", field)] = function()
    eq(matches(string.format("%s on 2024-04-21", field), pt(with_date)), false)
  end

  T[string.format("%s date is invalid: true for non-ISO value", field)] = function()
    local t = pt(without_date)
    t.fields[field] = "not-a-date"
    local ast = qp.parse(string.format("%s date is invalid", field))
    local pred = filter_mod.compile_all(ast.filters)
    eq(pred(t, "/vault/note.md"), true)
  end

  T[string.format("%s date is invalid: false for valid ISO date", field)] = function()
    eq(matches(string.format("%s date is invalid", field), pt(with_date)), false)
  end

  return T
end

return M
