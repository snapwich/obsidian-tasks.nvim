-- tests/unit/test_query_filter_happens_date.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/HappensDateField.test.ts
--
-- `happens` is a synthetic field: the EARLIEST of due / scheduled / start.
-- It does not appear on the task line directly — the filter derives it from
-- the other three date fields.
--
-- KNOWN GAPS vs upstream (tracked for Bucket B / Phase 2):
--   • `happens on or before/after` — operator parity (Bucket B item 8)
--   • Period shortcuts — Bucket B item 9

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

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

-- ── has / no happens date ─────────────────────────────────────────────────

T["has happens date: true when ANY of due/scheduled/start is set"] = function()
  eq(matches("has happens date", pt("- [ ] Task 📅 2024-04-20")), true)
  eq(matches("has happens date", pt("- [ ] Task ⏳ 2024-04-20")), true)
  eq(matches("has happens date", pt("- [ ] Task 🛫 2024-04-20")), true)
end

T["has happens date: false when none of due/scheduled/start is set"] = function()
  eq(matches("has happens date", pt("- [ ] Task")), false)
end

T["no happens date: true when none of due/scheduled/start is set"] = function()
  eq(matches("no happens date", pt("- [ ] Task")), true)
end

T["no happens date: false when at least one is set"] = function()
  eq(matches("no happens date", pt("- [ ] Task 📅 2024-04-20")), false)
end

-- ── happens before / after / on uses the EARLIEST of the three ───────────

T["happens before: uses earliest of due/scheduled/start"] = function()
  -- start is 2024-03-01 (earliest), due is 2024-05-01.  happens = 2024-03-01.
  local t = pt("- [ ] Task 🛫 2024-03-01 📅 2024-05-01")
  eq(matches("happens before 2024-04-01", t), true)
  eq(matches("happens before 2024-03-01", t), false) -- strict
  eq(matches("happens after 2024-02-28", t), true)
  eq(matches("happens on 2024-03-01", t), true)
end

T["happens before: when only scheduled is set, uses scheduled"] = function()
  local t = pt("- [ ] Task ⏳ 2024-04-15")
  eq(matches("happens before 2024-04-16", t), true)
  eq(matches("happens on 2024-04-15", t), true)
end

T["happens before: when no date fields, filter-fails"] = function()
  eq(matches("happens before 2099-01-01", pt("- [ ] Task with no dates")), false)
end

T["happens: picks earliest even when all three are set"] = function()
  -- scheduled (2024-02-01) is the earliest among due/scheduled/start.
  local t = pt("- [ ] Task 📅 2024-05-01 ⏳ 2024-02-01 🛫 2024-03-15")
  eq(matches("happens on 2024-02-01", t), true)
  eq(matches("happens on 2024-03-15", t), false)
end

return T
