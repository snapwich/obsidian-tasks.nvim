-- tests/unit/test_query_filter_random.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/RandomField.test.ts
--
-- v1: `random` as a FILTER is a pass-through (matches everything).
-- KNOWN GAPS vs upstream — both tracked for Bucket B / Phase 2:
--   • `sort by random` (shuffle)
--   • `group by random` (randomized buckets)

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

T["random: passes any task (filter never excludes)"] = function()
  eq(matches("random", pt("- [ ] Task")), true)
  eq(matches("random", pt("- [x] Task ✅ 2024-01-10")), true)
  eq(matches("random", pt("  - [ ] Sub-task #work 📅 2024-04-01")), true)
end

return T
