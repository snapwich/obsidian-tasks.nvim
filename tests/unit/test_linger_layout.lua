-- tests/unit/test_linger_layout.lua
-- Unit tests for layout's linger emission.
--
-- Verifies that layout.layout(result, { lingers, group_by }) appends linger
-- rows at the bottom of each matching group with `linger = true`, in the order
-- they're passed.  Lingers whose previous group has no live members appear as
-- ghost groups at the end.

local T = MiniTest.new_set()

local layout_mod = require("obsidian-tasks.render.layout")
local parse_task = require("obsidian-tasks.task.parse")

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
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
    header_summary = opts.header_summary or "",
    errors = opts.errors or {},
    _ast_sort = opts._ast_sort,
    limit = opts.limit,
  }
end

local function lingers_of(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" and l.linger then
      out[#out + 1] = l
    end
  end
  return out
end

-- ── ungrouped result + single linger ─────────────────────────────────────────

T["linger: ungrouped result with one linger appends a dimmed row"] = function()
  local task_live = with_src(pt("- [ ] live one"), "/vault/a.md", 1)
  local lingered_task = with_src(pt("- [x] done one"), "/vault/a.md", 2)
  local result = make_result({ groups = { { name = "", tasks = { task_live } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = lingered_task, src_path = "/vault/a.md", src_line = 2 } },
    group_by = {},
  })

  local lingered = lingers_of(rendered)
  eq(#lingered, 1)
  eq(lingered[1].src_path, "/vault/a.md")
  eq(lingered[1].src_line, 2)
end

T["linger: appears after live tasks in the same group"] = function()
  local task_live = with_src(pt("- [ ] live one"), "/vault/a.md", 1)
  local lingered_task = with_src(pt("- [x] done one"), "/vault/a.md", 2)
  local result = make_result({ groups = { { name = "", tasks = { task_live } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = lingered_task, src_path = "/vault/a.md", src_line = 2 } },
    group_by = {},
  })

  -- Collect task records in order.
  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 2)
  eq(tasks[1].linger, nil)
  eq(tasks[2].linger, true)
end

T["linger: appended in completion order (newest at bottom)"] = function()
  local live = with_src(pt("- [ ] live"), "/vault/a.md", 1)
  local first_done = with_src(pt("- [x] first"), "/vault/a.md", 2)
  local second_done = with_src(pt("- [x] second"), "/vault/a.md", 3)
  local result = make_result({ groups = { { name = "", tasks = { live } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      { task = first_done, src_path = "/vault/a.md", src_line = 2 },
      { task = second_done, src_path = "/vault/a.md", src_line = 3 },
    },
    group_by = {},
  })

  local lingered = lingers_of(rendered)
  eq(#lingered, 2)
  eq(lingered[1].src_line, 2)
  eq(lingered[2].src_line, 3)
end

-- ── grouped result: lingers placed in matching group(s) ──────────────────────

T["linger: appears in matching group only (group by path)"] = function()
  local task_a = with_src(pt("- [ ] live in a"), "/vault/a.md", 1)
  local task_b = with_src(pt("- [ ] live in b"), "/vault/b.md", 1)
  local done_a = with_src(pt("- [x] done in a"), "/vault/a.md", 5)

  local result = make_result({
    total = 2,
    groups = {
      { name = "/vault/a.md", tasks = { task_a } },
      { name = "/vault/b.md", tasks = { task_b } },
    },
  })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = done_a, src_path = "/vault/a.md", src_line = 5 } },
    group_by = { { key = "path" } },
  })

  -- Verify the linger appears after task_a but before the next group header.
  local found_a_header, found_a_task, found_linger, found_b_header = false, false, false, false
  for _, l in ipairs(rendered) do
    if l.kind == "group_header" and l.text == "## /vault/a.md" then
      found_a_header = true
    elseif l.kind == "task" and found_a_header and not found_b_header then
      if l.linger then
        eq(found_a_task, true) -- linger must come after live task
        found_linger = true
      else
        found_a_task = true
      end
    elseif l.kind == "group_header" and l.text == "## /vault/b.md" then
      found_b_header = true
      eq(found_linger, true) -- linger must come before next group's header
    end
  end
  eq(found_a_task, true)
  eq(found_linger, true)
  eq(found_b_header, true)
end

