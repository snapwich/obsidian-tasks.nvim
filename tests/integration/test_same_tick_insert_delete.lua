-- tests/integration/test_same_tick_insert_delete.lua
-- Phase 5d: same-tick INSERT + DELETE coordination (carried P5c handoff).
--
-- When ONE flush both deletes a source line AND inserts a new row whose anchor
-- sits BELOW the deleted line, the anchor's meta.source_row is a PRE-delete
-- snapshot (too high by the number of deleted source lines above it).  flush()
-- applies the delete to disk FIRST, so without coordination the insert would use
-- the stale source_row and land one line too low — overwriting / displacing an
-- unrelated source line.  flush() re-locates the anchor against the post-delete
-- disk by its verbatim task_text so the new line lands after the anchor's CURRENT
-- position.
--
-- Driven through flush() directly with injected snapshots so the
-- anchor-below-delete geometry (hard to produce via pure keystrokes) is exact.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local edit_mod = require("obsidian-tasks.render.edit")
local managed = require("obsidian-tasks.render.managed")

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

local function meta(src_path, source_row, task_text, source_indent, depth)
  return {
    source_file = src_path,
    source_row = source_row,
    task_text = task_text,
    rendered_text = task_text,
    source_indent = source_indent,
    depth = depth,
    tree_kind = "task",
  }
end

T["same-tick: delete-above + insert below a lower anchor lands correctly"] = function()
  render.configure({ default_folded = false })

  -- Source layout (flat siblings — keeps the disk arithmetic obvious):
  --   row 0  - [ ] Root #task          (deleted this tick — ABOVE the anchor)
  --   row 1  - [ ] Anchor #task         (insert anchor — survives, BELOW delete)
  --   row 2  - [ ] Sibling untouched #task   (must never be corrupted)
  local src_path = make_tmpfile({
    "- [ ] Root #task",
    "- [ ] Anchor #task",
    "- [ ] Sibling untouched #task",
  })

  -- Dashboard buffer.  Managed rows are at buffer rows 3 (Anchor) and 4 (Sibling)
  -- — Root has already been deleted from the buffer (its dd happened this tick).
  --   row 0..2  ```tasks / show tree / ```
  --   row 3     Anchor   (managed)
  --   row 4     INSERT   (new typed task, no meta)
  --   row 5     Sibling  (managed)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "```tasks",
    "show tree",
    "```",
    "- [ ] Anchor #task",
    "- [ ] Child N #task",
    "- [ ] Sibling untouched #task",
  })
  vim.b[bufnr].obsidian_tasks_dashboard = true

  -- Inject the PRE-delete snapshot: Anchor still carries source_row = 1 and
  -- Sibling source_row = 2 (their positions BEFORE Root is removed from disk).
  -- Root's meta is parked at a buffer row that no longer exists (row 99) so flush's
  -- nil-text fallback classifies it as a DELETE of source_row 0.
  local meta_by_row = {
    [3] = meta(src_path, 1, "- [ ] Anchor #task", "", 0),
    [5] = meta(src_path, 2, "- [ ] Sibling untouched #task", "", 0),
    [99] = meta(src_path, 0, "- [ ] Root #task", "", 0), -- buffer row 99 → nil text → DELETE
  }
  revert._set_snapshots_for_test(bufnr, { { 3, 5 } }, meta_by_row)

  edit_mod.flush(bufnr)

  local src = read_file(src_path)
  local joined = table.concat(src, "\n")

  eq(joined:find("Root", 1, true) == nil, true, "Root must be deleted: " .. vim.inspect(src))
  eq(joined:find("Anchor", 1, true) ~= nil, true, "Anchor must survive: " .. vim.inspect(src))
  eq(joined:find("Child N", 1, true) ~= nil, true, "new task must be inserted: " .. vim.inspect(src))
  -- CRITICAL: the sibling line must be byte-intact.  A stale anchor source_row (1
  -- instead of the post-delete 0) would make insert_after_anchor land the new line
  -- AFTER source row 1 (= onto/over the Sibling slot), corrupting it.
  eq(
    joined:find("- [ ] Sibling untouched #task", 1, true) ~= nil,
    true,
    "sibling must be byte-intact — no stale-anchor corruption: " .. vim.inspect(src)
  )
  -- The new task must appear IMMEDIATELY after the Anchor (its true position),
  -- before the Sibling.
  local anchor_i, new_i, sib_i
  for i, l in ipairs(src) do
    if l:find("Anchor", 1, true) then
      anchor_i = i
    end
    if l:find("Child N", 1, true) then
      new_i = i
    end
    if l:find("Sibling", 1, true) then
      sib_i = i
    end
  end
  eq(anchor_i ~= nil and new_i ~= nil and sib_i ~= nil, true, "all three lines present: " .. vim.inspect(src))
  eq(new_i == anchor_i + 1, true, "new task must land directly after Anchor: " .. vim.inspect(src))
  eq(sib_i == new_i + 1, true, "Sibling must follow the new task, uncorrupted: " .. vim.inspect(src))

  render.clear_buffer(bufnr)
  managed.clear_buffer(bufnr)
  revert._cleanup(bufnr)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  pcall(vim.fn.delete, src_path)
end

return T
