-- lua/obsidian-tasks/render/managed.lua
-- Managed-region module: extmark scheme, side tables, and namespace.
--
-- Owns the lifecycle of three kinds of extmarks in a DEDICATED namespace
-- (separate from util/extmark.lua's NS which is used for virt_lines):
--
--   1. Fence-opening extmarks  — anchored to the opening ```tasks fence line.
--   2. Bracketing extmarks     — span the full row range of a managed region.
--   3. Per-task extmarks       — anchored to each rendered task line.
--
-- Side tables (Lua-side, per-buffer, keyed by extmark id):
--
--   _task_meta[bufnr][mark_id] = {
--     source_file = '/abs/path.md',
--     source_row  = 42,            -- 0-indexed
--     task_text   = '- [ ] thing', -- canonical text for drift detection
--   }
--
--   _fence_marks[bufnr][mark_id] = { start_row, end_row }  -- 0-indexed inclusive
--
-- Other modules (render/draw.lua, autocmds, keymaps) consume this API; they
-- must not touch the namespace directly or maintain their own copies of these
-- tables.

local M = {}

-- ── Namespace ─────────────────────────────────────────────────────────────────

local _ns_id = nil

--- Return the managed-region namespace id (lazy-created).
--- @return integer
function M.namespace()
  if not _ns_id then
    _ns_id = vim.api.nvim_create_namespace("obsidian_tasks_managed")
  end
  return _ns_id
end

-- ── Side tables ───────────────────────────────────────────────────────────────

-- _fence_marks[bufnr][mark_id] = { start_row, end_row }  (0-indexed inclusive)
local _fence_marks = {}

-- _region_marks[bufnr][mark_id] = true  (set of region extmark IDs for fast lookup)
local _region_marks = {}

-- _task_meta[bufnr][mark_id] = { source_file, source_row, task_text }
local _task_meta = {}

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Ensure per-buffer tables exist.
--- @param bufnr integer
local function ensure_buf(bufnr)
  if not _fence_marks[bufnr] then
    _fence_marks[bufnr] = {}
  end
  if not _region_marks[bufnr] then
    _region_marks[bufnr] = {}
  end
  if not _task_meta[bufnr] then
    _task_meta[bufnr] = {}
  end
end

-- ── Block (fence) management ──────────────────────────────────────────────────

--- Anchor a fence extmark on fence_start_row and record in known_blocks.
---
--- right_gravity = true (default): the extmark moves with the fence when lines
--- are inserted at or before the fence row.  This is required so that
--- rerender_buffer can query the LIVE fence position via
--- nvim_buf_get_extmark_by_id after the user inserts source lines above the
--- rendered block between renders.
---
--- @param bufnr          integer
--- @param fence_start_row integer  0-indexed
--- @param fence_end_row   integer  0-indexed
--- @return integer  fence_mark_id
function M.add_block(bufnr, fence_start_row, fence_end_row)
  ensure_buf(bufnr)
  local ns = M.namespace()
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, fence_start_row, 0, {
    right_gravity = true,
  })
  _fence_marks[bufnr][mark_id] = { fence_start_row, fence_end_row }
  return mark_id
end

--- Delete the fence extmark and its known_blocks entry.
---
--- @param bufnr         integer
--- @param fence_mark_id integer
function M.cleanup_block(bufnr, fence_mark_id)
  local ns = M.namespace()
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, fence_mark_id)
  if _fence_marks[bufnr] then
    _fence_marks[bufnr][fence_mark_id] = nil
  end
end

--- Iterate all fence-opening extmarks in the buffer.
--- Yields: mark_id, { start_row, end_row }, current_row
---
--- @param bufnr integer
--- @return fun(): integer?, table?, integer?
function M.fence_marks(bufnr)
  if not _fence_marks[bufnr] then
    return function()
      return nil
    end
  end
  local ns = M.namespace()
  local ids = {}
  for mid in pairs(_fence_marks[bufnr]) do
    ids[#ids + 1] = mid
  end
  local i = 0
  return function()
    i = i + 1
    local mid = ids[i]
    if not mid then
      return nil
    end
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mid, {})
    local recorded = _fence_marks[bufnr][mid]
    -- pos = { row, col } or {} if extmark was deleted externally
    local current_row = pos and pos[1] or nil
    return mid, recorded, current_row
  end
end

-- ── Region (bracketing) management ────────────────────────────────────────────

--- Create a bracketing extmark spanning start_row..end_row.
---
--- right_gravity = false: the start stays put when text is inserted at start_row.
--- end_right_gravity = true: the end expands when text is inserted at end_row.
---
--- @param bufnr     integer
--- @param start_row integer  0-indexed
--- @param end_row   integer  0-indexed (inclusive)
--- @return integer  region_mark_id
function M.add_region(bufnr, start_row, end_row)
  ensure_buf(bufnr)
  local ns = M.namespace()
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, start_row, 0, {
    end_row = end_row,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  _region_marks[bufnr][mark_id] = true
  return mark_id
end

--- Return the bracketing extmark + its current [start, end] range covering row,
--- or nil if no region extmark covers row.
---
--- @param bufnr integer
--- @param row   integer  0-indexed buffer row
--- @return table|nil  { mark_id, range = { start_row, end_row } }
function M.region_for_row(bufnr, row)
  if not _region_marks[bufnr] then
    return nil
  end
  local ns = M.namespace()
  -- overlap = true returns extmarks whose [start..end] spans this row.
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, {
    overlap = true,
    details = true,
  })
  for _, em in ipairs(ems) do
    local mark_id = em[1]
    if _region_marks[bufnr][mark_id] then
      local start_row = em[2]
      local details = em[4]
      local end_row = details.end_row ~= nil and details.end_row or start_row
      return { mark_id = mark_id, range = { start_row, end_row } }
    end
  end
  return nil
end

--- Delete the bracketing extmark, all per-task extmarks within its range,
--- and their task_meta entries.
---
--- @param bufnr          integer
--- @param region_mark_id integer
function M.cleanup_region(bufnr, region_mark_id)
  if not _region_marks[bufnr] or not _region_marks[bufnr][region_mark_id] then
    return
  end
  local ns = M.namespace()

  -- Determine current range from the extmark before deleting it.
  local em = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local start_row, end_row
  for _, e in ipairs(em) do
    if e[1] == region_mark_id then
      start_row = e[2]
      local details = e[4]
      end_row = details.end_row ~= nil and details.end_row or e[2]
      break
    end
  end

  -- Delete the region extmark.
  pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, region_mark_id)
  _region_marks[bufnr][region_mark_id] = nil

  -- Delete task extmarks within the region range and their meta entries.
  if start_row ~= nil and end_row ~= nil and _task_meta[bufnr] then
    local ems_in_range = vim.api.nvim_buf_get_extmarks(bufnr, ns, { start_row, 0 }, { end_row, -1 }, {
      details = false,
    })
    for _, e in ipairs(ems_in_range) do
      local mid = e[1]
      if _task_meta[bufnr][mid] then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mid)
        _task_meta[bufnr][mid] = nil
      end
    end
  end
end

-- ── Per-task management ───────────────────────────────────────────────────────

--- Anchor a per-task extmark on row and store meta in task_meta.
---
--- Default gravity (right_gravity = true) means the extmark tracks
--- the task line as surrounding lines are inserted/deleted.
---
--- @param bufnr integer
--- @param row   integer  0-indexed
--- @param meta  table    { source_file, source_row, task_text }
--- @return integer  task_mark_id
function M.add_task(bufnr, row, meta)
  ensure_buf(bufnr)
  local ns = M.namespace()
  local mark_id = vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {})
  _task_meta[bufnr][mark_id] = meta
  return mark_id
end

--- Find the per-task extmark at row and return its task_meta entry, or nil.
---
--- @param bufnr integer
--- @param row   integer  0-indexed
--- @return table|nil  { source_file, source_row, task_text }
function M.task_meta_for_row(bufnr, row)
  if not _task_meta[bufnr] then
    return nil
  end
  local ns = M.namespace()
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, -1 }, {})
  for _, em in ipairs(ems) do
    local mark_id = em[1]
    local meta = _task_meta[bufnr][mark_id]
    if meta then
      return meta
    end
  end
  return nil
end

-- ── Region enumeration ────────────────────────────────────────────────────────

--- Return a sorted list of { start_row, end_row } for all live region extmarks.
---
--- Reads current extmark positions so the result is always up-to-date even if
--- surrounding lines have been inserted or deleted since the region was created.
--- Used by the BufWriteCmd save handler to determine which rows to drop.
---
--- @param bufnr integer
--- @return table[]  list of { start_row, end_row } 0-indexed inclusive, sorted by start_row
function M.all_regions(bufnr)
  if not _region_marks[bufnr] then
    return {}
  end
  local ns = M.namespace()
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  local regions = {}
  for _, em in ipairs(ems) do
    local mark_id = em[1]
    if _region_marks[bufnr][mark_id] then
      local start_row = em[2]
      local details = em[4]
      local end_row = details.end_row ~= nil and details.end_row or start_row
      regions[#regions + 1] = { start_row, end_row }
    end
  end
  -- nvim_buf_get_extmarks already returns marks in position order, but sort
  -- explicitly so callers can rely on the ordering guarantee.
  table.sort(regions, function(a, b)
    return a[1] < b[1]
  end)
  return regions
end

-- ── Debug / test helpers ──────────────────────────────────────────────────────

--- Return the number of entries in each per-buffer side table.
--- Intended for use in tests to verify cleanup invariants without exposing the
--- raw tables (stale Lua-side entries are a footgun; tests must be able to
--- catch them even when public accessors return nil via extmark lookup).
---
--- @param bufnr integer
--- @return table  { task_meta_count, fence_mark_count, region_mark_count }
function M._debug_counts(bufnr)
  local function count(t)
    if not t then
      return 0
    end
    local n = 0
    for _ in pairs(t) do
      n = n + 1
    end
    return n
  end
  return {
    task_meta_count = count(_task_meta[bufnr]),
    fence_mark_count = count(_fence_marks[bufnr]),
    region_mark_count = count(_region_marks[bufnr]),
  }
end

-- ── Buffer lifecycle ──────────────────────────────────────────────────────────

--- Clear all managed state for a buffer (fence marks, region marks, task meta).
--- Call this on BufDelete.
---
--- @param bufnr integer
function M.clear_buffer(bufnr)
  local ns = M.namespace()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
  _fence_marks[bufnr] = nil
  _region_marks[bufnr] = nil
  _task_meta[bufnr] = nil
end

return M
