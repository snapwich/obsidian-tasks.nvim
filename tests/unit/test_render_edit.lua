-- tests/unit/test_render_edit.lua
-- Unit tests for render/edit.lua.
-- Runs in headless Neovim (mini.test); real vim.api and vim.fn calls are valid.

local T = MiniTest.new_set()

local edit_mod = require("obsidian-tasks.render.edit")
local draw_mod = require("obsidian-tasks.render.draw")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Create a scratch buffer with the given lines.
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Named scratch buffer — visible to vim.fn.bufnr() by path.
local function make_named_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  -- Assign a unique scratch name so vim.fn.bufnr(path, false) finds it.
  local name = "obsidian-tasks-test-edit-" .. bufnr .. ".md"
  vim.api.nvim_buf_set_name(bufnr, name)
  return bufnr, name
end

--- fence_range helper: 0-indexed first..last.
local function fence(first, last)
  return { first, last }
end

--- Build a minimal layout_lines list with a single task.
local function simple_layout(text, src_path, src_line)
  local hash = vim.fn.sha256(text):sub(1, 16)
  return {
    { kind = "label", text = "▶ tasks · 1 result" },
    {
      kind = "task",
      text = text,
      src_path = src_path or "/vault/note.md",
      src_line = src_line or 5,
      src_hash = hash,
    },
    { kind = "footer", text = "─ 1 result ─" },
  }
end

--- Build a layout_lines list with two tasks.
local function two_task_layout(text_a, path_a, line_a, text_b, path_b, line_b)
  local hash_a = vim.fn.sha256(text_a):sub(1, 16)
  local hash_b = vim.fn.sha256(text_b):sub(1, 16)
  return {
    { kind = "label", text = "▶ tasks · 2 results" },
    { kind = "task", text = text_a, src_path = path_a, src_line = line_a, src_hash = hash_a },
    { kind = "task", text = text_b, src_path = path_b, src_line = line_b, src_hash = hash_b },
    { kind = "footer", text = "─ 2 results ─" },
  }
end

-- ── apply_patch: loaded buffer ────────────────────────────────────────────────

T["apply_patch: loaded buffer uses nvim_buf_set_lines"] = function()
  local bufnr, path = make_named_buf({ "line1", "- [ ] Original task", "line3" })

  -- Verify buffer is reachable via path.
  MiniTest.expect.equality(vim.fn.bufnr(path, false) > -1, true)

  edit_mod.apply_patch({ src_path = path, src_line = 2, new_text = "- [x] Done task" })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(lines[2], "- [x] Done task")
  -- Other lines untouched.
  eq(lines[1], "line1")
  eq(lines[3], "line3")
end

T["apply_patch: loaded buffer replaces only the target line"] = function()
  local bufnr, path = make_named_buf({ "a", "b", "c", "d" })

  edit_mod.apply_patch({ src_path = path, src_line = 3, new_text = "C-modified" })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#lines, 4)
  eq(lines[1], "a")
  eq(lines[2], "b")
  eq(lines[3], "C-modified")
  eq(lines[4], "d")
end

-- ── apply_patch: disk fallback ────────────────────────────────────────────────

T["apply_patch: disk fallback uses readfile/writefile"] = function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "line1", "- [ ] Original task", "line3" }, path)

  -- Must NOT be loaded as a buffer.
  eq(vim.fn.bufnr(path, false), -1)

  edit_mod.apply_patch({ src_path = path, src_line = 2, new_text = "- [x] Done task" })

  local lines = vim.fn.readfile(path)
  eq(lines[1], "line1")
  eq(lines[2], "- [x] Done task")
  eq(lines[3], "line3")
end

