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

-- ── apply_insert stub ─────────────────────────────────────────────────────────

T["apply_insert: stub does not error"] = function()
  MiniTest.expect.no_error(function()
    edit_mod.apply_insert({ after_lnum = 5, new_text = "- [ ] New task" })
  end)
end

return T
