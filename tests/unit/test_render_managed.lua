-- tests/unit/test_render_managed.lua
-- Unit tests for render/managed.lua.
-- All vim.api calls are valid because mini.test runs in headless Neovim.

local T = MiniTest.new_set()

-- ── module handle ─────────────────────────────────────────────────────────────

local managed = require("obsidian-tasks.render.managed")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]  raw lines (1-indexed)
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Collect all extmarks in the managed namespace for a buffer.
--- @param bufnr integer
--- @return table[]
local function get_managed_marks(bufnr)
  local ns = managed.namespace()
  return vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
end

--- Build a minimal task meta table.
--- @param row integer  0-indexed source row
--- @return table
local function task_meta(row)
  return {
    source_file = "/vault/note.md",
    source_row = row,
    task_text = "- [ ] task at row " .. tostring(row),
  }
end

-- ── namespace ─────────────────────────────────────────────────────────────────

T["namespace: returns a positive integer"] = function()
  local ns = managed.namespace()
  eq(type(ns), "number")
  MiniTest.expect.equality(ns > 0, true)
end

T["namespace: stable across calls"] = function()
  eq(managed.namespace(), managed.namespace())
end

T["namespace: distinct from util/extmark NS"] = function()
  local ext_ns = require("obsidian-tasks.util.extmark").NS
  MiniTest.expect.equality(managed.namespace() ~= ext_ns, true)
end

-- ── add_region / region_for_row ───────────────────────────────────────────────

T["region: region_for_row returns region for every row in range"] = function()
  local bufnr = make_buf({ "line0", "line1", "line2", "line3", "line4" })
  local mid = managed.add_region(bufnr, 1, 3) -- rows 1,2,3

  -- Every row in [1, 3] should resolve to this region.
  for row = 1, 3 do
    local result = managed.region_for_row(bufnr, row)
    MiniTest.expect.equality(result ~= nil, true)
    eq(result.mark_id, mid)
    eq(result.range[1], 1)
    eq(result.range[2], 3)
  end

  managed.clear_buffer(bufnr)
end

T["region: region_for_row returns nil outside range"] = function()
  local bufnr = make_buf({ "line0", "line1", "line2", "line3", "line4" })
  managed.add_region(bufnr, 1, 3)

  eq(managed.region_for_row(bufnr, 0), nil)
  eq(managed.region_for_row(bufnr, 4), nil)

  managed.clear_buffer(bufnr)
end

T["region: multiple regions resolved correctly"] = function()
  local bufnr = make_buf({ "l0", "l1", "l2", "l3", "l4", "l5" })
  local mid_a = managed.add_region(bufnr, 0, 1)
  local mid_b = managed.add_region(bufnr, 3, 5)

  local r0 = managed.region_for_row(bufnr, 0)
  MiniTest.expect.equality(r0 ~= nil, true)
  eq(r0.mark_id, mid_a)

  local r3 = managed.region_for_row(bufnr, 3)
  MiniTest.expect.equality(r3 ~= nil, true)
  eq(r3.mark_id, mid_b)

  -- Gap between regions
  eq(managed.region_for_row(bufnr, 2), nil)

  managed.clear_buffer(bufnr)
end

-- ── add_task / task_meta_for_row ─────────────────────────────────────────────

T["task_meta: task_meta_for_row returns stored meta"] = function()
  local bufnr = make_buf({ "line0", "line1", "line2" })
  local meta = task_meta(5)
  managed.add_task(bufnr, 1, meta)

  local got = managed.task_meta_for_row(bufnr, 1)
  MiniTest.expect.equality(got ~= nil, true)
  eq(got.source_file, meta.source_file)
  eq(got.source_row, meta.source_row)
  eq(got.task_text, meta.task_text)

  managed.clear_buffer(bufnr)
end

T["task_meta: task_meta_for_row returns nil for empty row"] = function()
  local bufnr = make_buf({ "line0", "line1" })
  managed.add_task(bufnr, 0, task_meta(0))

  eq(managed.task_meta_for_row(bufnr, 1), nil)

  managed.clear_buffer(bufnr)
end

