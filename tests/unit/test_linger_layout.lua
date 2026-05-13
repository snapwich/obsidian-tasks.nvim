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
