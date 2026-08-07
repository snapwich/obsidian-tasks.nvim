-- lua/obsidian-tasks/render/cursor.lua
-- Cursor follow across a rerender: keep the cursor on the SAME TASK (and at the
-- same screen row) when a clear+render pass reorders the rendered lines.
--
-- Callers save before the pass and restore after it:
--
--   local cursor = require("obsidian-tasks.render.cursor")
--   local snap = cursor.save(bufnr)
--   ... clear + render ...
--   cursor.restore(bufnr, snap)
--
-- ── Identity key: (src_path, src_line) ───────────────────────────────────────
-- A rendered row is identified by the source file it came from plus the
-- 1-indexed line in that file.  Both values come from the LIVE draw-NS extmark
-- (draw.is_render_line), so they stay correct even when rows moved after the
-- snapshot was taken.
--
-- src_hash is NOT usable as the key.  It hashes the RENDERED text, so it
-- changes exactly when the user edits the task — which is the moment the follow
-- must work.  src_line breaks only when an external edit adds or removes lines
-- ABOVE the task in its source file; that case falls through to the neighbor
-- rule and then to the legacy clamp.
--
-- ── The key is not unique ────────────────────────────────────────────────────
-- One matched task can render more than once in the same buffer:
--   • once per group it matches (`group by` with several matching group keys);
--   • in tree mode, as a LIT fold owner plus DIM breadcrumb copies.
-- The restore therefore RANKS every candidate row instead of taking the first
-- match — see M._rank_candidates for the rule order.

local M = {}

--- Read the follow_cursor_on_rerender gate.
---
--- Same runtime pattern as linger_on_filter_exit / dim_completed_tasks in
--- render/init.lua: consult the opts table, treat only an explicit `false` as
--- off.  An absent key (nil) means ON, so a stubbed config in a unit test still
--- exercises the follow path.  render._opts is the merged table installed by
--- render.configure(); the plugin root table is the fallback for callers that
--- run before configure() (draw.lua reads opts the same way).
---
--- @return boolean
local function follow_enabled()
  local ok, render = pcall(require, "obsidian-tasks.render")
  if ok and type(render) == "table" and type(render._opts) == "table" then
    if render._opts.follow_cursor_on_rerender ~= nil then
      return render._opts.follow_cursor_on_rerender ~= false
    end
  end
  local ok2, ot = pcall(require, "obsidian-tasks")
  if ok2 and type(ot) == "table" and type(ot.opts) == "table" then
    return ot.opts.follow_cursor_on_rerender ~= false
  end
  return true
end

--- Return the render orchestrator's per-buffer block-state list, or nil.
--- @param bufnr integer
--- @return table|nil  list of block states, each with a .line_map
local function buffer_state(bufnr)
  local ok, render = pcall(require, "obsidian-tasks.render")
  if not ok or type(render) ~= "table" or type(render._buffer_state) ~= "table" then
    return nil
  end
  return render._buffer_state[bufnr]
end

--- True when *meta* carries a full identity and it equals *id*.
--- @param meta table|nil  line_map entry
--- @param id   table|nil  { src_path, src_line }
--- @return boolean
local function id_matches(meta, id)
  if not meta or not id then
    return false
  end
  return meta.src_path ~= nil and meta.src_path == id.src_path and meta.src_line == id.src_line
end

-- ── Save ─────────────────────────────────────────────────────────────────────