T["task_meta: multiple tasks on distinct rows"] = function()
  local bufnr = make_buf({ "t0", "t1", "t2" })
  local meta0 = task_meta(10)
  local meta1 = task_meta(20)
  local meta2 = task_meta(30)
  managed.add_task(bufnr, 0, meta0)
  managed.add_task(bufnr, 1, meta1)
  managed.add_task(bufnr, 2, meta2)

  eq(managed.task_meta_for_row(bufnr, 0).source_row, 10)
  eq(managed.task_meta_for_row(bufnr, 1).source_row, 20)
  eq(managed.task_meta_for_row(bufnr, 2).source_row, 30)

  managed.clear_buffer(bufnr)
end

-- ── add_block / fence_marks ───────────────────────────────────────────────────

T["fence_marks: iterates added fence block"] = function()
  local bufnr = make_buf({ "```tasks", "filter", "```" })
  local fence_id = managed.add_block(bufnr, 0, 2)

  local found = false
  for mid, recorded, _ in managed.fence_marks(bufnr) do
    if mid == fence_id then
      found = true
      eq(recorded[1], 0)
      eq(recorded[2], 2)
    end
  end
  eq(found, true)

  managed.clear_buffer(bufnr)
end

T["fence_marks: iterates multiple fence blocks"] = function()
  local bufnr = make_buf({ "```tasks", "f1", "```", "prose", "```tasks", "f2", "```" })
  local id1 = managed.add_block(bufnr, 0, 2)
  local id2 = managed.add_block(bufnr, 4, 6)

  local seen = {}
  for mid, _, _ in managed.fence_marks(bufnr) do
    seen[mid] = true
  end
  eq(seen[id1], true)
  eq(seen[id2], true)

  managed.clear_buffer(bufnr)
end

T["fence_marks: empty iterator when no blocks"] = function()
  local bufnr = make_buf({ "no fences here" })
  local count = 0
  for _ in managed.fence_marks(bufnr) do
    count = count + 1
  end
  eq(count, 0)
end

-- ── extmark gravity: inserts/deletes shift marks correctly ────────────────────

T["extmark tracking: task extmark follows line after insert above"] = function()
  local bufnr = make_buf({ "line0", "task_line", "line2" })
  -- Anchor task at row 1.
  managed.add_task(bufnr, 1, task_meta(99))

  -- Insert a line before row 1 (shifts task from row 1 → row 2).
  vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { "inserted" })

  -- Task meta should now be at row 2 (extmark tracked the move).
  eq(managed.task_meta_for_row(bufnr, 2) ~= nil, true)
  eq(managed.task_meta_for_row(bufnr, 2).source_row, 99)
  -- Row 1 no longer has task meta.
  eq(managed.task_meta_for_row(bufnr, 1), nil)

  managed.clear_buffer(bufnr)
end

T["extmark tracking: region_for_row follows after lines inserted inside"] = function()
  -- Region spans rows 1..3 (3 task lines).  Insert a line inside.
  local bufnr = make_buf({ "fence_open", "t1", "t2", "t3", "fence_close" })
  managed.add_region(bufnr, 1, 3)

  -- Insert a line at row 2 (inside the region).  Region should expand to 1..4.
  vim.api.nvim_buf_set_lines(bufnr, 2, 2, false, { "new_task" })

  -- Row 4 (previously row 3) should still be inside the region.
  local r4 = managed.region_for_row(bufnr, 4)
  MiniTest.expect.equality(r4 ~= nil, true)

  managed.clear_buffer(bufnr)
end

-- ── cleanup_region ────────────────────────────────────────────────────────────

T["cleanup_region: removes bracketing extmark"] = function()
  local bufnr = make_buf({ "l0", "l1", "l2" })
  local mid = managed.add_region(bufnr, 0, 2)

  managed.cleanup_region(bufnr, mid)

  -- region_for_row should return nil for all rows.
  eq(managed.region_for_row(bufnr, 0), nil)
  eq(managed.region_for_row(bufnr, 1), nil)
  eq(managed.region_for_row(bufnr, 2), nil)
end