T["linger: ghost group emitted when previous group has no live members"] = function()
  -- Live result has no /vault/c.md group (e.g. all tasks completed).
  local task_a = with_src(pt("- [ ] live in a"), "/vault/a.md", 1)
  local done_c = with_src(pt("- [x] done in c"), "/vault/c.md", 5)

  local result = make_result({
    total = 1,
    groups = { { name = "/vault/a.md", tasks = { task_a } } },
  })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = done_c, src_path = "/vault/c.md", src_line = 5 } },
    group_by = { { key = "path" } },
  })

  -- A ghost group_header "## /vault/c.md" must appear, followed by the linger.
  local saw_ghost_header, saw_ghost_linger = false, false
  for i, l in ipairs(rendered) do
    if l.kind == "group_header" and l.text == "## /vault/c.md" then
      saw_ghost_header = true
      -- Next task line should be the linger.
      for j = i + 1, #rendered do
        if rendered[j].kind == "task" then
          eq(rendered[j].linger, true)
          saw_ghost_linger = true
          break
        end
      end
    end
  end
  eq(saw_ghost_header, true)
  eq(saw_ghost_linger, true)
end

T["linger: ungrouped result with empty live set still renders the linger"] = function()
  local done = with_src(pt("- [x] done"), "/vault/a.md", 1)
  local result = make_result({ groups = {}, total = 0 })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = done, src_path = "/vault/a.md", src_line = 1 } },
    group_by = {},
  })

  local lingered = lingers_of(rendered)
  eq(#lingered, 1)
end

T["linger: footer unchanged — describes live results only"] = function()
  local live = with_src(pt("- [ ] live"), "/vault/a.md", 1)
  local done = with_src(pt("- [x] done"), "/vault/a.md", 2)
  local result = make_result({ groups = { { name = "", tasks = { live } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = done, src_path = "/vault/a.md", src_line = 2 } },
    group_by = {},
  })

  local footer = rendered[#rendered]
  eq(footer.kind, "footer")
  -- Footer says "1 result" (live count), not 2.
  MiniTest.expect.equality(footer.text:find("1 result", 1, true) ~= nil, true)
end

T["linger: no opts = no lingers (backward compatible)"] = function()
  local live = with_src(pt("- [ ] live"), "/vault/a.md", 1)
  local result = make_result({ groups = { { name = "", tasks = { live } } }, total = 1 })

  local rendered = layout_mod.layout(result)
  eq(#lingers_of(rendered), 0)
end

-- ── prior_index splicing (new positioning) ──────────────────────────────────

T["prior_index: linger at index 0 appears at top of group"] = function()
  local a = with_src(pt("- [ ] live a"), "/vault/x.md", 1)
  local b = with_src(pt("- [ ] live b"), "/vault/x.md", 2)
  local moved = with_src(pt("- [x] moved"), "/vault/x.md", 5)
  local result = make_result({ groups = { { name = "", tasks = { a, b } } }, total = 2 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = moved,
        src_path = "/vault/x.md",
        src_line = 5,
        prior_group_name = "",
        prior_index_within_group = 0,
      },
    },
    group_by = {},
  })

  -- Collect task records in order.
  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 3)
  eq(tasks[1].linger, true) -- linger slotted at index 0 (top of group)
  eq(tasks[1].src_line, 5)
  eq(tasks[2].src_line, 1) -- live a, bumped to index 1
  eq(tasks[3].src_line, 2) -- live b, bumped to index 2
end

T["prior_index: linger splices between live tasks"] = function()
  local a = with_src(pt("- [ ] live a"), "/vault/x.md", 1)
  local b = with_src(pt("- [ ] live b"), "/vault/x.md", 2)
  local moved = with_src(pt("- [x] moved"), "/vault/x.md", 5)
  local result = make_result({ groups = { { name = "", tasks = { a, b } } }, total = 2 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = moved,
        src_path = "/vault/x.md",
        src_line = 5,
        prior_group_name = "",
        prior_index_within_group = 1,
      },
    },
    group_by = {},
  })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 3)
  eq(tasks[1].src_line, 1) -- live a at 0
  eq(tasks[2].linger, true) -- linger at 1
  eq(tasks[2].src_line, 5)
  eq(tasks[3].src_line, 2) -- live b bumped from 1 to 2
end

T["prior_index: linger past live count appended after"] = function()
  local a = with_src(pt("- [ ] live a"), "/vault/x.md", 1)
  local moved = with_src(pt("- [x] moved"), "/vault/x.md", 5)
  local result = make_result({ groups = { { name = "", tasks = { a } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = moved,
        src_path = "/vault/x.md",
        src_line = 5,
        prior_group_name = "",
        prior_index_within_group = 99,
      },
    },
    group_by = {},
  })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 2)
  eq(tasks[1].linger, nil) -- live first
  eq(tasks[2].linger, true) -- linger spills after live (clamp to end)
