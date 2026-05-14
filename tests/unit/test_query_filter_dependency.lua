-- tests/unit/test_query_filter_dependency.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/{Id,DependsOn,Blocking}Field.test.ts
--
-- Dependency filters: `id is X`, `depends on X`, `is blocking`, `is blocked`.
-- The blocking/blocked filters consult the index for reverse / forward
-- lookups; this test seeds the index directly so it doesn't depend on
-- obsidian.nvim or any vault state.

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
  return pred(task, "/v/note.md")
end

--- Seed the index with synthetic tasks for blocking/blocked tests.
--- We re-require the index module on every call.  test_index.lua replaces
--- package.loaded["obsidian-tasks.index"] mid-suite to get a fresh module;
--- capturing `index` at file-load time would write into a stale module
--- while filter.lua's predicate re-requires the live one and sees an
--- empty index.
local function seed_index(items)
  local index = require("obsidian-tasks.index")
  index._reset()
  local entry_tasks = {}
  for _, item in ipairs(items) do
    entry_tasks[#entry_tasks + 1] = { task = item.task, line_num = item.line_num or 1 }
  end
  local raw = index._raw()
  raw["/v/note.md"] = { mtime = 0, tasks = entry_tasks }
end

local function reset_index()
  require("obsidian-tasks.index")._reset()
end

-- ── id is <X> ────────────────────────────────────────────────────────────

T["id is <x>: matches task whose id equals x"] = function()
  local t = pt("- [ ] Task 🆔 abc123")
  eq(matches("id is abc123", t), true)
end

T["id is <x>: false when id differs"] = function()
  eq(matches("id is xyz789", pt("- [ ] Task 🆔 abc123")), false)
end

T["id is <x>: false when task has no id"] = function()
  eq(matches("id is abc123", pt("- [ ] Task")), false)
end

-- ── depends on <X> ──────────────────────────────────────────────────────

T["depends on <id>: matches task with that id in its ⛔ list"] = function()
  local t = pt("- [ ] Task ⛔ abc")
  eq(matches("depends on abc", t), true)
end

T["depends on <id>: matches in a comma-separated list"] = function()
  local t = pt("- [ ] Task ⛔ abc,def,xyz")
  eq(matches("depends on def", t), true)
  eq(matches("depends on xyz", t), true)
end

T["depends on <id>: false when not in list"] = function()
  eq(matches("depends on nope", pt("- [ ] Task ⛔ abc,def")), false)
end

T["depends on <id>: false when task has no depends_on"] = function()
  eq(matches("depends on abc", pt("- [ ] Plain task")), false)
end

-- ── is blocking / is blocked ────────────────────────────────────────────

T["is blocking: task whose id appears in another's depends_on"] = function()
  local blocker = pt("- [ ] Build feature 🆔 feat1")
  local blocked_by_feat1 = pt("- [ ] Ship release ⛔ feat1")
  seed_index({
    { task = blocker },
    { task = blocked_by_feat1 },
  })
  eq(matches("is blocking", blocker), true)
  -- The "Ship release" task itself isn't blocking anyone (no id) → false.
  eq(matches("is blocking", blocked_by_feat1), false)
  reset_index()
end

T["is blocking: false when no other task depends on this id"] = function()
  local solo = pt("- [ ] Solo 🆔 alone")
  seed_index({ { task = solo } })
  eq(matches("is blocking", solo), false)
  reset_index()
end

T["is not blocking: complement of is blocking"] = function()
  local blocker = pt("- [ ] B 🆔 a")
  local dependant = pt("- [ ] D ⛔ a")
  seed_index({ { task = blocker }, { task = dependant } })
  eq(matches("is not blocking", blocker), false)
  eq(matches("is not blocking", dependant), true)
  reset_index()
end

T["is blocked: task whose depends_on points to an in-progress task"] = function()
  local upstream = pt("- [ ] Upstream still open 🆔 u1")
  local downstream = pt("- [ ] Downstream waiting ⛔ u1")
  seed_index({ { task = upstream }, { task = downstream } })
  eq(matches("is blocked", downstream), true)
  -- The upstream task isn't blocked (it has no depends_on).
  eq(matches("is blocked", upstream), false)
  reset_index()
end

T["is blocked: false when ALL upstream dependencies are done"] = function()
  local done_upstream = pt("- [x] Done upstream 🆔 u1 ✅ 2024-01-01")
  local downstream = pt("- [ ] Downstream ⛔ u1")
  seed_index({ { task = done_upstream }, { task = downstream } })
  eq(matches("is blocked", downstream), false)
  reset_index()
end

T["is blocked: true when SOME upstream is not-done (logical OR over deps)"] = function()
  local done = pt("- [x] Done 🆔 u1 ✅ 2024-01-01")
  local still_open = pt("- [ ] Open 🆔 u2")
  local downstream = pt("- [ ] Multi-dep ⛔ u1,u2")
  seed_index({ { task = done }, { task = still_open }, { task = downstream } })
  eq(matches("is blocked", downstream), true)
  reset_index()
end

T["is not blocked: complement"] = function()
  local plain = pt("- [ ] Plain task")
  seed_index({ { task = plain } })
  eq(matches("is not blocked", plain), true)
  reset_index()
end

return T
