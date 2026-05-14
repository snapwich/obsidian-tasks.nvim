-- tests/unit/test_query_filter_status.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/StatusField.test.ts
--
-- Tests the `done` and `not done` filters against the full status-type matrix
-- (TODO / DONE / IN_PROGRESS / CANCELLED / ON_HOLD), and sort/group by status.
--
-- Parity status:
--   • `done` / `not done` filters: ALIGNED with upstream (CANCELLED, DONE,
--     NON_TASK, and any custom non-pending types all match `done`; TODO,
--     IN_PROGRESS, ON_HOLD match `not done`).
--
-- KNOWN DIVERGENCES (tracked in parity backlog):
--   • `group by status` returns the full status name ("Todo" / "In Progress" /
--     "Done" / "Cancelled" / "On Hold").  Upstream returns binary "Todo" / "Done".
--   • `sort by status` sorts by the type enum string (alphabetical CANCELLED <
--     DONE < IN_PROGRESS < ON_HOLD < TODO).  Upstream sorts by the binary bucket.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")
local group_mod = require("obsidian-tasks.query.group")
local sort_mod = require("obsidian-tasks.query.sort")

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

-- ── done / not done across the type matrix ────────────────────────────────

T["done: matches DONE type (- [x])"] = function()
  eq(matches("done", pt("- [x] Done ✅ 2024-01-10")), true)
end

T["done: does NOT match TODO type (- [ ]) — parity with upstream"] = function()
  eq(matches("done", pt("- [ ] Todo task")), false)
end

T["done: does NOT match IN_PROGRESS type (- [/]) — parity with upstream"] = function()
  eq(matches("done", pt("- [/] In progress")), false)
end

T["done: does NOT match ON_HOLD type (- [h]) — parity with upstream"] = function()
  eq(matches("done", pt("- [h] On hold")), false)
end

T["done: matches CANCELLED type (- [-]) — upstream parity"] = function()
  -- CANCELLED counts as done (matches upstream's task.isDone semantics).
  eq(matches("done", pt("- [-] Cancelled")), true)
end

T["not done: matches TODO type (- [ ])"] = function()
  eq(matches("not done", pt("- [ ] Todo task")), true)
end

T["not done: matches IN_PROGRESS type (- [/])"] = function()
  eq(matches("not done", pt("- [/] In progress")), true)
end

T["not done: matches ON_HOLD type (- [h])"] = function()
  eq(matches("not done", pt("- [h] On hold")), true)
end

T["not done: does NOT match CANCELLED type — upstream parity"] = function()
  -- CANCELLED is considered done (matches upstream).
  eq(matches("not done", pt("- [-] Cancelled")), false)
end

T["not done: does NOT match DONE type"] = function()
  eq(matches("not done", pt("- [x] Done ✅ 2024-01-10")), false)
end

-- ── sort by status ────────────────────────────────────────────────────────

T["sort by status: TODO before DONE (alphabetical type string)"] = function()
  local items = {
    { task = pt("- [x] Done"), path = "/v/a.md", _idx = 1 },
    { task = pt("- [ ] Todo"), path = "/v/a.md", _idx = 2 },
  }
  local cmp = sort_mod.make_comparator({ { key = "status", reverse = false } })
  table.sort(items, cmp)
  -- Our sort: types compared as strings ("DONE" < "TODO").
  -- This places DONE first ascending — DIVERGES from upstream (Todo, Done).
  eq(items[1].task.status_symbol, "x")
  eq(items[2].task.status_symbol, " ")
end

T["sort by status reverse: reverses the order"] = function()
  local items = {
    { task = pt("- [x] Done"), path = "/v/a.md", _idx = 1 },
    { task = pt("- [ ] Todo"), path = "/v/a.md", _idx = 2 },
  }
  local cmp = sort_mod.make_comparator({ { key = "status", reverse = true } })
  table.sort(items, cmp)
  eq(items[1].task.status_symbol, " ")
  eq(items[2].task.status_symbol, "x")
end

-- ── group by status ──────────────────────────────────────────────────────

T["group by status: returns full status name (DIVERGES from upstream)"] = function()
  -- Upstream: binary "Todo" / "Done".  Ours: full name per status entry.
  eq(group_mod.resolve(pt("- [ ] a"), "/v/a.md", { { key = "status" } })[1], "Todo")
  eq(group_mod.resolve(pt("- [x] a ✅ 2024-01-10"), "/v/a.md", { { key = "status" } })[1], "Done")
  eq(group_mod.resolve(pt("- [/] a"), "/v/a.md", { { key = "status" } })[1], "In Progress")
  eq(group_mod.resolve(pt("- [-] a"), "/v/a.md", { { key = "status" } })[1], "Cancelled")
  eq(group_mod.resolve(pt("- [h] a"), "/v/a.md", { { key = "status" } })[1], "On Hold")
end

return T
