-- tests/unit/test_query_filter_heading.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/HeadingField.test.ts
--
-- `heading <op> <value>` matches against the nearest ATX heading above the
-- task's source line — `task.heading`, populated by the indexer (a parsed
-- Task carries no file context, so these tests set it directly).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

--- Parse a task line and attach a heading, as the indexer would.
local function task_under(heading)
  local t = assert(parse_task.parse("- [ ] Some task"))
  t.heading = heading
  return t
end

local function matches(line, t)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(t, "/vault/note.md")
end

T["heading includes: matches when the heading contains the value"] = function()
  eq(matches("heading includes Stretch", task_under("Stretch goals")), true)
end

T["heading includes: case-insensitive"] = function()
  eq(matches("heading includes stretch", task_under("Stretch Goals")), true)
end

T["heading includes: false when the heading lacks the value"] = function()
  eq(matches("heading includes Stretch", task_under("Sprint May 2026")), false)
end

T["heading includes: false when the task has no heading"] = function()
  eq(matches("heading includes Stretch", task_under(nil)), false)
end

T["heading does not include: true when the heading lacks the value"] = function()
  eq(matches("heading does not include Stretch", task_under("Sprint May 2026")), true)
end

T["heading does not include: false when the heading contains the value"] = function()
  eq(matches("heading does not include Stretch", task_under("Stretch goals")), false)
end

T["heading does not include: true when the task has no heading"] = function()
  eq(matches("heading does not include Stretch", task_under(nil)), true)
end

T["heading regex matches: anchored pattern"] = function()
  eq(matches("heading regex matches /^Stretch/", task_under("Stretch goals")), true)
  eq(matches("heading regex matches /^Stretch/", task_under("Final Stretch")), false)
end

return T
