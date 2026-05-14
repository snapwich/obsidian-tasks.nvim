-- tests/unit/test_query_filter_exclude_sub_items.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/ExcludeSubItemsField.test.ts
--
-- `exclude sub-items` keeps only top-level tasks (no leading indent).
-- Indented tasks (sub-items in markdown lists) are filtered out.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(line, task)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

T["exclude sub-items: matches top-level task (no indent)"] = function()
  eq(matches("exclude sub-items", pt("- [ ] Top level")), true)
end

T["exclude sub-items: rejects two-space indented task"] = function()
  eq(matches("exclude sub-items", pt("  - [ ] Indented")), false)
end

T["exclude sub-items: rejects four-space indented task"] = function()
  eq(matches("exclude sub-items", pt("    - [ ] Doubly indented")), false)
end

T["exclude sub-items: rejects tab-indented task"] = function()
  eq(matches("exclude sub-items", pt("\t- [ ] Tab indented")), false)
end

return T
