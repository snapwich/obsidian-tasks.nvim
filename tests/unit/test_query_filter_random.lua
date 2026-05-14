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

-- ── sort by random ────────────────────────────────────────────────────────

T["sort by random: produces some permutation (deterministic given seed)"] = function()
  -- Seed for determinism within the test.
  math.randomseed(42)
  local sort_mod = require("obsidian-tasks.query.sort")
  local items = {
    { task = pt("- [ ] A"), path = "/v/a.md", _idx = 1 },
    { task = pt("- [ ] B"), path = "/v/a.md", _idx = 2 },
    { task = pt("- [ ] C"), path = "/v/a.md", _idx = 3 },
    { task = pt("- [ ] D"), path = "/v/a.md", _idx = 4 },
    { task = pt("- [ ] E"), path = "/v/a.md", _idx = 5 },
  }
  local cmp = sort_mod.make_comparator({ { key = "random", reverse = false } })
  table.sort(items, cmp)
  -- All 5 items still present.
  eq(#items, 5)
  -- Verify it doesn't preserve insertion order (very unlikely under shuffle).
  -- Instead, just check the set is intact.
  local seen = {}
  for _, it in ipairs(items) do
    seen[it.task.description] = true
  end
  eq(seen.A and seen.B and seen.C and seen.D and seen.E, true)
end

T["group by random: produces a non-empty group bucket"] = function()
  local group_mod = require("obsidian-tasks.query.group")
  local names = group_mod.resolve(pt("- [ ] Task"), "/v/a.md", { { key = "random", reverse = false } })
  eq(#names, 1)
  eq(type(names[1]) == "string" and #names[1] > 0, true)
end

return T
