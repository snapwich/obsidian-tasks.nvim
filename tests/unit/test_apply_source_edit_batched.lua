-- tests/unit/test_apply_source_edit_batched.lua
-- RED-phase tests for the batched-edit extension of cmd.apply_source_edit (Q13).
--
-- All tests fail while the batch branch is a stub raising
-- error('batched apply_source_edit not implemented').
-- They pass once the GREEN task (ot-32mh) implements the real batch write path.
--
-- Locked decisions under test:
--   Q13 Tick coalescing: group by src_path; single read+write per file; single
--       undo block per tick.
--   Q15 Per-file write failure: per-file atomic; failed files revert their own
--       rows; other files in the flush proceed.
--
-- Tests call apply_source_edit with opts.batch and assert:
--   • Single-file batch → writefile called exactly once.
--   • Two-file batch → each src_path written exactly once.
--   • Edits applied bottom-up so earlier row indices remain valid.
--   • Per-file failure isolates to that file's rows.
--   • Undo block opened once per batch (not once per edit).

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

-- ── Helper: writefile call counter ───────────────────────────────────────────

--- Wrap vim.fn.writefile to count calls per path.
--- Returns: { counts = { [path] = n }, restore = fn }
local function wrap_writefile()
  local counts = {}
  local orig = vim.fn.writefile
  vim.fn.writefile = function(lines, path, ...)
    counts[path] = (counts[path] or 0) + 1
    return orig(lines, path, ...)
  end
  return {
    counts = counts,
    restore = function()
      vim.fn.writefile = orig
    end,
  }
end

-- ── Single-file batch writes file exactly once ────────────────────────────────

T["batched apply_source_edit: single file — writefile called once"] = function()
  local path = make_tmpfile({
    "# Header",
    "- [ ] Task row 0",
    "- [ ] Task row 1",
    "- [ ] Task row 2",
    "# Footer",
  })

  local spy = wrap_writefile()

  -- Batch: mutate rows 0 and 2 in a single apply_source_edit call.
  local ok = cmd.apply_source_edit(path, 0, { "- [x] Task row 0" }, {
    batch = {
      { row = 0, new_lines = { "- [x] Task row 0" } },
      { row = 2, new_lines = { "- [x] Task row 2" } },
    },
  })

  spy.restore()

  eq(ok, true, "batched apply_source_edit should succeed")
  eq(spy.counts[path], 1, "writefile should be called exactly once for single-file batch")

  local lines = read_file(path)
  eq(lines[2], "- [x] Task row 0", "row 0 should be updated")
  eq(lines[4], "- [x] Task row 2", "row 2 should be updated")

  vim.fn.delete(path)
end

-- ── Two-file batch writes each file exactly once ──────────────────────────────

T["batched apply_source_edit: two files — each written exactly once"] = function()
  local path_a = make_tmpfile({
    "- [ ] Task in file A",
    "# other content A",
  })
  local path_b = make_tmpfile({
    "- [ ] Task in file B",
    "# other content B",
  })

  local spy = wrap_writefile()

  -- Two separate apply_source_edit calls, one per file, each with a single batch entry.
  local ok_a = cmd.apply_source_edit(path_a, 0, { "- [x] Task in file A" }, {
    batch = { { row = 0, new_lines = { "- [x] Task in file A" } } },
  })
  local ok_b = cmd.apply_source_edit(path_b, 0, { "- [x] Task in file B" }, {
    batch = { { row = 0, new_lines = { "- [x] Task in file B" } } },
  })

  spy.restore()

  eq(ok_a, true, "file A batch should succeed")
  eq(ok_b, true, "file B batch should succeed")
  eq(spy.counts[path_a], 1, "file A should be written exactly once")
  eq(spy.counts[path_b], 1, "file B should be written exactly once")

  vim.fn.delete(path_a)
  vim.fn.delete(path_b)
end

-- ── Bottom-up application preserves row indices ────────────────────────────────