--- Snapshot the cursor of every window showing *bufnr*.
---
--- Result: { [winid] = { row, col, winline, leftcol, id, group_name, neighbor_id } }
---   row         1-indexed cursor row at save time
---   col         0-indexed cursor column
---   winline     screen row of the cursor inside the window (1-indexed)
---   leftcol     first visible column (horizontal scroll)
---   id          { src_path, src_line } | nil — nil when the cursor was not on
---               a rendered task row (prose, fence, freshly typed text)
---   group_name  string|nil — group hint used to break ranking ties
---   neighbor_id { src_path, src_line } | nil — identity of the next rendered
---               row, used only when the followed task disappears
---
--- Never raises: every window call is guarded, and an unreadable window is
--- simply left out of the snapshot.
---
--- @param bufnr integer
--- @return table  snapshot keyed by window handle (empty when no window shows bufnr)
function M.save(bufnr)
  local snapshot = {}
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return snapshot
  end

  local ok_draw, draw = pcall(require, "obsidian-tasks.render.draw")
  local state = buffer_state(bufnr)

  local ok_wins, wins = pcall(vim.fn.win_findbuf, bufnr)
  if not ok_wins or type(wins) ~= "table" then
    return snapshot
  end

  for _, w in ipairs(wins) do
    local ok_pos, pos = pcall(vim.api.nvim_win_get_cursor, w)
    if ok_pos and type(pos) == "table" and pos[1] then
      local lnum0 = pos[1] - 1 -- line_map keys and is_render_line are 0-indexed
      local entry = { row = pos[1], col = pos[2] or 0, leftcol = 0 }

      -- winline() and winsaveview() report the CURRENT window, so run them
      -- inside the saved window.
      pcall(vim.api.nvim_win_call, w, function()
        entry.winline = vim.fn.winline()
        local view = vim.fn.winsaveview()
        if type(view) == "table" and type(view.leftcol) == "number" then
          entry.leftcol = view.leftcol
        end
      end)

      -- Identity from live extmarks: correct even after line insertions above.
      if ok_draw and type(draw.is_render_line) == "function" then
        local ok_id, id = pcall(draw.is_render_line, bufnr, lnum0)
        if ok_id and id and id.src_path and id.src_line then
          entry.id = { src_path = id.src_path, src_line = id.src_line }
        end
      end

      -- Group hint + neighbor come from the block whose line_map holds this
      -- row.  line_map rows are STALE after buffer edits, so the hint is only
      -- accepted when its identity still equals the live one from the extmark.
      -- A rejected hint costs nothing — it only weakens the ranking.
      if state then
        for _, block_state in ipairs(state) do
          local line_map = block_state.line_map
          local meta = line_map and line_map[lnum0]
          if meta then
            if id_matches(meta, entry.id) then
              entry.group_name = meta.group_name
            end
            -- Neighbor: the next row below the cursor that names a task.
            -- Used as the landing spot when the followed task is gone, which
            -- gives the familiar vim `dd` behavior.
            local best_row, best_meta
            for lnum, m in pairs(line_map) do
              if lnum > lnum0 and m.src_path and m.src_line and (best_row == nil or lnum < best_row) then
                best_row, best_meta = lnum, m
              end
            end
            if best_meta then
              entry.neighbor_id = { src_path = best_meta.src_path, src_line = best_meta.src_line }
            end
            break
          end
        end
      end

      snapshot[w] = entry
    end
  end

  return snapshot
end

-- ── Candidate ranking ────────────────────────────────────────────────────────

--- Pick the best rendered row for *id* out of *state*.
---
--- Rules, first difference wins:
---   1. a LIT row beats a DIM row (prefer the real copy over a breadcrumb);
---   2. a row whose group_name equals the saved hint beats one that does not
---      (skipped when the snapshot carries no hint);
---   3. the row nearest the saved row — same rule as
---      managed.live_fold_root_row_for_source;
---   4. the lowest row.
---
--- Exported (M._ prefix) so unit tests can assert the ranking without a window.
---
--- @param state table|nil  render._buffer_state[bufnr] — a LIST of block states
--- @param id    table|nil  { src_path, src_line }
--- @param hint  table|nil  { row = 1-indexed saved row, group_name = string|nil }
--- @return integer|nil  0-indexed buffer row, or nil when nothing matches
function M._rank_candidates(state, id, hint)
  if type(state) ~= "table" or not id or not id.src_path or not id.src_line then
    return nil
  end
  local saved_row0 = ((hint and hint.row) or 1) - 1
  local want_group = hint and hint.group_name

  local best_row, best_lit, best_group, best_dist
  for _, block_state in ipairs(state) do
    local line_map = block_state.line_map
    if type(line_map) == "table" then
      for lnum, meta in pairs(line_map) do
        if id_matches(meta, id) then
          local lit = not meta.dim
          local group_ok = want_group ~= nil and meta.group_name == want_group
          local dist = math.abs(lnum - saved_row0)
          local better
          if best_row == nil then
            better = true
          elseif lit ~= best_lit then
            better = lit
          elseif want_group ~= nil and group_ok ~= best_group then
            better = group_ok
          elseif dist ~= best_dist then
            better = dist < best_dist
          else
            better = lnum < best_row
          end
          if better then
            best_row, best_lit, best_group, best_dist = lnum, lit, group_ok, dist
          end
        end
      end
    end
  end
  return best_row
