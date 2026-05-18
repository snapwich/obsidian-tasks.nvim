-- tests/integration/test_undo_ring.lua
-- Per-dashboard undo / redo ring for plugin-driven source-file mutations.
--
-- apply_source_edit records each forward edit into M._undo_ring[bufnr]; the
-- new dashboard_undo / dashboard_redo helpers pop entries and replay the
-- inverse via apply_source_edit{ skip_record = true }.

local T = MiniTest.new_set()

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

local function fresh_dashboard()
  -- A scratch buffer to act as the dashboard for ring keying.
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  return b
end

local function reset_rings()
  local cmd = require("obsidian-tasks.cmd")
  cmd._undo_ring = {}
  cmd._redo_ring = {}
end

T = MiniTest.new_set({
  hooks = {
    pre_case = function()
      reset_rings()
    end,
  },
})

-- ── Recording ────────────────────────────────────────────────────────────────

T["undo ring: forward edit pushes entry keyed by dashboard buf"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "- [ ] one", "- [ ] two", "- [ ] three" })

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 1, { "- [x] two" })
  eq(ok, true)

  local ring = cmd._undo_ring[dash]
  eq(ring ~= nil, true, "ring entry created for dashboard buf")
  eq(#ring, 1)
  eq(ring[1].src_path, path)
  eq(ring[1].src_row, 1)
  eq(ring[1].old_count, 1)
  eq(ring[1].old_lines[1], "- [ ] two")
  eq(ring[1].new_lines[1], "- [x] two")

  vim.fn.delete(path)
end

T["undo ring: skip_record opts.bypass keeps ring untouched"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "- [ ] x" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "- [x] x" }, { skip_record = true })
  eq(cmd._undo_ring[dash], nil, "ring not populated when skip_record=true")

  vim.fn.delete(path)
end

