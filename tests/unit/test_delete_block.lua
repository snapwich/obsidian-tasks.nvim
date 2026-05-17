-- tests/unit/test_delete_block.lua
-- RED-phase unit tests for cmd.delete_block (Q14).
--
-- ALL tests FAIL while delete_block is a stub raising
-- error('delete_block not implemented').
-- They pass once the GREEN task (ot-vz1m) implements the real algorithm.
--
-- Locked decision under test:
--   Q14 Delete with continuation: block-aware delete of a task line and all
--       its continuation lines.  Continuation rules:
--         (a) Non-blank line indented more than task_indent → continuation.
--         (b) Blank line immediately followed by a non-blank row indented more
--             than task_indent → blank + following row are continuation.
--         (c) Blank line NOT followed by an indented row ends the continuation;
--             the blank itself is NOT deleted.
--
-- Count = last_continuation_row - task_row + 1 (applies to apply_source_edit).

local T = MiniTest.new_set()

local cmd = require("obsidian-tasks.cmd")

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

-- ── No continuation: deletes just the task line ───────────────────────────────
--
-- RED: FAILS — stub raises error('delete_block not implemented').
-- GREEN contract: when the task has no continuation (next row is at same or
-- lower indent, or file ends), only task_row is deleted (count=1).

T["delete_block: no continuation — deletes only the task line"] = function()
  local path = make_tmpfile({
    "- [ ] Task to delete", -- row 0
    "- [ ] Other task", -- row 1 (not a continuation)
  })

  local ok = cmd.delete_block(path, 0, 0)

  eq(ok, true, "delete_block should succeed")

  local lines = read_file(path)
  eq(#lines, 1, "file should have 1 line (task deleted)")
  eq(lines[1], "- [ ] Other task", "other task now at row 0")

  vim.fn.delete(path)
end

-- ── Indented children: deletes task + all indented children ──────────────────
--
-- RED: FAILS — stub raises error('delete_block not implemented').
-- GREEN contract: all non-blank rows indented more than task_indent immediately
-- following task_row are included in the delete range.

T["delete_block: indented children — deletes task and all children"] = function()
  local path = make_tmpfile({
    "- [ ] Task with children", -- row 0, indent 0
    "  - [ ] Child one", -- row 1, indent 2 → continuation
    "  - [ ] Child two", -- row 2, indent 2 → continuation
    "- [ ] Sibling task", -- row 3, indent 0 → end of continuation
  })

  local ok = cmd.delete_block(path, 0, 0)

  eq(ok, true, "delete_block should succeed")

  local lines = read_file(path)
  eq(#lines, 1, "file should have 1 line (task + 2 children deleted, sibling remains)")
  eq(lines[1], "- [ ] Sibling task", "sibling now at row 0")

  vim.fn.delete(path)
end

-- ── Blank then dedented: deletes only task, blank stays ───────────────────────
--
-- RED: FAILS — stub raises error('delete_block not implemented').
-- GREEN contract: a blank line followed by a dedented row ends the continuation.
-- The blank line itself is NOT deleted (it belongs to the surrounding structure,
-- not to the task block).

T["delete_block: blank then dedented — deletes task only, blank and other stay"] = function()
  local path = make_tmpfile({
    "- [ ] Task to delete", -- row 0, indent 0
    "", -- row 1, blank → look ahead
    "- [ ] Other task", -- row 2, indent 0 ≤ 0 → blank is NOT continuation
  })

  local ok = cmd.delete_block(path, 0, 0)

  eq(ok, true, "delete_block should succeed")

  local lines = read_file(path)
  eq(#lines, 2, "file should have 2 lines (only task deleted; blank + other remain)")
  eq(lines[1], "", "blank line still at row 0")
  eq(lines[2], "- [ ] Other task", "other task still at row 1")

  vim.fn.delete(path)
end

-- ── Blank then indented: deletes task + blank + indented continuation ─────────
--
-- RED: FAILS — stub raises error('delete_block not implemented').
-- GREEN contract: a blank line followed by an indented row IS part of the
-- continuation block.  Both the blank and the following indented lines are
-- deleted together with the task.

T["delete_block: blank then indented — deletes task, blank, and continuation"] = function()
  local path = make_tmpfile({
    "- [ ] Task with gap-child", -- row 0, indent 0
    "", -- row 1, blank → look ahead
    "  - [ ] Child via blank", -- row 2, indent 2 > 0 → rows 1+2 are continuation
    "- [ ] Sibling task", -- row 3, indent 0 → end of continuation
  })

  local ok = cmd.delete_block(path, 0, 0)

  eq(ok, true, "delete_block should succeed")

  local lines = read_file(path)
  eq(#lines, 1, "file should have 1 line (task + blank + child deleted; sibling remains)")
  eq(lines[1], "- [ ] Sibling task", "sibling now at row 0")

  vim.fn.delete(path)
end

-- ── Last task in file: deletes without out-of-bounds error ───────────────────
--
-- RED: FAILS — stub raises error('delete_block not implemented').
-- GREEN contract: when the task is the last (or only) row in the file, the
-- function deletes it cleanly without indexing past end-of-file.

T["delete_block: last task in file — deletes cleanly, no out-of-bounds"] = function()
  local path = make_tmpfile({
    "- [ ] Only task in file", -- row 0 (only row)
  })

  local ok = cmd.delete_block(path, 0, 0)

  eq(ok, true, "delete_block of last task should succeed")

  local lines = read_file(path)
  eq(#lines, 0, "file should be empty after deleting the only task")

  vim.fn.delete(path)
end

-- ── Mixed: blank+indented followed by blank+dedented ─────────────────────────
--
-- RED: FAILS — stub raises error('delete_block not implemented').
-- GREEN contract: chain of continuations terminates at the first blank whose
-- lookahead row is dedented.

T["delete_block: mixed continuation — stops at blank-followed-by-dedented"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0, indent 0
    "", -- row 1, blank → look ahead
    "  - [ ] Child via blank", -- row 2, indent 2 → rows 1+2 continuation
    "", -- row 3, blank → look ahead
    "- [ ] Dedented after blank", -- row 4, indent 0 ≤ 0 → rows 3 NOT continuation
  })

  local ok = cmd.delete_block(path, 0, 0)

  eq(ok, true, "delete_block should succeed on mixed continuation chain")

  local lines = read_file(path)
  -- Rows 0, 1, 2 deleted (task + continuation via blank + indented child).
  -- Row 3 (blank) is NOT deleted (followed by dedented row 4).
  eq(#lines, 2, "file should have 2 lines (blank separator and dedented task remain)")
  eq(lines[1], "", "blank separator still at row 0")
  eq(lines[2], "- [ ] Dedented after blank", "dedented task still at row 1")

  vim.fn.delete(path)
end

return T