end

-- ── Restore ──────────────────────────────────────────────────────────────────

--- Legacy restore: today's behavior, kept as the fallback.
--- Clamp the row to the new line count (min 1), clamp the column to the new
--- line length (min 0), then set the cursor.  No viewport pin — there is no
--- task to hold at a fixed screen row.
---
--- Exported (M._ prefix) so tests can drive the fallback directly.
---
--- @param win   integer  window handle
--- @param bufnr integer
--- @param saved table    snapshot entry ({ row, col, ... })
function M._legacy_restore(win, bufnr, saved)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local row = math.min(saved.row or 1, math.max(1, line_count))
  if row < 1 then
    row = 1
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local col = math.max(0, math.min(saved.col or 0, #line))
  pcall(vim.api.nvim_win_set_cursor, win, { row, col })
end

--- Follow restore: put the cursor on *row* and hold the task at its old screen
--- row.  winrestview needs the window to be current, hence nvim_win_call.
--- Neovim clamps topline near the ends of the buffer, so no extra guard is
--- needed; scrolloff is resolved by Neovim afterwards (only topline shifts).
---
--- @param win   integer
--- @param bufnr integer
--- @param row   integer  1-indexed target row
--- @param saved table    snapshot entry
local function follow_restore(win, bufnr, row, saved)
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local col = math.max(0, math.min(saved.col or 0, #line))
  local winline = saved.winline
  pcall(vim.api.nvim_win_call, win, function()
    if type(winline) == "number" and winline >= 1 then
      vim.fn.winrestview({
        topline = math.max(1, row - (winline - 1)),
        lnum = row,
        col = col,
        leftcol = saved.leftcol or 0,
      })
    else
      vim.api.nvim_win_set_cursor(win, { row, col })
    end
  end)
end

--- Restore the cursor of every window in *snapshot* that still shows *bufnr*.
---
--- Per window: follow the saved task when the feature is on and the snapshot
--- carries an identity; otherwise fall back — first to the neighbor task, then
--- to the legacy clamp.  Never raises.
---
--- @param bufnr    integer
--- @param snapshot table|nil  result of M.save
function M.restore(bufnr, snapshot)
  if type(snapshot) ~= "table" then
    return
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local follow = follow_enabled()
  local state = buffer_state(bufnr)

  for win, saved in pairs(snapshot) do
    if type(saved) == "table" and vim.api.nvim_win_is_valid(win) then
      local ok_buf, shown = pcall(vim.api.nvim_win_get_buf, win)
      if ok_buf and shown == bufnr then
        local row -- 1-indexed follow target; nil ⇒ legacy path
        if follow and saved.id then
          local cand = M._rank_candidates(state, saved.id, saved)
          if cand == nil and saved.neighbor_id then
            -- The task is gone (deleted, or filtered out): land on the task
            -- that came after it.
            cand = M._rank_candidates(state, saved.neighbor_id, saved)
          end
          if cand ~= nil then
            row = cand + 1
          end
        end
        if row then
          follow_restore(win, bufnr, row, saved)
        else
          M._legacy_restore(win, bufnr, saved)
        end
      end
    end
  end
end

return M
