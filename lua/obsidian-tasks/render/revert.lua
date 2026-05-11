-- lua/obsidian-tasks/render/revert.lua
-- Read-only enforcement for managed regions via nvim_buf_attach on_lines.
--
-- When a user edits a row that belongs to a managed region (rendered task lines),
-- we schedule a debounced re-render that reverts the edit on the next event-loop
-- tick.  Edits in prose areas or inside query fences are NOT reverted.
--
-- Design:
--   • nvim_buf_attach on_lines listener is attached once per buffer on first render.
--   • Intersection with managed regions is detected via a per-buffer SNAPSHOT of
--     region positions taken at render time (not live extmarks).
--     Using live extmarks is unreliable: replacing a line just above a region
--     causes the region extmark to temporarily expand to include the replaced row
--     (due to left-gravity start + right-gravity end on a zero-width extmark).
--     The snapshot sidesteps this by storing stable positions and incrementally
--     adjusting them only when prose is inserted/deleted above managed rows.
--   • Debounce: at most one re-render pass is scheduled per buffer at a time.
--   • Plugin-initiated mutations are wrapped in suppress() / unsuppress() so the
--     listener ignores our own writes and doesn't recurse.
--   • Suppress is reference-counted so nesting (render_buffer calls clear_buffer
--     which both suppress) is safe.
--   • Cursor position is preserved across the re-render (clamped to new line count).
--   • undojoin merges the revert into the preceding user change to avoid polluting
--     the undo history.
--   • Cleanup happens automatically via the on_detach callback when the buffer is
--     deleted; explicit M._cleanup() is also available for tests.

local M = {}

local managed = require("obsidian-tasks.render.managed")

-- ── Per-buffer state ──────────────────────────────────────────────────────────

-- Reference-counted suppress flag.  > 0 means "ignore on_lines callbacks".
-- nil and 0 are both "not suppressed".
local _suppress = {} -- [bufnr] = integer

-- Debounce: true when a revert pass is already scheduled for this buffer.
local _scheduled = {} -- [bufnr] = true

-- Workspace stored at attach time so the scheduled callback can call rerender.
local _workspace = {} -- [bufnr] = workspace table | nil

-- Guard against double-attaching (nvim_buf_attach accumulates listeners).
local _attached = {} -- [bufnr] = true

-- Snapshot of managed region positions at the time of the last render.
-- { { start_row, end_row }, ... } (0-indexed inclusive, sorted ascending).
-- Updated at attach() time and incrementally in on_lines when prose is
-- inserted/deleted above managed rows (to keep the snapshot in sync).
local _region_snapshot = {} -- [bufnr] = table[]

-- ── Suppress helpers (public — called by render/init.lua) ─────────────────────

--- Increment the suppress counter for *bufnr*.
--- While > 0, on_lines callbacks are ignored.
--- @param bufnr integer
function M.suppress(bufnr)
  _suppress[bufnr] = (_suppress[bufnr] or 0) + 1
end

--- Decrement the suppress counter for *bufnr*.
--- @param bufnr integer
function M.unsuppress(bufnr)
  local n = _suppress[bufnr] or 0
  if n <= 1 then
    _suppress[bufnr] = nil
  else
    _suppress[bufnr] = n - 1
  end
end

--- Return true when on_lines callbacks are currently suppressed for *bufnr*.
--- Exposed for tests.
--- @param bufnr integer
--- @return boolean
function M.is_suppressed(bufnr)
  return (_suppress[bufnr] or 0) > 0
end

-- ── Internal: on_lines callback ───────────────────────────────────────────────

