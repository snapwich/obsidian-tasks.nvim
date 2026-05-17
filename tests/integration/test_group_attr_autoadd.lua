-- tests/integration/test_group_attr_autoadd.lua
-- RED-phase integration tests for P9: group-attribute auto-add on INSERT.
--
-- Each test sets up a grouped dashboard with TWO source tasks (so the managed
-- region spans both rows), inserts a new task BETWEEN them, calls flush, and
-- asserts the source-side new task carries the group-defining attribute.
--
-- Tests that assert an attribute WAS appended FAIL in RED (the stub in
-- group_attr.lua returns the line unchanged).  Tests that assert NO attribute
-- was added (file group, no group-by) PASS in RED.
--
-- INSERT pattern (matches test_insert_delete.lua):
--   source: anchor + sibling in same group
--   region: [task_row, task_row+1]
--   insert at task_row+1: new row at task_row+1, sibling shifts to task_row+2
--   region end expands (end_right_gravity=true) → new row in region → INSERT detected
--   anchor lookup: walks backward from task_row to find anchor at task_row ✓
--
-- Locked decisions under test (Q5):
--   tag group      → #tagname appended (additive — only if missing).
--   priority group → emoji or dataview field appended per origin.
--   status group   → checkbox symbol set to the group's status symbol.
--   file group     → NO auto-add; position handles membership.
--   multi-level    → all qualifying levels appended.
--   origin-aware   → dataview-style source → dataview form used.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local edit_mod = require("obsidian-tasks.render.edit")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

local function read_file(path)
  local b = vim.fn.bufnr(path, false)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- Stub the index to serve tasks read fresh from one source file.
