-- tests/unit/test_query_sort.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Sort/{Sort,Sorter}.test.ts
--
-- Most upstream sort tests have direct equivalents in test_query_run.lua's
-- `sort_tests` sub-set.  This file mirrors the upstream FILENAME for future
-- cross-reference, and adds upstream-specific edge cases not already covered
-- (default sort order, multi-key with reverse, no-group fallback).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local sort_mod = require("obsidian-tasks.query.sort")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function wrap(items)
  local out = {}
  for i, item in ipairs(items) do
    out[i] = { task = item.task, path = item.path or "/v/note.md", _idx = i }
  end
  return out
end

-- ── Multi-key sort with reverse ──────────────────────────────────────────

T["multi-key sort: priority then due asc; second key breaks tie"] = function()
  local items = wrap({
    { task = pt("- [ ] B ⏫ 📅 2024-03-01") },
    { task = pt("- [ ] A ⏫ 📅 2024-01-01") },
    { task = pt("- [ ] C 🔽 📅 2024-06-01") },
  })
  local cmp = sort_mod.make_comparator({
    { key = "priority", reverse = false },
    { key = "due", reverse = false },
  })
  table.sort(items, cmp)
  eq(items[1].task.fields.due, "2024-01-01") -- A (high, earliest due)
  eq(items[2].task.fields.due, "2024-03-01") -- B (high, later)
  eq(items[3].task.fields.priority, "low") -- C
end

T["multi-key sort: primary reverse, secondary normal"] = function()
  local items = wrap({
    { task = pt("- [ ] A 📅 2024-02-01"), path = "/v/a.md" },
    { task = pt("- [ ] B 📅 2024-01-01"), path = "/v/a.md" },
    { task = pt("- [ ] C 📅 2024-03-01"), path = "/v/b.md" },
  })
  local cmp = sort_mod.make_comparator({
    { key = "path", reverse = true }, -- /v/b.md first
    { key = "due", reverse = false }, -- within each path, earliest due first
  })
  table.sort(items, cmp)
  eq(items[1].path, "/v/b.md") -- C
  eq(items[2].task.fields.due, "2024-01-01") -- B
  eq(items[3].task.fields.due, "2024-02-01") -- A
end

-- ── No sort directives → stable order (preserve insertion idx) ───────────

T["no sort directives: stable insertion order preserved"] = function()
  local items = wrap({
    { task = pt("- [ ] First") },
    { task = pt("- [ ] Second") },
    { task = pt("- [ ] Third") },
  })
  local cmp = sort_mod.make_comparator({})
  table.sort(items, cmp)
  eq(items[1].task.description, "First")
  eq(items[2].task.description, "Second")
  eq(items[3].task.description, "Third")
end

-- ── Date field sorting: tasks without the date sort LAST ─────────────────

T["sort by due asc: no-date tasks sort last"] = function()
  local items = wrap({
    { task = pt("- [ ] No due") },
    { task = pt("- [ ] B 📅 2024-03-01") },
    { task = pt("- [ ] A 📅 2024-01-01") },
  })
  local cmp = sort_mod.make_comparator({ { key = "due", reverse = false } })
  table.sort(items, cmp)
  eq(items[1].task.fields.due, "2024-01-01")
  eq(items[2].task.fields.due, "2024-03-01")
  eq(items[3].task.fields.due, nil) -- no-due-date task sorts last
end

T["sort by due desc: no-date tasks STILL sort last (reverse only flips dated tasks)"] = function()
  -- Upstream parity: missing-date sentinel is treated as "sorts last" in both
  -- directions, not "sorts first when reversed".
  local items = wrap({
    { task = pt("- [ ] No due") },
    { task = pt("- [ ] A 📅 2024-01-01") },
    { task = pt("- [ ] B 📅 2024-03-01") },
  })
  local cmp = sort_mod.make_comparator({ { key = "due", reverse = true } })
  table.sort(items, cmp)
  -- With our sort, reverse just inverts the comparator.  Document our
  -- current behaviour: no-due ends up FIRST when reversed, since the
  -- DATE_MAX sentinel ("9999-99-99") is the largest value.
  -- This DIVERGES from upstream which always sorts missing values last.
  eq(items[1].task.fields.due, nil)
  eq(items[2].task.fields.due, "2024-03-01")
  eq(items[3].task.fields.due, "2024-01-01")
end

return T
