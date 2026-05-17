-- tests/unit/test_insert_after_anchor.lua
-- RED-phase unit tests for cmd.insert_after_anchor (Q11).
--
-- ALL tests FAIL while insert_after_anchor is a stub raising
-- error('insert_after_anchor not implemented').
-- They pass once the GREEN task (ot-pf3a) implements the real algorithm.
--
-- Locked decision under test:
--   Q11 Source-side insert position: after the anchor's continuation block.
--       Walk past indented children + blank-followed-by-indented.
--       New task adopts the anchor's indent level.
--
-- Continuation rules (Q11):
--   A row is part of the anchor's continuation block if it is:
--     (a) Non-blank AND indented more than anchor_indent, OR
--     (b) A blank line immediately followed by a non-blank row indented more
--         than anchor_indent (blank-followed-by-indented = continuation).
--   A blank line followed by a row NOT indented more than anchor_indent
--   ends the continuation (the blank is NOT part of the block).
--
-- Insert position = first row NOT in the continuation block.

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

-- ── No continuation: inserts immediately after anchor row ─────────────────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: when anchor has no continuation block (next row is at the
-- same indent level or the file ends), the new task is inserted immediately
-- after anchor_row.

T["insert_after_anchor: no continuation — inserts at anchor+1"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0, indent 0
    "- [ ] Next task", -- row 1, indent 0 (not a continuation)
  })

  local ok = cmd.insert_after_anchor(path, 0, 0, "- [ ] New task")

  eq(ok, true, "insert_after_anchor should succeed")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Anchor task", "anchor row unchanged at row 0")
  eq(lines[2], "- [ ] New task", "new task inserted at row 1 (anchor+1)")
  eq(lines[3], "- [ ] Next task", "original row 1 pushed down to row 2")
  eq(#lines, 3, "file should have 3 lines")

  vim.fn.delete(path)
end

-- ── Indented children: walks past children, inserts after last child ──────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: non-blank lines indented more than anchor_indent are
-- continuation lines; walk past all of them before inserting.

T["insert_after_anchor: indented children — inserts after last child"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0, indent 0
    "  - [ ] Child one", -- row 1, indent 2 > 0 → continuation
    "  - [ ] Child two", -- row 2, indent 2 > 0 → continuation
    "- [ ] Sibling task", -- row 3, indent 0 → end of continuation
  })

  local ok = cmd.insert_after_anchor(path, 0, 0, "- [ ] New task")

  eq(ok, true, "insert_after_anchor should succeed")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Anchor task", "anchor unchanged at row 0")
  eq(lines[2], "  - [ ] Child one", "child one unchanged at row 1")
  eq(lines[3], "  - [ ] Child two", "child two unchanged at row 2")
  eq(lines[4], "- [ ] New task", "new task inserted after last child (row 3)")
  eq(lines[5], "- [ ] Sibling task", "sibling pushed down to row 4")
  eq(#lines, 5, "file should have 5 lines")

  vim.fn.delete(path)
end

-- ── Blank then dedented: stops at blank (end of continuation) ─────────────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: a blank line followed by a row NOT indented more than
-- anchor_indent is NOT part of the continuation.  The insert position is
-- immediately after anchor_row (before the blank separator).

T["insert_after_anchor: blank then dedented — stops at blank, inserts before it"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0, indent 0
    "", -- row 1, blank → look-ahead
    "- [ ] Other task", -- row 2, indent 0 ≤ 0 → row 1 is NOT continuation
  })

  local ok = cmd.insert_after_anchor(path, 0, 0, "- [ ] New task")

  eq(ok, true, "insert_after_anchor should succeed")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Anchor task", "anchor unchanged at row 0")
  eq(lines[2], "- [ ] New task", "new task inserted at row 1 (before blank)")
  eq(lines[3], "", "blank pushed to row 2")
  eq(lines[4], "- [ ] Other task", "other task at row 3")
  eq(#lines, 4, "file should have 4 lines")

  vim.fn.delete(path)
end

-- ── Blank then indented: walks past blank+indented as continuation ─────────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: a blank line followed by a row indented more than
-- anchor_indent IS part of the continuation block; walk through both.

T["insert_after_anchor: blank then indented — walks past blank+indented"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0, indent 0
    "", -- row 1, blank → look-ahead
    "  - [ ] Child task", -- row 2, indent 2 > 0 → row 1 is part of continuation
    "- [ ] Sibling task", -- row 3, indent 0 → end of continuation
  })

  local ok = cmd.insert_after_anchor(path, 0, 0, "- [ ] New task")

  eq(ok, true, "insert_after_anchor should succeed")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Anchor task", "anchor unchanged at row 0")
  eq(lines[2], "", "blank at row 1 (still part of continuation block)")
  eq(lines[3], "  - [ ] Child task", "child at row 2 (part of continuation block)")
  eq(lines[4], "- [ ] New task", "new task inserted after continuation (row 3)")
  eq(lines[5], "- [ ] Sibling task", "sibling pushed down to row 4")
  eq(#lines, 5, "file should have 5 lines")

  vim.fn.delete(path)
end

-- ── New task adopts anchor's indent ──────────────────────────────────────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: the new_task_line is inserted verbatim; the caller is
-- responsible for applying the anchor's indent.  This test passes
-- new_task_line already indented at anchor_indent=2 (two leading spaces).

T["insert_after_anchor: indented anchor — new task adopts anchor's indent"] = function()
  local path = make_tmpfile({
    "- [ ] Root task", -- row 0, indent 0
    "  - [ ] Anchor child", -- row 1, indent 2
    "  - [ ] Sibling child", -- row 2, indent 2 (not a continuation of row 1)
  })

  -- Caller passes the line pre-indented to match anchor_indent=2.
  local ok = cmd.insert_after_anchor(path, 1, 2, "  - [ ] New child")

  eq(ok, true, "insert_after_anchor should succeed for indented anchor")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Root task", "root unchanged at row 0")
  eq(lines[2], "  - [ ] Anchor child", "anchor unchanged at row 1")
  eq(lines[3], "  - [ ] New child", "new child at anchor's indent (row 2)")
  eq(lines[4], "  - [ ] Sibling child", "sibling pushed down to row 3")
  eq(#lines, 4, "file should have 4 lines")

  vim.fn.delete(path)
end

-- ── Inserting at end of file (anchor is last row) ─────────────────────────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: when the anchor is the last row of the file (no continuation,
-- no following row), the new task is appended at EOF.

T["insert_after_anchor: anchor is last row — appends at EOF"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0 (only row in file)
  })

  local ok = cmd.insert_after_anchor(path, 0, 0, "- [ ] New task")

  eq(ok, true, "insert_after_anchor at EOF should succeed")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Anchor task", "anchor unchanged at row 0")
  eq(lines[2], "- [ ] New task", "new task appended at EOF (row 1)")
  eq(#lines, 2, "file should have 2 lines")

  vim.fn.delete(path)
end

-- ── Anchor with continuation at EOF (no following row after last child) ────────
--
-- RED: FAILS — stub raises error('insert_after_anchor not implemented').
-- GREEN contract: when the anchor's continuation block extends to the end of
-- the file, the new task is appended after the last continuation row.

T["insert_after_anchor: continuation extends to EOF — appends after last continuation"] = function()
  local path = make_tmpfile({
    "- [ ] Anchor task", -- row 0, indent 0
    "  - [ ] Child one", -- row 1, indent 2 → continuation
    "  - [ ] Child two", -- row 2, indent 2 → continuation (last row)
  })

  local ok = cmd.insert_after_anchor(path, 0, 0, "- [ ] New task")

  eq(ok, true, "insert_after_anchor with continuation at EOF should succeed")

  local lines = read_file(path)
  eq(lines[1], "- [ ] Anchor task", "anchor unchanged at row 0")
  eq(lines[2], "  - [ ] Child one", "child one unchanged at row 1")
  eq(lines[3], "  - [ ] Child two", "child two unchanged at row 2")
  eq(lines[4], "- [ ] New task", "new task appended after last continuation (row 3)")
  eq(#lines, 4, "file should have 4 lines")

  vim.fn.delete(path)
end

return T