end

T["prior_index: multiple lingers slot in ascending order"] = function()
  local a = with_src(pt("- [ ] live a"), "/vault/x.md", 1)
  local b = with_src(pt("- [ ] live b"), "/vault/x.md", 2)
  local c = with_src(pt("- [ ] live c"), "/vault/x.md", 3)
  local first_done = with_src(pt("- [x] done one"), "/vault/x.md", 10)
  local second_done = with_src(pt("- [x] done two"), "/vault/x.md", 11)
  local result = make_result({ groups = { { name = "", tasks = { a, b, c } } }, total = 3 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = second_done,
        src_path = "/vault/x.md",
        src_line = 11,
        prior_group_name = "",
        prior_index_within_group = 2,
      },
      {
        task = first_done,
        src_path = "/vault/x.md",
        src_line = 10,
        prior_group_name = "",
        prior_index_within_group = 1,
      },
    },
    group_by = {},
  })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  -- Lingers had consecutive prior_indices (1, 2) — in the prior render they
  -- were neighbors.  New render preserves that adjacency: both lingers bunch
  -- between live a and live b/c.
  -- Expected: a(0), first_done(1), second_done(2), b(3), c(4).
  eq(#tasks, 5)
  eq(tasks[1].src_line, 1)
  eq(tasks[2].linger, true)
  eq(tasks[2].src_line, 10)
  eq(tasks[3].linger, true)
  eq(tasks[3].src_line, 11)
  eq(tasks[4].src_line, 2)
  eq(tasks[5].src_line, 3)
end

T["prior_index: tasks carry group_name + group_index on their records"] = function()
  local a = with_src(pt("- [ ] live a"), "/vault/x.md", 1)
  local b = with_src(pt("- [ ] live b"), "/vault/x.md", 2)
  local result = make_result({ groups = { { name = "g1", tasks = { a, b } } }, total = 2 })

  local rendered = layout_mod.layout(result, { group_by = { { key = "path" } } })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 2)
  eq(tasks[1].group_name, "g1")
  eq(tasks[1].group_index, 0)
  eq(tasks[2].group_name, "g1")
  eq(tasks[2].group_index, 1)
end

-- ── Q8 dedup: linger wins within same query ──────────────────────────────────

T["dedup: live task suppressed when also lingered in same group"] = function()
  local same = with_src(pt("- [ ] same task"), "/vault/x.md", 5)
  -- Same src_path/src_line appears both as live AND lingered.
  local result = make_result({ groups = { { name = "", tasks = { same } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = same,
        src_path = "/vault/x.md",
        src_line = 5,
        prior_group_name = "",
        prior_index_within_group = 0,
      },
    },
    group_by = {},
  })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  -- Live render suppressed; only the lingered (dim) row remains.
  eq(#tasks, 1)
  eq(tasks[1].linger, true)
end

T["dedup: different src_line, same path → both render (not deduped)"] = function()
  local live = with_src(pt("- [ ] live"), "/vault/x.md", 1)
  local lingered = with_src(pt("- [x] lingered"), "/vault/x.md", 2)
  local result = make_result({ groups = { { name = "", tasks = { live } } }, total = 1 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = lingered,
        src_path = "/vault/x.md",
        src_line = 2,
        prior_group_name = "",
        prior_index_within_group = 1,
      },
    },
    group_by = {},
  })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 2)
end

-- ── ghost groups with prior_index ────────────────────────────────────────────