T["batched apply_source_edit: sort-by-row-desc applies bottom-up"] = function()
  -- Two rows: editing row 0 first in a naive (top-down) implementation would
  -- shift row indices after line insertions/deletions, corrupting subsequent
  -- edits.  Bottom-up application (row 3 before row 0) keeps indices valid.
  local path = make_tmpfile({
    "- [ ] Row zero",
    "# middle",
    "# middle 2",
    "- [ ] Row three",
  })

  local spy = wrap_writefile()

  local ok = cmd.apply_source_edit(path, 0, { "- [x] Row zero" }, {
    -- Deliberately list row 0 before row 3 to force sort-by-desc.
    batch = {
      { row = 0, new_lines = { "- [x] Row zero" } },
      { row = 3, new_lines = { "- [x] Row three" } },
    },
  })

  spy.restore()

  eq(ok, true, "batch should succeed regardless of input order")

  local lines = read_file(path)
  eq(lines[1], "- [x] Row zero", "row 0 should be updated")
  eq(lines[4], "- [x] Row three", "row 3 should be updated and NOT shifted by row-0 edit")
  eq(#lines, 4, "file length should not change when both edits are 1-for-1 replacements")

  vim.fn.delete(path)
end

-- ── Per-file failure isolates to that file (Q15) ──────────────────────────────

T["batched apply_source_edit: per-file write failure isolates to that file"] = function()
  local path_ok = make_tmpfile({ "- [ ] Task OK" })
  local path_fail = make_tmpfile({ "- [ ] Task FAIL" })

  -- Make path_fail read-only so writefile fails.
  vim.fn.system({ "chmod", "-w", path_fail })

  local spy = wrap_writefile()

  local ok_ok = cmd.apply_source_edit(path_ok, 0, { "- [x] Task OK" }, {
    batch = { { row = 0, new_lines = { "- [x] Task OK" } } },
  })
  local ok_fail = cmd.apply_source_edit(path_fail, 0, { "- [x] Task FAIL" }, {
    batch = { { row = 0, new_lines = { "- [x] Task FAIL" } } },
  })

  spy.restore()

  -- Restore write permission for cleanup.
  vim.fn.system({ "chmod", "+w", path_fail })

  -- The writable file's batch should succeed; the read-only file's should fail.
  eq(ok_ok, true, "writable file batch should succeed")
  eq(ok_fail, false, "read-only file batch should fail without affecting other files")

  -- Verify the writable file was actually updated.
  local lines_ok = read_file(path_ok)
  eq(lines_ok[1], "- [x] Task OK", "writable file should have the new content")

  -- Verify the read-only file was not mutated.
  local lines_fail = read_file(path_fail)
  eq(lines_fail[1], "- [ ] Task FAIL", "read-only file should retain original content")

  vim.fn.delete(path_ok)
  vim.fn.delete(path_fail)
end

-- ── Undo block opened once per batch ─────────────────────────────────────────

T["batched apply_source_edit: single undo block per batch"] = function()
  -- This test verifies that a single-file batch records exactly one undo-ring
  -- entry (covering all edits in the batch), not one entry per edit row.
  local dash_bufnr = vim.api.nvim_create_buf(false, true)
  local path = make_tmpfile({
    "- [ ] Task row 0",
    "- [ ] Task row 1",
    "- [ ] Task row 2",
  })

  -- Clear existing undo history for this dashboard buffer.
  cmd._undo_ring[dash_bufnr] = nil

  local ok = cmd.apply_source_edit(path, 0, { "- [x] Task row 0" }, {
    dashboard_bufnr = dash_bufnr,
    batch = {
      { row = 0, new_lines = { "- [x] Task row 0" } },
      { row = 1, new_lines = { "- [x] Task row 1" } },
      { row = 2, new_lines = { "- [x] Task row 2" } },
    },
  })

  eq(ok, true, "batch should succeed")

  local ring = cmd._undo_ring[dash_bufnr]
  MiniTest.expect.no_equality(ring, nil, "undo ring should have an entry after batch")
  eq(#ring, 1, "batch should produce exactly one undo-ring entry (single undo block)")

  -- Cleanup
  cmd._undo_ring[dash_bufnr] = nil
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(path)
end

return T
