-- tests/unit/test_dim_completed.lua
-- Unit tests for dim_completed_tasks (live-task dim + sink to bottom).
--
-- Layout behavior:
--   • Completed-status tasks (Done 'x', Cancelled '-') in a group are emitted
--     after non-completed tasks, preserving the user's sort within each tier.
--   • Each emitted completed-live row has ll.dim = true (visual cue).
--   • Other terminal-feeling statuses (OnHold 'h', InProgress '/') are NOT
--     treated as completed.
--   • opts.dim_completed = false disables the sink + dim.
--   • Lingered rows continue to slot below live-completed and also carry dim.

local T = MiniTest.new_set()

local layout_mod = require("obsidian-tasks.render.layout")
local parse_task = require("obsidian-tasks.task.parse")

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function pt(line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  return t
end

local function with_src(task, path, line_nr)
  task._src_path = path
  task._src_line = line_nr or 1
  return task
end

local function make_result(opts)
  opts = opts or {}
  return {
    groups = opts.groups or {},
    total = opts.total or 0,
    hide_flags = opts.hide_flags or {},
    header_summary = "",
    errors = {},
  }
end

local function tasks_in_order(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      out[#out + 1] = l
    end
  end
  return out
end

-- ── Basic partition behavior ─────────────────────────────────────────────────

T["dim_completed: Done task sinks below Todo in same group"] = function()
  local todo = with_src(pt("- [ ] todo one"), "/v/a.md", 1)
  local done = with_src(pt("- [x] done one"), "/v/a.md", 2)

  local rendered = layout_mod.layout(
    make_result({ total = 2, groups = { { name = "", tasks = { todo, done } } } }),
    { dim_completed = true }
  )

  local tasks = tasks_in_order(rendered)
  eq(#tasks, 2)
  -- First task is the Todo (text starts with "- [ ]").
  MiniTest.expect.equality(tasks[1].text:sub(1, 5), "- [ ]")
  MiniTest.expect.equality(tasks[2].text:sub(1, 5), "- [x]")
  eq(tasks[1].dim, nil)
  eq(tasks[2].dim, true)
end

T["dim_completed: input order with Done first still sinks Done"] = function()
  local todo = with_src(pt("- [ ] todo one"), "/v/a.md", 1)
  local done = with_src(pt("- [x] done one"), "/v/a.md", 2)

  local rendered = layout_mod.layout(
    -- Done is first in the input list — sink should still put it second.
    make_result({ total = 2, groups = { { name = "", tasks = { done, todo } } } }),
    { dim_completed = true }
  )

  local tasks = tasks_in_order(rendered)
  MiniTest.expect.equality(tasks[1].text:sub(1, 5), "- [ ]")
  MiniTest.expect.equality(tasks[2].text:sub(1, 5), "- [x]")
end

T["dim_completed: Cancelled also sinks + dims"] = function()
  local todo = with_src(pt("- [ ] todo"), "/v/a.md", 1)
  local cancelled = with_src(pt("- [-] cancelled"), "/v/a.md", 2)

  local rendered = layout_mod.layout(
    make_result({ total = 2, groups = { { name = "", tasks = { cancelled, todo } } } }),
    { dim_completed = true }
  )

  local tasks = tasks_in_order(rendered)
  eq(tasks[1].dim, nil)
  eq(tasks[2].dim, true)
  MiniTest.expect.equality(tasks[2].text:sub(1, 5), "- [-]")
end

T["dim_completed: OnHold ('h') is NOT treated as completed"] = function()
  local todo = with_src(pt("- [ ] todo"), "/v/a.md", 1)
  local hold = with_src(pt("- [h] on hold"), "/v/a.md", 2)

  local rendered = layout_mod.layout(
    make_result({ total = 2, groups = { { name = "", tasks = { todo, hold } } } }),
    { dim_completed = true }
  )

  local tasks = tasks_in_order(rendered)
  eq(tasks[1].dim, nil)
  eq(tasks[2].dim, nil)
  -- Order preserved (not sunk).
  MiniTest.expect.equality(tasks[1].text:sub(1, 5), "- [ ]")
  MiniTest.expect.equality(tasks[2].text:sub(1, 5), "- [h]")
end

T["dim_completed: InProgress ('/') is NOT treated as completed"] = function()
  local todo = with_src(pt("- [ ] todo"), "/v/a.md", 1)
  local prog = with_src(pt("- [/] in progress"), "/v/a.md", 2)

  local rendered = layout_mod.layout(
    make_result({ total = 2, groups = { { name = "", tasks = { todo, prog } } } }),
    { dim_completed = true }
  )

  local tasks = tasks_in_order(rendered)
  eq(tasks[1].dim, nil)
  eq(tasks[2].dim, nil)
end

T["dim_completed: preserves order within each tier"] = function()
  -- Mix: t1 (todo), d1 (done), t2 (todo), d2 (done).
  -- Expect: [t1, t2, d1, d2] (each tier order preserved).
  local t1 = with_src(pt("- [ ] one"), "/v/a.md", 1)
  local d1 = with_src(pt("- [x] two"), "/v/a.md", 2)
  local t2 = with_src(pt("- [ ] three"), "/v/a.md", 3)
  local d2 = with_src(pt("- [x] four"), "/v/a.md", 4)

  local rendered = layout_mod.layout(
    make_result({ total = 4, groups = { { name = "", tasks = { t1, d1, t2, d2 } } } }),
    { dim_completed = true }
  )

  local tasks = tasks_in_order(rendered)
  eq(#tasks, 4)
  eq(tasks[1].src_line, 1) -- t1
  eq(tasks[2].src_line, 3) -- t2
  eq(tasks[3].src_line, 2) -- d1
  eq(tasks[4].src_line, 4) -- d2
end

-- ── Per-group partition ──────────────────────────────────────────────────────

T["dim_completed: partition is per-group (not global)"] = function()
  local todo_a = with_src(pt("- [ ] todo A"), "/v/a.md", 1)
  local done_a = with_src(pt("- [x] done A"), "/v/a.md", 2)
  local todo_b = with_src(pt("- [ ] todo B"), "/v/b.md", 1)
  local done_b = with_src(pt("- [x] done B"), "/v/b.md", 2)

  local rendered = layout_mod.layout(
    make_result({
      total = 4,
      groups = {
        { name = "/v/a.md", tasks = { done_a, todo_a } },
        { name = "/v/b.md", tasks = { done_b, todo_b } },
      },
    }),
    { dim_completed = true }
  )

  -- Each group should have its own done sunk to bottom.
  local tasks = tasks_in_order(rendered)
  eq(#tasks, 4)
  -- Find by src_path + status to assert ordering.
  -- Group A: todo_a before done_a; group B: todo_b before done_b.
  MiniTest.expect.equality(tasks[1].src_path, "/v/a.md")
  MiniTest.expect.equality(tasks[1].text:sub(1, 5), "- [ ]")
  MiniTest.expect.equality(tasks[2].src_path, "/v/a.md")
  MiniTest.expect.equality(tasks[2].text:sub(1, 5), "- [x]")
  MiniTest.expect.equality(tasks[3].src_path, "/v/b.md")
  MiniTest.expect.equality(tasks[3].text:sub(1, 5), "- [ ]")
  MiniTest.expect.equality(tasks[4].src_path, "/v/b.md")
  MiniTest.expect.equality(tasks[4].text:sub(1, 5), "- [x]")
end

-- ── Disable knob ─────────────────────────────────────────────────────────────

T["dim_completed: opts.dim_completed=false preserves order, no dim flags"] = function()
  local todo = with_src(pt("- [ ] todo"), "/v/a.md", 1)
  local done = with_src(pt("- [x] done"), "/v/a.md", 2)

  local rendered = layout_mod.layout(
    make_result({ total = 2, groups = { { name = "", tasks = { done, todo } } } }),
    { dim_completed = false }
  )

  local tasks = tasks_in_order(rendered)
  -- Input order preserved: Done first.
  MiniTest.expect.equality(tasks[1].text:sub(1, 5), "- [x]")
  MiniTest.expect.equality(tasks[2].text:sub(1, 5), "- [ ]")
  eq(tasks[1].dim, nil)
  eq(tasks[2].dim, nil)
end

-- ── Linger interaction ────────────────────────────────────────────────────────

T["dim_completed: lingered rows slot below live-completed, both dimmed"] = function()
  -- Group has [todo, done-live, done-lingered] → emitted in that order.
  local todo = with_src(pt("- [ ] todo"), "/v/a.md", 1)
  local done_live = with_src(pt("- [x] done live"), "/v/a.md", 2)
  local done_lingered = with_src(pt("- [x] done lingered"), "/v/a.md", 5)

  local rendered =
    layout_mod.layout(make_result({ total = 2, groups = { { name = "", tasks = { todo, done_live } } } }), {
      dim_completed = true,
      lingers = { { task = done_lingered, src_path = "/v/a.md", src_line = 5 } },
      group_by = {},
    })

  local tasks = tasks_in_order(rendered)
  eq(#tasks, 3)
  eq(tasks[1].dim, nil) -- todo
  eq(tasks[2].dim, true) -- done live
  eq(tasks[3].dim, true) -- done lingered
  eq(tasks[3].linger, true)
  eq(tasks[2].linger, nil) -- not lingered, just dim
end

return T