--- Returns a restore function.
local function install_file_stub(src_path)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.tasks_in = function(_)
    local ok, lines = pcall(vim.fn.readfile, src_path)
    local content = ok and lines or {}
    local all = {}
    for ln, line in ipairs(content) do
      local task = task_parse.parse(line)
      if task then
        all[#all + 1] = { task = task, path = src_path, line_num = ln }
      end
    end
    local i = 0
    return function()
      i = i + 1
      if all[i] then
        return all[i].task, all[i].path, all[i].line_num
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Build a grouped dashboard from a single source file with TWO tasks.
--- query_lines: list of query lines (inserted between fences, without markers).
--- src_lines:   exactly 2 task lines for anchor + sibling.
--- Returns: bufnr, src_path, task_row, cleanup.
---
--- task_row is the 0-indexed row of the FIRST rendered task (anchor).
--- With N query_lines: fence=0, query_lines 1..N, fence=N+1, anchor=N+2.
--- Insert new task at task_row+1 (between anchor and sibling) to trigger INSERT.
local function setup_grouped_dashboard(src_lines, query_lines)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile(src_lines)
  local restore = install_file_stub(src_path)

  local buf_lines = { "```tasks" }
  for _, ql in ipairs(query_lines) do
    buf_lines[#buf_lines + 1] = ql
  end
  buf_lines[#buf_lines + 1] = "```"

  local bufnr = make_buf(buf_lines)
  render.render_buffer(bufnr, nil)

  local task_row = #query_lines + 2 -- 0-indexed first task row (anchor)

  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local sb = vim.fn.bufnr(src_path, false)
    if sb ~= -1 then
      vim.api.nvim_buf_delete(sb, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end

  return bufnr, src_path, task_row, cleanup
end

-- ── Tag group ─────────────────────────────────────────────────────────────────
--
-- RED FAIL: stub returns line unchanged; source new task lacks #someday.

T["group_attr_autoadd: paste into #someday tag group — source task gets #someday"] = function()
  -- Two tasks tagged #someday → same group, region spans both.
  local bufnr, src_path, task_row, cleanup = setup_grouped_dashboard(
    { "- [ ] Anchor task #someday", "- [ ] Sibling task #someday" },
    { "not done", "group by tags" }
  )

  -- Insert between anchor (task_row) and sibling (task_row+1).
  vim.api.nvim_buf_set_lines(bufnr, task_row + 1, task_row + 1, false, { "- [ ] New task" })

  edit_mod.flush(bufnr)

  -- GREEN: source has 3 lines; new task (written after anchor) has #someday.
  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source must have 3 lines after insert")
  -- insert_after_anchor writes new task after anchor (source row 0 → inserted at row 1).
  local new_task_line = src_lines[2]
  MiniTest.expect.no_equality(new_task_line, nil, "new task line must exist in source")
  local has_tag = new_task_line and new_task_line:find("#someday") ~= nil
  eq(has_tag, true, "new source task must have #someday auto-added by P9")

  cleanup()
end

-- ── Priority group (emoji) ────────────────────────────────────────────────────
--
-- RED FAIL: stub returns line unchanged; source new task lacks ⏫.

T["group_attr_autoadd: paste into ⏫ priority group — source task gets ⏫"] = function()
  -- Two high-priority tasks → same group (Priority 2: High).
  local bufnr, src_path, task_row, cleanup = setup_grouped_dashboard(
    { "- [ ] Anchor task ⏫", "- [ ] Sibling task ⏫" },
    { "not done", "group by priority" }
  )

  vim.api.nvim_buf_set_lines(bufnr, task_row + 1, task_row + 1, false, { "- [ ] New priority task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source must have 3 lines after insert")
  local new_task_line = src_lines[2]
  local has_priority = new_task_line and new_task_line:find("⏫") ~= nil
  eq(has_priority, true, "new source task must have ⏫ auto-added by P9")

  cleanup()
end

-- ── Priority group (dataview) ─────────────────────────────────────────────────
--
-- RED FAIL: stub returns line unchanged; source new task lacks [priority:: high].

T["group_attr_autoadd: dataview-style source in priority group — new task gets [priority:: high]"] = function()
  -- Two tasks with dataview priority syntax → same group, origin = dataview.
  local bufnr, src_path, task_row, cleanup = setup_grouped_dashboard(
    { "- [ ] Anchor task [priority:: high]", "- [ ] Sibling task [priority:: high]" },
    { "not done", "group by priority" }
  )

  vim.api.nvim_buf_set_lines(bufnr, task_row + 1, task_row + 1, false, { "- [ ] New dataview task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source must have 3 lines after insert")
  local new_task_line = src_lines[2]
  local has_dv = new_task_line and new_task_line:find("%[priority:: high%]") ~= nil
  eq(has_dv, true, "new task must use dataview form [priority:: high] matching anchor origin")

  cleanup()
end

-- ── Status group ──────────────────────────────────────────────────────────────
--
-- RED FAIL: stub returns line unchanged; new task retains [ ] instead of [/].

T["group_attr_autoadd: paste into [/] status group — source task gets [/] checkbox"] = function()
  -- Two In Progress tasks → same status group.
  local bufnr, src_path, task_row, cleanup = setup_grouped_dashboard(
    { "- [/] Anchor in-progress task", "- [/] Sibling in-progress task" },
    { "not done", "group by status" }
  )

  vim.api.nvim_buf_set_lines(bufnr, task_row + 1, task_row + 1, false, { "- [ ] New status task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source must have 3 lines after insert")
  local new_task_line = src_lines[2]
  local has_inprogress = new_task_line and new_task_line:find("%- %[/%]") ~= nil
  eq(has_inprogress, true, "new source task must have [/] checkbox from P9 status group")

  cleanup()
end

-- ── Multi-level group ─────────────────────────────────────────────────────────
--
-- RED FAIL: stub returns line unchanged; new task lacks both #someday and ⏫.

T["group_attr_autoadd: paste into multi-level tag+priority group — both attributes appended"] = function()
  -- Two tasks with both #someday tag and high priority → same combined group.
  local bufnr, src_path, task_row, cleanup = setup_grouped_dashboard(
    { "- [ ] Anchor task #someday ⏫", "- [ ] Sibling task #someday ⏫" },
    { "not done", "group by tags", "group by priority" }
  )

  vim.api.nvim_buf_set_lines(bufnr, task_row + 1, task_row + 1, false, { "- [ ] Multi-level new task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source must have 3 lines after insert")
  local new_task_line = src_lines[2]
  local has_tag = new_task_line and new_task_line:find("#someday") ~= nil
  local has_prio = new_task_line and new_task_line:find("⏫") ~= nil
  eq(has_tag, true, "new source task must have #someday auto-added")
  eq(has_prio, true, "new source task must have ⏫ auto-added")

  cleanup()
end

-- ── File group (PASS in RED — no auto-add expected) ───────────────────────────
--
-- PASS in RED: stub returns line unchanged, which IS the correct behaviour
-- for file groups (position in source file is the implicit membership).
-- INSERT itself works (P8 is GREEN); only assert no extra attribute was added.

T["group_attr_autoadd: paste into file group — no attribute auto-added (regression guard)"] = function()
  local bufnr, src_path, task_row, cleanup = setup_grouped_dashboard(
    { "- [ ] Anchor file-group task", "- [ ] Sibling file-group task" },
    { "not done", "group by filename" }
  )

  vim.api.nvim_buf_set_lines(bufnr, task_row + 1, task_row + 1, false, { "- [ ] New file-group task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source must have 3 lines after insert")
  -- New task is written exactly as typed: no attribute appended.
  local new_task_line = src_lines[2]
  eq(new_task_line, "- [ ] New file-group task", "file group must not auto-add any attribute")

  cleanup()
end

return T