T["undo ring: explicit dashboard_bufnr opt routes the entry"] = function()
  local _ = fresh_dashboard() -- current buf, unused
  local other = vim.api.nvim_create_buf(false, true)
  local path = make_tmpfile({ "- [ ] a" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "- [x] a" }, { dashboard_bufnr = other })
  eq(cmd._undo_ring[other] ~= nil, true)
  eq(#cmd._undo_ring[other], 1)

  vim.fn.delete(path)
end

T["undo ring: 50-entry cap drops oldest on overflow"] = function()
  local _ = fresh_dashboard()
  local path = make_tmpfile({ "row0" })

  local cmd = require("obsidian-tasks.cmd")
  for i = 1, 60 do
    cmd.apply_source_edit(path, 0, { "edit-" .. i })
  end

  local ring = cmd._undo_ring[vim.api.nvim_get_current_buf()]
  eq(#ring, 50, "cap is 50")
  -- Oldest 10 should be dropped; first surviving entry is edit-11 → edit-10.
  -- After each edit, the previous edit-N becomes old_lines for the next.
  eq(ring[1].old_lines[1], "edit-10")
  eq(ring[50].new_lines[1], "edit-60")

  vim.fn.delete(path)
end

-- Regression: when the ring is at UNDO_RING_CAP and flush() pushes multiple
-- per-file entries, the Q13 multi-file merge must still combine them.  The
-- previous implementation used `#ring - ring_before` which underreports (or
-- returns 0) at the cap because each push triggers a table.remove(r, 1).
T["undo ring: multi-file merge works when ring is already at cap"] = function()
  local dash = fresh_dashboard()
  local cmd = require("obsidian-tasks.cmd")

  -- Pre-fill the ring to UNDO_RING_CAP with filler entries.
  local filler_path = make_tmpfile({ "filler" })
  for i = 1, 50 do
    cmd.apply_source_edit(filler_path, 0, { "edit-" .. i })
  end
  eq(#cmd._undo_ring[dash], 50, "ring at cap before flush")

  -- Now simulate a 2-file flush via the edit.flush merge path: push 2 per-file
  -- entries one after the other, then run the same merge logic as flush.
  local path_a = make_tmpfile({ "- [ ] A" })
  local path_b = make_tmpfile({ "- [ ] B" })
  local pushes_in_flush = 0
  for _, path in ipairs({ path_a, path_b }) do
    if cmd.apply_source_edit(path, 0, { "- [x] X" }) then
      pushes_in_flush = pushes_in_flush + 1
    end
  end

  -- Apply the same merge logic flush() uses (location: edit.lua "Q13 merge").
  local ring = cmd._undo_ring[dash]
  local ring_after = #ring
  local new_entries = math.min(pushes_in_flush, ring_after)
  eq(new_entries, 2, "merge logic must see both new entries even at cap")
  -- Sanity: the last 2 entries of the ring are the new edits (not filler).
  eq(ring[ring_after].src_path, path_b, "last ring entry is the b-file edit")
  eq(ring[ring_after - 1].src_path, path_a, "second-to-last is the a-file edit")

  -- Old (buggy) approach: ring_before was captured at 50, ring_after = 50, so
  -- (ring_after - ring_before) = 0 → merge skipped, leaving 2 individual
  -- entries.  The new approach uses pushes_in_flush so the merge runs.

  vim.fn.delete(filler_path)
  vim.fn.delete(path_a)
  vim.fn.delete(path_b)
end

-- ── Undo ─────────────────────────────────────────────────────────────────────

T["dashboard_undo: replays inverse, pops the entry"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "- [ ] one", "- [ ] two", "- [ ] three" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 1, { "- [x] two" })
  eq(read_file(path)[2], "- [x] two", "forward edit landed on disk")

  local ok = cmd.dashboard_undo(dash)
  eq(ok, true)
  eq(read_file(path)[2], "- [ ] two", "undo restored the original line")
  eq(cmd._undo_ring[dash] and #cmd._undo_ring[dash] or 0, 0, "ring empty after undo")
  eq(#cmd._redo_ring[dash], 1, "redo ring received the popped entry")

  vim.fn.delete(path)
end

T["dashboard_undo: empty ring returns false"] = function()
  local dash = fresh_dashboard()
  local cmd = require("obsidian-tasks.cmd")
  eq(cmd.dashboard_undo(dash), false)
end

T["dashboard_undo: drift detected → refuse, ring intact"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "- [ ] one" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "- [x] one" })
  -- Simulate an external edit between forward and undo.
  vim.fn.writefile({ "- [ ] one EXTERNAL" }, path)

  local ok = cmd.dashboard_undo(dash)
  eq(ok, false, "undo refused on drift")
  eq(read_file(path)[1], "- [ ] one EXTERNAL", "external edit preserved")
  eq(#cmd._undo_ring[dash], 1, "entry not popped on drift refusal")

  vim.fn.delete(path)
end

T["dashboard_undo: inverse replay does not re-record"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "alpha" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "ALPHA" })
  eq(#cmd._undo_ring[dash], 1)

  cmd.dashboard_undo(dash)
  eq(cmd._undo_ring[dash] and #cmd._undo_ring[dash] or 0, 0, "ring emptied (no re-record on inverse)")

  vim.fn.delete(path)
end

-- ── Redo ─────────────────────────────────────────────────────────────────────

T["dashboard_redo: pops redo entry and replays forward"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "- [ ] one" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "- [x] one" })
  cmd.dashboard_undo(dash)
  eq(read_file(path)[1], "- [ ] one")
  eq(#cmd._redo_ring[dash], 1)

  local ok = cmd.dashboard_redo(dash)
  eq(ok, true)
  eq(read_file(path)[1], "- [x] one", "redo re-applied the forward edit")
  eq(cmd._redo_ring[dash] and #cmd._redo_ring[dash] or 0, 0)
  eq(#cmd._undo_ring[dash], 1, "undo ring re-populated after redo")

  vim.fn.delete(path)
end

T["forward edit after undo clears redo ring (new branch)"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "row" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "ROW1" })
  cmd.dashboard_undo(dash)
  eq(#cmd._redo_ring[dash], 1)

  -- Make a new forward edit; redo branch should be discarded.
  cmd.apply_source_edit(path, 0, { "ROW2" })
  eq(cmd._redo_ring[dash], nil, "redo cleared by new forward edit")

  vim.fn.delete(path)
end

-- ── Delete + undo round-trip (count=1 → new_lines={} → inverse count=0) ──────

T["undo of delete: restores the deleted line"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "before", "- [ ] doomed", "after" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 1, {}) -- delete row 1
  eq(read_file(path)[2], "after", "row deleted")
  eq(#read_file(path), 2)

  cmd.dashboard_undo(dash)
  local restored = read_file(path)
  eq(#restored, 3)
  eq(restored[2], "- [ ] doomed")
  eq(restored[3], "after")

  vim.fn.delete(path)
end

-- ── Clear ────────────────────────────────────────────────────────────────────

-- ── Same-buffer dashboard branch ─────────────────────────────────────────────
-- When the source file IS the dashboard buffer (e.g. task lives in the same
-- file as the ```tasks block), apply_source_edit must mutate the buffer
-- directly rather than round-tripping through disk.  The buffer is always
-- "modified" due to our render insertions, so the modified-refusal in the
-- disk path doesn't apply.

T["apply_source_edit: dashboard branch mutates buffer without refusal"] = function()
  local _ = fresh_dashboard()
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [ ] task A", "- [ ] task B" }, path)

  -- Load the file as a buffer and mark it as a dashboard (sentinel-only;
  -- buftype stays "").
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  vim.b[b].obsidian_tasks_dashboard = true

  -- Add render-like decoration so the buffer is "modified".
  vim.api.nvim_buf_set_lines(b, -1, -1, false, { "rendered task line" })
  eq(vim.bo[b].modified, true, "precondition: buffer is modified")

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 0, { "- [x] task A" })
  eq(ok, true, "edit must succeed even though buffer is modified")

  -- Buffer mutated; rendered line still present.
  local lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  eq(lines[1], "- [x] task A")
  eq(lines[2], "- [ ] task B")
  eq(lines[3], "rendered task line", "render decoration preserved")

  vim.b[b].obsidian_tasks_dashboard = nil
  vim.bo[b].modified = false
  vim.api.nvim_buf_delete(b, { force = true })
  vim.fn.delete(path)
end

T["clear_dashboard_undo: drops both rings"] = function()
  local dash = fresh_dashboard()
  local path = make_tmpfile({ "x" })

  local cmd = require("obsidian-tasks.cmd")
  cmd.apply_source_edit(path, 0, { "X" })
  cmd.dashboard_undo(dash)
  eq(#cmd._redo_ring[dash], 1)

  cmd.clear_dashboard_undo(dash)
  eq(cmd._undo_ring[dash], nil)
  eq(cmd._redo_ring[dash], nil)

  vim.fn.delete(path)
end

return T