--- Called by Neovim whenever buffer text changes.
--- Signature: (event_type, bufnr, changedtick, firstline, lastline, new_lastline, byte_count)
---   firstline    — 0-indexed first changed line.
---   lastline     — 0-indexed exclusive end of the OLD changed range.
---   new_lastline — 0-indexed exclusive end of the NEW changed range.
local function on_lines(_, bufnr, _tick, first_line, last_line, new_lastline, _byte_count)
  -- Short-circuit when plugin is writing.
  if (_suppress[bufnr] or 0) > 0 then
    return
  end

  local snapshot = _region_snapshot[bufnr]
  if not snapshot or #snapshot == 0 then
    return
  end

  -- Union of old and new changed ranges:
  --   • For pure insertions:  old=[first,first), new=[first, first+n)
  --   • For pure deletions:   old=[first, first+n), new=[first, first)
  --   • For replacements:     old=[first, first+old_n), new=[first, first+new_n)
  -- check_end is the exclusive right boundary covering both old and new.
  local check_end = math.max(last_line, new_lastline)

  -- Overlap: snapshot region [r_start, r_end] (inclusive) overlaps
  -- [first_line, check_end) when: r_start < check_end AND r_end >= first_line
  local touched = false
  for _, region in ipairs(snapshot) do
    if region[1] < check_end and region[2] >= first_line then
      touched = true
      break
    end
  end

  if not touched then
    -- The edit did not touch any managed region (prose or query fence edit).
    -- If lines were inserted or deleted, incrementally update the snapshot so
    -- future on_lines calls use correct positions (avoids the stale-snapshot
    -- false-negative when prose is inserted above the managed region).
    local delta = new_lastline - last_line
    if delta ~= 0 then
      local new_snapshot = {}
      for _, region in ipairs(snapshot) do
        if region[1] >= last_line then
          -- Region is at or below the edit (using OLD positions); shift by delta.
          new_snapshot[#new_snapshot + 1] = { region[1] + delta, region[2] + delta }
        else
          -- Region is above the edit; position unchanged.
          new_snapshot[#new_snapshot + 1] = region
        end
      end
      _region_snapshot[bufnr] = new_snapshot
    end
    return
  end

  -- Debounce: schedule at most one revert pass per buffer.
  if _scheduled[bufnr] then
    return
  end
  _scheduled[bufnr] = true

  vim.schedule(function()
    _scheduled[bufnr] = nil

    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    -- Capture cursor position before re-render.
    local wins = vim.fn.win_findbuf(bufnr)
    local cursor_save = nil
    if #wins > 0 then
      cursor_save = vim.api.nvim_win_get_cursor(wins[1])
    end

    -- undojoin merges the revert into the preceding user change so pressing
    -- <u> undoes the user's original edit rather than the revert separately.
    pcall(vim.cmd, "silent! undojoin")

    -- Suppress on_lines during our own buffer mutations to avoid recursion.
    M.suppress(bufnr)
    local ok, err = pcall(function()
      local render = require("obsidian-tasks.render.init")
      render.rerender_buffer(bufnr, _workspace[bufnr])
    end)
    M.unsuppress(bufnr)

    if not ok then
      require("obsidian-tasks.log").warn("revert: rerender_buffer error: " .. tostring(err))
    end

    -- Restore cursor (clamp row to new line count to handle line-count changes).
    if cursor_save and #wins > 0 then
      local line_count = vim.api.nvim_buf_line_count(bufnr)
      local row = math.min(cursor_save[1], line_count)
      local col = cursor_save[2]
      pcall(vim.api.nvim_win_set_cursor, wins[1], { row, col })
    end
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Attach the on_lines listener to *bufnr*.
---
--- Idempotent: if already attached, only updates the stored workspace and
--- refreshes the region snapshot from the current managed state.
--- Call this at the end of render_buffer (after managed regions are established).
---
--- @param bufnr    integer
--- @param workspace table?  workspace object passed to rerender_buffer on revert
function M.attach(bufnr, workspace)
  -- Always refresh workspace (may differ across rerenders) and snapshot
  -- (managed regions are re-set by each render_buffer call).
  _workspace[bufnr] = workspace
  _region_snapshot[bufnr] = managed.all_regions(bufnr)

  if _attached[bufnr] then
    return
  end
  _attached[bufnr] = true

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = on_lines,
    on_detach = function()
      M._cleanup(bufnr)
    end,
  })
end

--- Clean up all per-buffer state.
--- Called automatically via on_detach when the buffer is deleted.
--- Also callable from tests to reset state between runs.
--- @param bufnr integer
function M._cleanup(bufnr)
  _suppress[bufnr] = nil
  _scheduled[bufnr] = nil
  _workspace[bufnr] = nil
  _attached[bufnr] = nil
  _region_snapshot[bufnr] = nil
end

--- Return internal state snapshot for tests.
--- @param bufnr integer
--- @return table  { suppress, scheduled, attached }
function M._debug_state(bufnr)
  return {
    suppress = _suppress[bufnr] or 0,
    scheduled = _scheduled[bufnr] == true,
    attached = _attached[bufnr] == true,
  }
end

return M