T["prior_index: ghost group lingers preserve prior_index order"] = function()
  local first = with_src(pt("- [x] first"), "/vault/x.md", 1)
  local second = with_src(pt("- [x] second"), "/vault/x.md", 2)
  -- No live members in the group; both tasks are lingered.
  local result = make_result({ groups = {}, total = 0 })

  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = second,
        src_path = "/vault/x.md",
        src_line = 2,
        prior_group_name = "ghostgrp",
        prior_index_within_group = 1,
      },
      {
        task = first,
        src_path = "/vault/x.md",
        src_line = 1,
        prior_group_name = "ghostgrp",
        prior_index_within_group = 0,
      },
    },
    group_by = {},
  })

  local tasks = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      tasks[#tasks + 1] = l
    end
  end
  eq(#tasks, 2)
  eq(tasks[1].src_line, 1) -- prior_index 0 first
  eq(tasks[2].src_line, 2) -- prior_index 1 second
end

-- ── source_text preservation (drift-check correctness) ──────────────────────
--
-- Regression: the dashboard reorders fields per FIELD_ORDER, so the rendered
-- text differs from a source line whose fields are in a non-canonical order.
-- Drift detection compares meta.task_text to the disk source line via string
-- equality, so layout must emit a `source_text` field carrying the VERBATIM
-- source line (= task.raw_line) — not the canonicalized render.

T["source_text: live task carries verbatim raw_line, not canonicalized render"] = function()
  -- Non-canonical field order: 🆔 (id) before ⏫ (priority) before 📅 (due).
  -- Canonical order per FIELD_ORDER is priority → due → id.
  local raw = "- [ ] task #t 🆔 web1 ⏫ 📅 2026-05-14"
  local task = parse_task.parse(raw)
  task._src_path = "/vault/web-app.md"
  task._src_line = 7

  local result = make_result({ groups = { { name = "", tasks = { task } } }, total = 1 })
  local rendered = layout_mod.layout(result, {})

  -- Find the rendered task row.
  local row
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      row = l
      break
    end
  end
  eq(row ~= nil, true)
  -- Rendered text is canonicalized (priority comes before id).
  -- This is the user-visible text in the dashboard.
  eq(row.text:find("⏫.*🆔") ~= nil, true)
  -- But source_text MUST be the verbatim source line so drift compares correctly.
  eq(row.source_text, raw)
end

T["source_text: linger entry carries verbatim raw_line"] = function()
  local raw = "- [x] done #t 🆔 abc ⏫ 📅 2026-05-14"
  local task = parse_task.parse(raw)
  task._src_path = "/vault/notes.md"
  task._src_line = 3

  local result = make_result({ groups = {}, total = 0 })
  local rendered = layout_mod.layout(result, {
    lingers = {
      {
        task = task,
        src_path = "/vault/notes.md",
        src_line = 3,
        prior_group_name = "",
        prior_index_within_group = 0,
      },
    },
    group_by = {},
  })

  local row
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      row = l
      break
    end
  end
  eq(row ~= nil, true)
  eq(row.source_text, raw)
end

-- ── post-mutation raw_line refresh ──────────────────────────────────────────
-- After a status-change command mutates a task, the task object still carries
-- its pre-mutation raw_line (set by parse).  _record_pending_linger must
-- refresh raw_line on the stored entry so subsequent drift checks (e.g. a
-- second toggle on the lingered row) compare against the post-mutation source.

T["_record_pending_linger: refreshes raw_line to post-mutation serialize"] = function()
  local render = require("obsidian-tasks.render")
  -- Save + restore state so other tests aren't affected.
  local prev_opts = render._opts
  local prev_pending = render._pending_lingers
  render._opts = { linger_on_filter_exit = true }
  render._pending_lingers = {}

  -- Parse a pre-mutation task; mutate status_symbol (as toggle would).
  local raw = "- [ ] task 📅 2026-05-20"
  local task = parse_task.parse(raw)
  eq(task.raw_line, raw)
  task.status_symbol = "x" -- toggle to done (pre-record mutation)

  render._record_pending_linger(99, "/vault/note.md", 1, nil, task)

  -- Stored entry's task.raw_line should reflect post-mutation serialize
  -- ("- [x] task 📅 2026-05-20"), not the original "- [ ]".
  local entries = render._pending_lingers[99]
  eq(#entries, 1)
  eq(entries[1].task.raw_line, "- [x] task 📅 2026-05-20")
  -- Caller's task object is NOT mutated (deepcopy isolates).
  eq(task.raw_line, raw)

  render._opts = prev_opts
  render._pending_lingers = prev_pending
end

-- ── tags expansion ───────────────────────────────────────────────────────────

T["linger: multi-tag task lingers in both tag groups when group by tags"] = function()
  -- Task with two tags, lingered.
  local done = with_src(pt("- [x] done #a #b"), "/vault/x.md", 5)
  local result = make_result({
    total = 0,
    groups = {},
  })

  local rendered = layout_mod.layout(result, {
    lingers = { { task = done, src_path = "/vault/x.md", src_line = 5 } },
    group_by = { { key = "tags" } },
  })

  -- Both #a and #b ghost groups should appear, each with a lingered row.
  local found_a, found_b = false, false
  for i, l in ipairs(rendered) do
    if l.kind == "group_header" then
      if l.text == "## #a" then
        found_a = true
        if rendered[i + 1] and rendered[i + 1].kind == "task" then
          eq(rendered[i + 1].linger, true)
        end
      elseif l.text == "## #b" then
        found_b = true
      end
    end
  end
  eq(found_a, true)
  eq(found_b, true)
end

return T