T["apply_patch: disk fallback preserves line count"] = function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "a", "b", "c" }, path)
  eq(vim.fn.bufnr(path, false), -1)

  edit_mod.apply_patch({ src_path = path, src_line = 1, new_text = "A" })

  local lines = vim.fn.readfile(path)
  eq(#lines, 3)
  eq(lines[1], "A")
end

-- ── apply_deletion: loaded buffer ─────────────────────────────────────────────

T["apply_deletion: loaded buffer removes target line"] = function()
  local bufnr, path = make_named_buf({ "line1", "- [ ] Task to delete", "line3" })

  MiniTest.expect.equality(vim.fn.bufnr(path, false) > -1, true)

  edit_mod.apply_deletion({ src_path = path, src_line = 2 })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#lines, 2)
  eq(lines[1], "line1")
  eq(lines[2], "line3")
end

T["apply_deletion: loaded buffer first-line removal"] = function()
  local bufnr, path = make_named_buf({ "delete-me", "keep-a", "keep-b" })

  edit_mod.apply_deletion({ src_path = path, src_line = 1 })

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#lines, 2)
  eq(lines[1], "keep-a")
  eq(lines[2], "keep-b")
end

-- ── apply_deletion: disk fallback ─────────────────────────────────────────────

T["apply_deletion: disk fallback removes target line"] = function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "line1", "- [ ] Task to delete", "line3" }, path)

  eq(vim.fn.bufnr(path, false), -1)

  edit_mod.apply_deletion({ src_path = path, src_line = 2 })

  local lines = vim.fn.readfile(path)
  eq(#lines, 2)
  eq(lines[1], "line1")
  eq(lines[2], "line3")
end

T["apply_deletion: disk fallback last-line removal"] = function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "a", "b", "c" }, path)
  eq(vim.fn.bufnr(path, false), -1)

  edit_mod.apply_deletion({ src_path = path, src_line = 3 })

  local lines = vim.fn.readfile(path)
  eq(#lines, 2)
  eq(lines[1], "a")
  eq(lines[2], "b")
end

-- ── diff: no changes ──────────────────────────────────────────────────────────

T["diff: unchanged task line produces no operations"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Buy milk", "/vault/note.md", 10)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Task inserted at line 3 (0-indexed).
  local result = edit_mod.diff(bufnr, { 3, 3 })

  eq(#result.patches, 0)
  eq(#result.deletions, 0)
  eq(#result.inserts, 0)

  draw_mod.clear(bufnr)
end

-- ── diff: patch detection ─────────────────────────────────────────────────────

T["diff: edited task line produces patch with new_text"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Buy milk", "/vault/note.md", 10)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Modify the task text in the render buffer (line 3, 0-indexed).
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "- [x] Buy milk" })

  local result = edit_mod.diff(bufnr, { 3, 3 })

  eq(#result.patches, 1)
  eq(result.patches[1].src_path, "/vault/note.md")
  eq(result.patches[1].src_line, 10)
  eq(result.patches[1].new_text, "- [x] Buy milk")
  eq(#result.deletions, 0)
  eq(#result.inserts, 0)

  draw_mod.clear(bufnr)
end

T["diff: multiple edited tasks all produce patches"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = two_task_layout("- [ ] A", "/v/a.md", 1, "- [ ] B", "/v/b.md", 2)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Tasks at lines 3 and 4; modify both.
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "- [x] A" })
  vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { "- [x] B" })

  local result = edit_mod.diff(bufnr, { 3, 4 })

  eq(#result.patches, 2)
  eq(#result.deletions, 0)
  eq(#result.inserts, 0)

  draw_mod.clear(bufnr)
end

T["diff: hash still matches when text unchanged → no patch"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Unchanged", "/v/note.md", 3)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Do NOT modify line 3.
  local result = edit_mod.diff(bufnr, { 3, 3 })
  eq(#result.patches, 0)

  draw_mod.clear(bufnr)
end

-- ── diff: deletion detection ──────────────────────────────────────────────────

T["diff: deleted task line produces deletion"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Task A", "/vault/a.md", 5)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Delete the task line (line 3); buffer now has only 3 lines (0-2).
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, {})

  -- Scan the original render_range; buffer is now shorter so the line is gone.
  local result = edit_mod.diff(bufnr, { 3, 3 })

  eq(#result.patches, 0)
  eq(#result.deletions, 1)
  eq(result.deletions[1].src_path, "/vault/a.md")
  eq(result.deletions[1].src_line, 5)
  eq(#result.inserts, 0)

  draw_mod.clear(bufnr)
end

T["diff: deleting all tasks produces one deletion per task"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = two_task_layout("- [ ] A", "/v/a.md", 1, "- [ ] B", "/v/b.md", 2)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Tasks at lines 3-4; delete both.
  vim.api.nvim_buf_set_lines(bufnr, 3, 5, false, {})

  local result = edit_mod.diff(bufnr, { 3, 4 })

  eq(#result.deletions, 2)
  eq(#result.patches, 0)
  eq(#result.inserts, 0)

  draw_mod.clear(bufnr)
end

-- ── diff: insert detection ────────────────────────────────────────────────────

T["diff: user-inserted line (no extmark) produces insert"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Original", "/vault/note.md", 1)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Task at line 3. Insert a new line after it (at line 4).
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "- [ ] New task" })

  -- Scan range {3, 4}: line 3 has extmark (original), line 4 has no extmark.
  local result = edit_mod.diff(bufnr, { 3, 4 })

  eq(#result.inserts, 1)
  eq(result.inserts[1].after_lnum, 4)
  eq(result.inserts[1].new_text, "- [ ] New task")
  eq(#result.patches, 0)
  eq(#result.deletions, 0)

  draw_mod.clear(bufnr)
end

T["diff: multiple inserted lines all appear as inserts"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Original", "/vault/note.md", 1)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Insert two lines after line 3.
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "- [ ] Insert 1", "- [ ] Insert 2" })

  local result = edit_mod.diff(bufnr, { 3, 5 })

  eq(#result.inserts, 2)
  eq(result.inserts[1].new_text, "- [ ] Insert 1")
  eq(result.inserts[2].new_text, "- [ ] Insert 2")
  eq(#result.patches, 0)
  eq(#result.deletions, 0)

  draw_mod.clear(bufnr)
end

-- ── diff: row-shift correctness (regression tests for reviewer bugs) ──────────

-- Bug #1: insert ABOVE an existing task → must produce INSERT only; must NOT
-- patch the task source with the newly inserted text.
T["diff: insert above existing task produces insert only"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Task A", "/vault/a.md", 10)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Task A is at row 3.  Insert a line ABOVE it (at row 3), pushing Task A to row 4.
  vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "- [ ] Above inserted" })

  -- Extended render_range covers both the new row (3) and Task A's new row (4).
  local result = edit_mod.diff(bufnr, { 3, 4 })

  eq(#result.patches, 0) -- Task A source must NOT be overwritten
  eq(#result.deletions, 0) -- Task A must NOT be treated as deleted
  eq(#result.inserts, 1)
  eq(result.inserts[1].new_text, "- [ ] Above inserted")

  draw_mod.clear(bufnr)
end

-- Bug #2: delete the FIRST of multiple tasks → must produce ONE deletion for
-- that task only; must NOT patch the surviving task's source.
T["diff: deleting first task in two-task block produces one deletion"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = two_task_layout("- [ ] Task A", "/v/a.md", 5, "- [ ] Task B", "/v/b.md", 7)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Tasks at rows 3 (A) and 4 (B).  Delete Task A; Task B shifts to row 3.
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, {})

  -- Original render_range covers rows 3-4.
  local result = edit_mod.diff(bufnr, { 3, 4 })

  eq(#result.patches, 0) -- Task B source must NOT be overwritten
  eq(#result.deletions, 1) -- Only Task A deleted
  eq(result.deletions[1].src_path, "/v/a.md")
  eq(result.deletions[1].src_line, 5)
  eq(#result.inserts, 0)

  draw_mod.clear(bufnr)
end

-- ── diff: mixed operations ────────────────────────────────────────────────────

T["diff: edit + insert in same render range"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Original", "/vault/note.md", 7)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Task at line 3. Edit it.
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "- [x] Original" })
  -- Insert a new line after it.
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "- [ ] Brand new" })

  local result = edit_mod.diff(bufnr, { 3, 4 })

  eq(#result.patches, 1)
  eq(result.patches[1].new_text, "- [x] Original")
  eq(#result.inserts, 1)
  eq(result.inserts[1].new_text, "- [ ] Brand new")
  eq(#result.deletions, 0)

  draw_mod.clear(bufnr)
end

-- ── diff: empty render range ──────────────────────────────────────────────────

T["diff: empty buffer state returns empty result"] = function()
  local bufnr = make_buf({ "just text" })

  local result = edit_mod.diff(bufnr, { 0, 0 })

  eq(#result.patches, 0)
  eq(#result.deletions, 0)
  eq(#result.inserts, 0)
end

-- ── apply_insert: without bufnr remains a no-op ───────────────────────────────

T["apply_insert: no bufnr → no-op, no error"] = function()
  MiniTest.expect.no_error(function()
    edit_mod.apply_insert({ after_lnum = 5, new_text = "- [ ] New task" })
  end)
end

-- ── resolve_insert: helpers ───────────────────────────────────────────────────

--- Override opts.capture_file for the duration of *fn*, restore afterwards.
local function with_capture_file(path, fn)
  local plugin = require("obsidian-tasks")
  local orig = plugin.opts.capture_file
  plugin.opts.capture_file = path
  local ok, err = pcall(fn)
  plugin.opts.capture_file = orig
  if not ok then
    error(err, 2)
  end
end

--- Override vim.notify for the duration of *fn*; returns captured calls.
--- Each entry: { msg, level }.
local function capture_notify(fn)
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level, _opts)
    calls[#calls + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then
    error(err, 2)
  end
  return calls
end

--- Draw a single-task block into *render_bufnr* and return the task's render row.
--- Returns the 0-indexed row where the task line was inserted.
local function draw_task(render_bufnr, src_path, src_line, task_text)
  local layout = simple_layout(task_text or "- [ ] Task", src_path, src_line)
  draw_mod.draw(render_bufnr, fence(0, 2), layout)
  -- fence is lines 0-2; task is inserted at line 3.
  return 3
end

-- ── resolve_insert: sibling above (loaded buffer) ─────────────────────────────

T["resolve_insert: sibling above → inserts after src_line in loaded source buffer"] = function()
  -- Source buffer: task at 1-indexed line 1.
  local src_bufnr, src_path = make_named_buf({ "- [ ] Task A", "extra line" })

  -- Render buffer with one task drawn.
  local render_bufnr = make_buf({ "```tasks", "not done", "```" })
  local task_row = draw_task(render_bufnr, src_path, 1, "- [ ] Task A")

  -- User inserts a line AFTER the task (at row task_row + 1).
  -- The new line's after_lnum = task_row + 1.
  local after_lnum = task_row + 1

  with_capture_file(nil, function()
    edit_mod.resolve_insert(render_bufnr, after_lnum, "- [ ] New task")
  end)

  -- Source buffer must have the new line inserted after 1-indexed line 1.
  local lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  eq(lines[1], "- [ ] Task A")
  eq(lines[2], "- [ ] New task")
  eq(lines[3], "extra line")

  draw_mod.clear(render_bufnr)
end

-- ── resolve_insert: sibling above (disk fallback) ─────────────────────────────

T["resolve_insert: sibling above → inserts after src_line on disk when not loaded"] = function()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] Task A", "extra line" }, path)

  -- Make sure this path is NOT loaded as a buffer.
  eq(vim.fn.bufnr(path, false), -1)

  local render_bufnr = make_buf({ "```tasks", "not done", "```" })
  local task_row = draw_task(render_bufnr, path, 1, "- [ ] Task A")

  local after_lnum = task_row + 1

  with_capture_file(nil, function()
    edit_mod.resolve_insert(render_bufnr, after_lnum, "- [ ] New task")
  end)

  local lines = vim.fn.readfile(path)
  eq(lines[1], "- [ ] Task A")
  eq(lines[2], "- [ ] New task")
  eq(lines[3], "extra line")

  draw_mod.clear(render_bufnr)
end

-- ── resolve_insert: sibling above with multiple tasks ────────────────────────

T["resolve_insert: sibling is immediately above insert row"] = function()
  -- Two tasks drawn: A at row 3, B at row 4.  Insert at row 5 (after B).
  local src_a = "/vault/a_sibling.md"
  local src_b_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] Task B", "tail" }, src_b_path)
  eq(vim.fn.bufnr(src_b_path, false), -1)

  local render_bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = two_task_layout("- [ ] Task A", src_a, 10, "- [ ] Task B", src_b_path, 1)
  draw_mod.draw(render_bufnr, fence(0, 2), layout)
  -- Task A at row 3, Task B at row 4.

  -- Insert after row 4 (= after Task B).
  local after_lnum = 5

  with_capture_file(nil, function()
    edit_mod.resolve_insert(render_bufnr, after_lnum, "- [ ] Inserted after B")
  end)

  -- Only Task B's source should be modified (nearest sibling above row 5 is row 4 = Task B).
  local lines = vim.fn.readfile(src_b_path)
  eq(lines[1], "- [ ] Task B")
  eq(lines[2], "- [ ] Inserted after B")
  eq(lines[3], "tail")

  draw_mod.clear(render_bufnr)
end

-- ── resolve_insert: capture_file path (no sibling) ───────────────────────────

T["resolve_insert: no sibling, capture_file set → appended to file (created on first use)"] = function()
  local cap_path = vim.fn.tempname() .. ".md"
  eq(vim.fn.filereadable(cap_path), 0) -- must not exist yet

  -- No draw state: state is nil, so no blocks → no sibling found.
  local render_bufnr = make_buf({ "- [ ] anything" })

  with_capture_file(cap_path, function()
    -- after_lnum = 0, no draw state → walk_stop = 0, walk_start = -1 → no walk → no anchor.
    edit_mod.resolve_insert(render_bufnr, 0, "- [ ] Captured")
  end)

  eq(vim.fn.filereadable(cap_path), 1) -- file created
  local lines = vim.fn.readfile(cap_path)
  eq(lines[1], "- [ ] Captured")
end

T["resolve_insert: capture_file exists → new task appended after existing content"] = function()
  local cap_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] Existing task" }, cap_path)

  local render_bufnr = make_buf({ "- [ ] anything" })

  with_capture_file(cap_path, function()
    edit_mod.resolve_insert(render_bufnr, 0, "- [ ] New capture")
  end)

  local lines = vim.fn.readfile(cap_path)
  eq(#lines, 2)
  eq(lines[1], "- [ ] Existing task")
  eq(lines[2], "- [ ] New capture")
end

T["resolve_insert: capture_file loaded as buffer → appended via buffer API"] = function()
  -- Use an absolute path as the buffer name so resolve_buf(abs_path) matches
  -- regardless of whether _G.Obsidian is set from other tests.
  local cf_path = vim.fn.tempname() .. "_capture.md"
  local cf_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(cf_bufnr, 0, -1, false, { "- [ ] Existing" })
  vim.api.nvim_buf_set_name(cf_bufnr, cf_path)

  MiniTest.expect.equality(vim.fn.bufnr(cf_path, false) > -1, true)

  local render_bufnr = make_buf({ "- [ ] anything" })

  with_capture_file(cf_path, function()
    edit_mod.resolve_insert(render_bufnr, 0, "- [ ] Via buffer")
  end)

  local lines = vim.api.nvim_buf_get_lines(cf_bufnr, 0, -1, false)
  eq(#lines, 2)
  eq(lines[1], "- [ ] Existing")
  eq(lines[2], "- [ ] Via buffer")
end

-- ── resolve_insert: capture_file with parent dirs ─────────────────────────────

T["resolve_insert: capture_file parent dirs created if missing"] = function()
  local base = vim.fn.tempname()
  local cap_path = base .. "/deep/nested/inbox.md"
  eq(vim.fn.filereadable(cap_path), 0)
  eq(vim.fn.isdirectory(vim.fn.fnamemodify(cap_path, ":h")), 0)

  local render_bufnr = make_buf({ "text" })

  with_capture_file(cap_path, function()
    edit_mod.resolve_insert(render_bufnr, 0, "- [ ] Deep capture")
  end)

  eq(vim.fn.filereadable(cap_path), 1)
  local lines = vim.fn.readfile(cap_path)
  eq(lines[1], "- [ ] Deep capture")
end

-- ── resolve_insert: relative capture_file → vault root ───────────────────────

T["resolve_insert: relative capture_file resolved against vault root"] = function()
  local vault_root = vim.fn.tempname()
  vim.fn.mkdir(vault_root, "p")
  local expected = vault_root .. "/inbox.md"
  eq(vim.fn.filereadable(expected), 0)

  -- Stub _G.Obsidian so current_workspace() returns our temp vault root.
  local prev_obsidian = _G.Obsidian
  _G.Obsidian = { workspace = { root = vault_root }, workspaces = {} }

  local render_bufnr = make_buf({ "text" })

  with_capture_file("inbox.md", function()
    edit_mod.resolve_insert(render_bufnr, 0, "- [ ] Relative capture")
  end)

  _G.Obsidian = prev_obsidian

  eq(vim.fn.filereadable(expected), 1)
  local lines = vim.fn.readfile(expected)
  eq(lines[1], "- [ ] Relative capture")
end

-- ── resolve_insert: no capture_file → warn, no write ─────────────────────────

T["resolve_insert: no sibling and no capture_file → warn emitted, no file written"] = function()
  local render_bufnr = make_buf({ "text" })

  local notify_calls = capture_notify(function()
    with_capture_file(nil, function()
      edit_mod.resolve_insert(render_bufnr, 0, "- [ ] Orphan")
    end)
  end)

  -- Must have emitted a WARN containing the expected message.
  local found_warn = false
  for _, call in ipairs(notify_calls) do
    if call.level == vim.log.levels.WARN and call.msg:find("no anchor", 1, true) then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

-- ── resolve_insert: block boundary (no cross-block sibling) ──────────────────

T["resolve_insert: insert at start of block with no tasks above → no cross-block sibling"] = function()
  -- Two-block render: block 1 has task A at row 3, block 2 has task B at row N.
  -- User inserts a line as the very first insert in block 2 (walk_stop = block2_start).
  -- The walk must NOT reach task A in block 1.

  local src_a_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] Task A" }, src_a_path)
  local src_b_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] Task B" }, src_b_path)

  -- Buffer with two fence blocks.
  local render_bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(render_bufnr, 0, -1, false, {
    "```tasks", -- 0
    "not done", -- 1
    "```", -- 2
    "", -- 3
    "```tasks", -- 4
    "done", -- 5
    "```", -- 6
  })

  -- Draw block 1 (fence 0-2): task A inserted at row 3 (buffer shifts).
  draw_mod.draw(render_bufnr, { 0, 2 }, {
    {
      kind = "task",
      text = "- [ ] Task A",
      src_path = src_a_path,
      src_line = 1,
      src_hash = vim.fn.sha256("- [ ] Task A"):sub(1, 16),
    },
  })
  -- After block 1 draw: task A at row 3; blank at row 4; block 2 fence at rows 5-7.

  -- Draw block 2 (fence now at 5-7): task B inserted at row 8.
  draw_mod.draw(render_bufnr, { 5, 7 }, {
    {
      kind = "task",
      text = "- [ ] Task B",
      src_path = src_b_path,
      src_line = 1,
      src_hash = vim.fn.sha256("- [ ] Task B"):sub(1, 16),
    },
  })
  -- Task B now at row 8.  Block 2 inserted_range = {8, 8}.

  -- Simulate insert at row 8 (user inserts at the same position as task B,
  -- pushing task B to row 9 in the live buffer).  For the purpose of this test
  -- we test with after_lnum = 8 where block_start = 8, making the walk range
  -- empty → no sibling found → falls to capture_file.
  local cap_path = vim.fn.tempname() .. ".md"

  with_capture_file(cap_path, function()
    edit_mod.resolve_insert(render_bufnr, 8, "- [ ] Inserted at top of block 2")
  end)

  -- Task A's source must NOT have been modified.
  local lines_a = vim.fn.readfile(src_a_path)
  eq(lines_a[1], "- [ ] Task A")
  eq(#lines_a, 1)

  -- New task must be in capture_file instead.
  eq(vim.fn.filereadable(cap_path), 1)
  local lines_cap = vim.fn.readfile(cap_path)
  eq(lines_cap[1], "- [ ] Inserted at top of block 2")

  draw_mod.clear(render_bufnr)
end

return T