T["cleanup_region: removes per-task extmarks within range"] = function()
  local bufnr = make_buf({ "l0", "l1", "l2", "l3" })
  local mid = managed.add_region(bufnr, 1, 2)
  managed.add_task(bufnr, 1, task_meta(10))
  managed.add_task(bufnr, 2, task_meta(11))

  managed.cleanup_region(bufnr, mid)

  eq(managed.task_meta_for_row(bufnr, 1), nil)
  eq(managed.task_meta_for_row(bufnr, 2), nil)
end

T["cleanup_region: does not remove task extmarks outside range"] = function()
  -- Two regions; cleanup only affects the targeted one.
  local bufnr = make_buf({ "l0", "l1", "l2", "l3", "l4" })
  local mid_a = managed.add_region(bufnr, 0, 1)
  managed.add_task(bufnr, 0, task_meta(0))
  managed.add_task(bufnr, 1, task_meta(1))

  managed.add_region(bufnr, 3, 4)
  managed.add_task(bufnr, 3, task_meta(3))
  managed.add_task(bufnr, 4, task_meta(4))

  -- Only clean up region A.
  managed.cleanup_region(bufnr, mid_a)

  -- Region B task meta must survive.
  eq(managed.task_meta_for_row(bufnr, 3) ~= nil, true)
  eq(managed.task_meta_for_row(bufnr, 4) ~= nil, true)

  managed.clear_buffer(bufnr)
end

T["cleanup_region: removes task_meta entries (no stale entries)"] = function()
  local bufnr = make_buf({ "a", "b", "c" })
  local mid = managed.add_region(bufnr, 0, 2)
  managed.add_task(bufnr, 0, task_meta(0))
  managed.add_task(bufnr, 1, task_meta(1))
  managed.add_task(bufnr, 2, task_meta(2))

  managed.cleanup_region(bufnr, mid)

  -- After cleanup no managed extmarks should remain in the buffer.
  local ns = managed.namespace()
  local remaining = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  eq(#remaining, 0)
end

-- ── cleanup_block ─────────────────────────────────────────────────────────────

T["cleanup_block: removes fence extmark from fence_marks iterator"] = function()
  local bufnr = make_buf({ "```tasks", "q", "```" })
  local fid = managed.add_block(bufnr, 0, 2)

  managed.cleanup_block(bufnr, fid)

  local found = false
  for mid in managed.fence_marks(bufnr) do
    if mid == fid then
      found = true
    end
  end
  eq(found, false)

  managed.clear_buffer(bufnr)
end

-- ── clear_buffer ──────────────────────────────────────────────────────────────

T["clear_buffer: removes all state for that buffer"] = function()
  local bufnr = make_buf({ "a", "b", "c", "d" })
  managed.add_block(bufnr, 0, 1)
  managed.add_region(bufnr, 1, 3)
  managed.add_task(bufnr, 1, task_meta(0))
  managed.add_task(bufnr, 2, task_meta(1))

  managed.clear_buffer(bufnr)

  -- No extmarks left in managed namespace.
  local ns = managed.namespace()
  local remaining = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  eq(#remaining, 0)

  -- All accessors return nil/empty.
  eq(managed.region_for_row(bufnr, 1), nil)
  eq(managed.task_meta_for_row(bufnr, 1), nil)

  local count = 0
  for _ in managed.fence_marks(bufnr) do
    count = count + 1
  end
  eq(count, 0)
end

T["clear_buffer: does not affect other buffers"] = function()
  local bufnr_a = make_buf({ "l0", "l1" })
  local bufnr_b = make_buf({ "l0", "l1" })

  managed.add_task(bufnr_a, 0, task_meta(10))
  managed.add_task(bufnr_b, 0, task_meta(20))

  -- Clear only buffer A.
  managed.clear_buffer(bufnr_a)

  -- Buffer B state must be unaffected.
  local meta_b = managed.task_meta_for_row(bufnr_b, 0)
  MiniTest.expect.equality(meta_b ~= nil, true)
  eq(meta_b.source_row, 20)

  managed.clear_buffer(bufnr_b)
end

T["clear_buffer: no-op on buffer with no managed state"] = function()
  local bufnr = make_buf({ "empty" })
  -- Should not error.
  managed.clear_buffer(bufnr)
  eq(managed.region_for_row(bufnr, 0), nil)
end

return T
