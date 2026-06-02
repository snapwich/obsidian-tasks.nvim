-- lua/obsidian-tasks/cmd/init.lua
-- :ObsidianTask <subcmd> dispatcher with range support and tab completion.
--
-- Public surface:
--   M.setup()                  — register :ObsidianTask user command
--   M.dispatch(opts)           — dispatch an opts table (testable entry point)
--   M.resolve_task_at(bufnr, lnum) — resolve task at 0-indexed lnum
--   M.bulk_range(bufnr, range) — walk range, return list of resolved tasks
--
-- Resolver for render lines (T7):
--   Uses managed.task_meta_for_row to identify rendered task lines.
--   Performs drift detection: if the source file line no longer matches
--   meta.task_text, the operation is refused with a notification.
--   Returns source buffer bufnr/lnum so subcommands write directly to source.

local M = {}

local log = require("obsidian-tasks.log")

-- ── Valid subcommands ─────────────────────────────────────────────────────────

local VALID_SUBCMDS = {
  "toggle",
  "done",
  "cancel",
  "inProgress",
  "onHold",
  "due",
  "scheduled",
  "start",
  "priority",
  "recurrence",
  "tags",
  "postpone",
  "id",
  "refresh",
  "render",
  "new",
  "goto",
  "quickfix",
}

local VALID_SUBCMDS_SET = {}
for _, v in ipairs(VALID_SUBCMDS) do
  VALID_SUBCMDS_SET[v] = true
end

-- Count leading whitespace characters in a line.
local function indent_of(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

-- A line is blank iff it is empty or whitespace-only.
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

-- ── Per-dashboard undo / redo ring ────────────────────────────────────────────
-- apply_source_edit appends each plugin-driven mutation to the undo ring keyed
-- by the dashboard buffer the user acted in.  dashboard_undo / dashboard_redo
-- pop entries and replay the inverse via apply_source_edit{skip_record=true}.
--
-- Ring entry shape:
--   { src_path, src_row, old_count, old_lines, new_count, new_lines }
--
-- Cleared on BufDelete (autocmds.lua) and on manual refresh (refresh_with_clear_lingers).

local UNDO_RING_CAP = 50

M._undo_ring = {} -- dashboard_bufnr → list of entries (push at end)
M._redo_ring = {} -- dashboard_bufnr → list of entries (push at end)

--- Native undo-sequence number (undotree().seq_cur) of *bufnr*.
---
--- Plugin task edits write to SOURCE files and re-render the dashboard with
--- undolevels = -1, so they never advance the dashboard buffer's own native undo
--- sequence — only genuine in-buffer user edits (prose / query tweaks) do.  By
--- stamping each ring entry with this value at push time, `u` can compare the
--- live sequence against the ring top to decide which history is MORE RECENT
--- and undo that one (see M.prefer_native_undo / make_undo_handler).
---
--- @param bufnr integer
--- @return integer  seq_cur, or 0 when unavailable
M.native_undo_seq = function(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0
  end
  local ok, seq = pcall(vim.api.nvim_buf_call, bufnr, function()
    return vim.fn.undotree().seq_cur
  end)
  return (ok and type(seq) == "number") and seq or 0
end

local function record_undo_edit(dashboard_bufnr, entry)
  if not dashboard_bufnr or dashboard_bufnr <= 0 then
    return
  end
  -- Stamp the dashboard's current native undo position so recency arbitration
  -- can order this plugin edit against native buffer edits.
  entry._native_seq = M.native_undo_seq(dashboard_bufnr)
  M._undo_ring[dashboard_bufnr] = M._undo_ring[dashboard_bufnr] or {}
  local r = M._undo_ring[dashboard_bufnr]
  r[#r + 1] = entry
  while #r > UNDO_RING_CAP do
    table.remove(r, 1)
  end
  -- A new forward edit invalidates the redo history for this dashboard.
  M._redo_ring[dashboard_bufnr] = nil
end

--- True when plain `u` should run NATIVE undo rather than the plugin ring:
--- the ring is empty, OR a native buffer edit landed AFTER the most recent
--- ring entry (live seq > the ring top's stamped seq).  See make_undo_handler.
--- @param dashboard_bufnr integer
--- @return boolean
function M.prefer_native_undo(dashboard_bufnr)
  local r = M._undo_ring[dashboard_bufnr]
  if not r or #r == 0 then
    return true
  end
  return M.native_undo_seq(dashboard_bufnr) > (r[#r]._native_seq or 0)
end

--- Mirror of prefer_native_undo for redo: prefer NATIVE redo while the live
--- sequence is still BELOW the redo top's stamped seq (native redos must climb
--- back up to the point where the ring entry was undone before it replays).
--- @param dashboard_bufnr integer
--- @return boolean
function M.prefer_native_redo(dashboard_bufnr)
  local r = M._redo_ring[dashboard_bufnr]
  if not r or #r == 0 then
    return true
  end
  return M.native_undo_seq(dashboard_bufnr) < (r[#r]._native_seq or 0)
end

-- ── Resolver helpers ─────────────────────────────────────────────────────────

--- Read a single line (0-indexed row) from a source file.
--- Prefers a loaded buffer; falls back to readfile for unloaded files.
--- Returns nil if the file cannot be read or the row is out of range.
---
--- @param file_path  string
--- @param row        integer  0-indexed
--- @return string|nil
local function read_source_line(file_path, row)
  local src_bufnr = vim.fn.bufnr(file_path, false)
  if src_bufnr > -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(src_bufnr, row, row + 1, false)
    return lines[1]
  end
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if ok and type(lines) == "table" then
    return lines[row + 1] -- readfile is 1-indexed
  end
  return nil
end

--- Return the bufnr of *file_path* iff it is already loaded; otherwise nil.
--- We deliberately do NOT bufadd+bufload here: auto-loading a vault file
--- triggers Neovim's swap-file detection, which would emit a notification (and
--- in the worst case leave the buffer empty) for any file with a stale .swp
--- left over from a crashed nvim session.  Mutations against unloaded files go
--- through apply_source_edit, which uses readfile/writefile on disk directly.
---
--- @param file_path string
--- @return integer|nil  bufnr of a loaded buffer, or nil
local function loaded_source_buf(file_path)
  local b = vim.fn.bufnr(file_path, false)
  if b > -1 and vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_is_loaded(b) then
    return b
  end
  return nil
end

--- Locate a source row near *expected_row* by content-search within ±10 rows.
---
--- Searches the file at *src_path* for *expected_text* in the window
--- [expected_row-10, expected_row+10].  When multiple rows match, the one
--- closest to *expected_row* is returned.  When no row in the window matches,
--- returns nil (caller should revert + notify).
---
--- Search order: for each offset 0, 1, 2, … 10 check expected_row+offset then
--- expected_row-offset.  The first hit at the smallest offset is returned
--- immediately (closest-first, prefer + over - on ties).
---
--- @param src_path      string   path to the source file
--- @param expected_row  integer  0-indexed expected row
--- @param expected_text string   verbatim task text to search for
--- @return integer|nil  0-indexed located row, or nil when not found within ±10
function M.locate(src_path, expected_row, expected_text)
  local ok, lines = pcall(vim.fn.readfile, src_path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  local n = #lines
  for offset = 0, 10 do
    local r_plus = expected_row + offset
    if r_plus >= 0 and r_plus < n and lines[r_plus + 1] == expected_text then
      return r_plus
    end
    if offset > 0 then
      local r_minus = expected_row - offset
      if r_minus >= 0 and r_minus < n and lines[r_minus + 1] == expected_text then
        return r_minus
      end
    end
  end
  return nil
end

--- Apply a single-row edit to a source file and persist it.
---
--- The replacement may have 0 (delete), 1 (replace), or N (expand) lines.
---
--- Disk is read first (authoritative), the mutation is applied to those lines,
--- and the result is written back via writefile.  When a buffer for *file_path*
--- is already loaded, the buffer is then synced to the new disk content so any
--- open view reflects external edits made since the buffer was last read.
---
--- Refuses if a loaded buffer has unsaved user edits — otherwise our write
--- would silently commit those pending edits alongside our mutation.
---
--- Cursor positions in any window showing the loaded source buffer are
--- preserved across the in-place buffer refresh; the buffer's `"` (last-cursor)
--- mark is preserved so a later :edit restores the user's pre-mutation row even
--- if the buffer was hidden when the mutation landed.
---
--- After a successful write, propagates the change to every OTHER visible
--- buffer whose render references this source path (via the index reverse
--- map) — this mirrors the BufWritePost propagation in autocmds.lua, which
--- can't fire here because writefile doesn't trigger BufWritePost.
---
--- **Batched edits** (opts.batch): when opts.batch is an array of
--- { row, new_lines, count? } entries for *file_path*, all edits are aggregated
--- and written in a single readfile/writefile round-trip, applied bottom-up so
--- row indices remain valid throughout.  Batches across multiple src_paths are
--- handled by grouping: callers should invoke apply_source_edit once per file
--- with all per-file edits in opts.batch.
---
--- @param file_path string
--- @param row       integer    0-indexed first row affected
--- @param new_lines string[]   replacement lines (0 = delete, 1 = replace, N = expand)
--- @param opts?     table      optional:
---                               count            — rows to remove starting at `row`
---                                                  (default 1).  0 = pure insert
---                                                  before `row`.
---                               dashboard_bufnr  — bufnr to record this edit
---                                                  against in the undo ring
---                                                  (default current_buf).
---                               skip_record      — when true, do not push this
---                                                  edit into the undo ring.
---                                                  Used by undo/redo replays.
---                               batch            — array of { row, new_lines,
---                                                  count? } entries for a
---                                                  multi-row grouped write.
---                                                  Applied bottom-up per file.
--- @return boolean ok
function M.apply_source_edit(file_path, row, new_lines, opts)
  opts = opts or {}

  -- ── Batched edits (Q13) ──────────────────────────────────────────────────────
  -- Single read + write per file; edits applied bottom-up; one undo record for
  -- the whole batch.  Callers invoke apply_source_edit once per src_path and
  -- pass all per-file edits in opts.batch.
  --
  -- Return shape: (ok, result) where
  --   result.entries[i] = { applied, located_row, reason }
  --   reason ∈ "ok" | "locate_miss" | "write_failed"
  -- Indexed by ORIGINAL opts.batch position so the flush layer can correlate
  -- extmark updates.  Non-batch callers receive only the boolean.
  if opts.batch ~= nil then
    -- Read file once (authoritative).
    local ok_r, disk_lines = pcall(vim.fn.readfile, file_path)
    if not ok_r or type(disk_lines) ~= "table" then
      log.warn("obsidian-tasks: failed to read " .. file_path)
      return false
    end

    -- Build sorted work list, preserving original batch index for result mapping.
    local work = {}
    for i, e in ipairs(opts.batch) do
      work[#work + 1] = { orig_idx = i, data = e }
    end
    -- Sort descending by row: bottom-up application keeps earlier row indices
    -- valid as lines are removed/inserted by subsequent (higher-row) edits.
    table.sort(work, function(a, b)
      return a.data.row > b.data.row
    end)

    -- Apply each entry to the in-memory copy of disk_lines.
    local result_entries = {}
    local undo_batch = {}
    for _, item in ipairs(work) do
      local entry = item.data
      local actual_row = entry.row
      local entry_count = entry.count or 1
      local do_apply = true

      -- Q12 drift recovery: content-search when expected_text is supplied.
      -- M.locate reads the original disk (not yet written) — correct because
      -- bottom-up processing has not yet touched rows above this one.
      if entry.expected_text then
        local located = M.locate(file_path, entry.row, entry.expected_text)
        if located == nil then
          do_apply = false
          result_entries[item.orig_idx] = { applied = false, located_row = nil, reason = "locate_miss" }
        else
          actual_row = located
        end
      end

      if do_apply then
        -- Capture old lines before mutation (needed for undo replay).
        local old_lines_entry = {}
        for i = 1, entry_count do
          old_lines_entry[i] = disk_lines[actual_row + i]
        end

        -- Apply: remove entry_count lines at actual_row, then insert new_lines.
        for _ = 1, entry_count do
          table.remove(disk_lines, actual_row + 1)
        end
        for i = #entry.new_lines, 1, -1 do
          table.insert(disk_lines, actual_row + 1, entry.new_lines[i])
        end

        result_entries[item.orig_idx] = { applied = true, located_row = actual_row, reason = "ok" }
        undo_batch[#undo_batch + 1] = {
          src_row = actual_row,
          old_count = entry_count,
          old_lines = old_lines_entry,
          new_count = #entry.new_lines,
          new_lines = vim.deepcopy(entry.new_lines),
        }
      end
    end

    -- Write file once (Q13: single write per src_path per flush).
    local ok_w = pcall(vim.fn.writefile, disk_lines, file_path)
    if not ok_w then
      log.warn("obsidian-tasks: failed to write " .. file_path)
      -- (Q15) per-file failure; other files' batches are unaffected.
      -- Report write_failed for every entry so the flush layer can revert.
      for i = 1, #opts.batch do
        result_entries[i] = { applied = false, located_row = nil, reason = "write_failed" }
      end
      return false, { entries = result_entries }
    end

    -- Refresh in-memory index.
    pcall(function()
      local idx = require("obsidian-tasks.index")
      if type(idx.invalidate) == "function" then
        idx.invalidate(file_path)
      end
      if type(idx.refresh_file) == "function" then
        idx.refresh_file(file_path)
      end
    end)

    -- Record ONE undo-ring entry for the entire batch (Q13: single undo block).
    -- batch_edits carries all sub-edits (descending row order = bottom-up) for
    -- full replay by dashboard_undo / dashboard_redo.
    if not opts.skip_record and #undo_batch > 0 then
      local dash = opts.dashboard_bufnr or vim.api.nvim_get_current_buf()
      local primary = undo_batch[#undo_batch] -- lowest row = last in bottom-up pass
      record_undo_edit(dash, {
        src_path = file_path,
        src_row = primary.src_row,
        old_count = primary.old_count,
        old_lines = primary.old_lines,
        new_count = primary.new_count,
        new_lines = primary.new_lines,
        batch_edits = undo_batch,
      })
    end

    return true, { entries = result_entries }
  end

  local count = opts.count or 1
  if type(count) ~= "number" or count < 0 then
    log.warn("obsidian-tasks: invalid count " .. tostring(count))
    return false
  end

  local src_bufnr = loaded_source_buf(file_path)

  -- Same-buffer dashboard branch.  When the loaded source buffer is itself
  -- a dashboard, the buffer carries rendered task lines below the fence
  -- that are not (and must not be) on disk.  The normal disk-path's
  -- post-write buffer sync would overwrite the rendered region with disk
  -- content (clobbering it); refusing on buf.modified would block every
  -- edit (the buffer is always modified by render insertions).
  --
  -- Strategy: write disk for the source row (via readfile + writefile so
  -- only that row changes on disk), then mutate the SAME row in the buffer
  -- (narrow nvim_buf_set_lines that leaves the rendered region intact).
  -- Index refresh then reads the now-up-to-date disk and the next rerender
  -- correctly reflects the new state.
  if src_bufnr and vim.b[src_bufnr].obsidian_tasks_dashboard then
    local ok_r, disk_lines = pcall(vim.fn.readfile, file_path)
    if not ok_r or type(disk_lines) ~= "table" then
      log.warn("obsidian-tasks: failed to read " .. file_path)
      return false
    end
    if row < 0 or row + count > #disk_lines then
      log.warn(
        "obsidian-tasks: edit at row "
          .. row
          .. " (count "
          .. count
          .. ") out of range (file has "
          .. #disk_lines
          .. " lines)"
      )
      return false
    end
    -- Capture old_lines from disk (authoritative pre-mutation state).
    local old_lines = {}
    for i = 1, count do
      old_lines[i] = disk_lines[row + i]
    end
    -- Mutate disk_lines.
    for _ = 1, count do
      table.remove(disk_lines, row + 1)
    end
    for i = #new_lines, 1, -1 do
      table.insert(disk_lines, row + 1, new_lines[i])
    end
    local ok_w = pcall(vim.fn.writefile, disk_lines, file_path)
    if not ok_w then
      log.warn("obsidian-tasks: failed to write " .. file_path)
      return false
    end
    -- Narrow buffer mutation at exactly the source row(s); rendered region
    -- below the fence is untouched.
    vim.api.nvim_buf_set_lines(src_bufnr, row, row + count, false, new_lines)
    -- Mark the buffer unmodified relative to the just-written disk content.
    -- BufWriteCmd's later :w will filter managed rows out, but until then
    -- the source-row state matches disk and shouldn't show as dirty.
    vim.bo[src_bufnr].modified = false

    -- Refresh the in-memory index from disk (now up to date).
    pcall(function()
      local idx = require("obsidian-tasks.index")
      if type(idx.invalidate) == "function" then
        idx.invalidate(file_path)
      end
      if type(idx.refresh_file) == "function" then
        idx.refresh_file(file_path)
      end
    end)

    -- Record into the per-dashboard undo ring.
    if not opts.skip_record then
      local dash = opts.dashboard_bufnr or vim.api.nvim_get_current_buf()
      record_undo_edit(dash, {
        src_path = file_path,
        src_row = row,
        old_count = count,
        old_lines = old_lines,
        new_count = #new_lines,
        new_lines = vim.deepcopy(new_lines),
      })
    end
    return true
  end

  if src_bufnr and vim.bo[src_bufnr].modified then
    log.warn(
      "obsidian-tasks: source buffer has unsaved changes — save (:w) "
        .. vim.fn.fnamemodify(file_path, ":t")
        .. " before editing from the query"
    )
    return false
  end

  -- Read disk first (authoritative).  Previously the loaded-buffer branch
  -- read from a possibly-stale buffer and writefile'd its contents back,
  -- silently clobbering external edits to disk made since the buffer loaded.
  local ok_r, disk_lines = pcall(vim.fn.readfile, file_path)
  if not ok_r or type(disk_lines) ~= "table" then
    log.warn("obsidian-tasks: failed to read " .. file_path)
    return false
  end
  -- count=0 (pure insert) accepts row ∈ [0, #disk_lines] so we can append at end.
  -- count>=1 requires row + count <= #disk_lines.
  if row < 0 or row + count > #disk_lines then
    log.warn(
      "obsidian-tasks: edit at row "
        .. row
        .. " (count "
        .. count
        .. ") out of range (file has "
        .. #disk_lines
        .. " lines)"
    )
    return false
  end

  -- Capture the about-to-be-removed lines for the undo ring (before mutation).
  local old_lines = {}
  for i = 1, count do
    old_lines[i] = disk_lines[row + i]
  end

  -- Detect external disk edits: buffer's view differs from on-disk pre-mutation
  -- content.  When they match, only the mutation rows need to change in the
  -- buffer — narrow replace preserves stored cursors (visible AND hidden).
  -- When they differ, the buffer needs a full-content refresh and cursor
  -- preservation becomes best-effort (the user's external edits got applied).
  local external_changed = false
  if src_bufnr then
    local buf_lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
    if #buf_lines ~= #disk_lines then
      external_changed = true
    else
      for i, v in ipairs(buf_lines) do
        if v ~= disk_lines[i] then
          external_changed = true
          break
        end
      end
    end
  end

  -- Apply the mutation to the disk-side lines: remove `count` rows at `row`,
  -- then insert `new_lines` at the same position.
  for _ = 1, count do
    table.remove(disk_lines, row + 1)
  end
  for i = #new_lines, 1, -1 do
    table.insert(disk_lines, row + 1, new_lines[i])
  end

  local ok_w = pcall(vim.fn.writefile, disk_lines, file_path)
  if not ok_w then
    log.warn("obsidian-tasks: failed to write " .. file_path)
    return false
  end

  if src_bufnr then
    -- Snapshot all visible window cursors AND the buffer's `"` mark before
    -- the mutation.  For visible windows Nvim preserves their cursors across
    -- nvim_buf_set_lines/set_text already, so the save+restore here is only
    -- a safety net for cases where it doesn't (e.g. full-buffer replace).
    -- For HIDDEN buffers, Nvim shifts the per-window stored cursor up by one
    -- row when nvim_buf_set_lines/set_text touches the row the cursor was on;
    -- the `"` mark (set on BufLeave) captures the user's true pre-switch
    -- position and is restored via a one-time BufEnter autocmd below.
    local cursor_saves = {}
    for _, w in ipairs(vim.fn.win_findbuf(src_bufnr)) do
      if vim.api.nvim_win_is_valid(w) then
        cursor_saves[w] = vim.api.nvim_win_get_cursor(w)
      end
    end
    local is_hidden = next(cursor_saves) == nil
    local quote_mark = vim.api.nvim_buf_get_mark(src_bufnr, '"')

    if external_changed then
      -- Sync the entire buffer to disk so the external edits are reflected.
      vim.api.nvim_buf_set_lines(src_bufnr, 0, -1, false, disk_lines)
    else
      -- No external edit: replace only the mutation range.  Visible windows
      -- keep their cursors naturally; hidden cursors are restored on the
      -- next BufEnter (see below).
      vim.api.nvim_buf_set_lines(src_bufnr, row, row + count, false, new_lines)
    end
    vim.bo[src_bufnr].modified = false

    -- Row-adjustment helper.  When the saved cursor was strictly below the
    -- last mutation row, shift by (#new_lines - count).  Cursors at-or-above
    -- the first mutation row are unchanged.
    local mut_row_1 = row + count -- 1-indexed: cursors > this shift
    local shift = #new_lines - count
    local total = #disk_lines
    local function adjust(cr, cc)
      if cr > mut_row_1 then
        cr = cr + shift
      end
      cr = math.max(1, math.min(cr, math.max(1, total)))
      local line = disk_lines[cr] or ""
      cc = math.max(0, math.min(cc, #line))
      return cr, cc
    end

    for w, pos in pairs(cursor_saves) do
      if vim.api.nvim_win_is_valid(w) then
        local cr, cc = adjust(pos[1], pos[2])
        pcall(vim.api.nvim_win_set_cursor, w, { cr, cc })
      end
    end
    if quote_mark[1] > 0 then
      local cr, cc = adjust(quote_mark[1], quote_mark[2])
      pcall(vim.api.nvim_buf_set_mark, src_bufnr, '"', cr, cc, {})

      -- Hidden-buffer cursor preservation: Nvim's per-window stored cursor
      -- for this buffer has drifted due to the line mutation, so register a
      -- one-time BufEnter that snaps the cursor to the user's pre-switch
      -- position on next entry.  Idempotent — only one registration pending
      -- at a time, even if multiple apply_source_edit calls land on a hidden
      -- buffer before the user enters it.
      if is_hidden and not vim.b[src_bufnr].obsidian_tasks_cursor_pending then
        vim.b[src_bufnr].obsidian_tasks_cursor_pending = true
        local target_row, target_col = cr, cc
        vim.api.nvim_create_autocmd("BufEnter", {
          buffer = src_bufnr,
          once = true,
          desc = "obsidian-tasks: restore cursor after plugin-driven mutation",
          callback = function()
            vim.b[src_bufnr].obsidian_tasks_cursor_pending = nil
            local nlines = vim.api.nvim_buf_line_count(src_bufnr)
            local r = math.max(1, math.min(target_row, math.max(1, nlines)))
            local line = vim.api.nvim_buf_get_lines(src_bufnr, r - 1, r, false)[1] or ""
            local c = math.max(0, math.min(target_col, #line))
            pcall(vim.api.nvim_win_set_cursor, 0, { r, c })
          end,
        })
      end
    end
  end

  -- Refresh the in-memory index entry for this path.
  -- Wrapped in pcall: index.refresh_file may call obsidian APIs that require
  -- obsidian.nvim to be set up (not guaranteed in all call sites).
  pcall(function()
    local index = require("obsidian-tasks.index")
    if type(index.invalidate) == "function" then
      index.invalidate(file_path)
    end
    if type(index.refresh_file) == "function" then
      index.refresh_file(file_path)
    end
  end)

  -- Propagate to every OTHER buffer whose render references this path.
  -- writefile() doesn't fire BufWritePost, so the reverse_index propagation in
  -- autocmds.lua never runs for plugin-driven mutations.  We mirror it here.
  -- The user's current buffer is skipped: the dashboard keymap handler that
  -- called us re-renders it separately via do_rerender().
  --
  -- Visible buffers rerender immediately; windowless ones are marked dirty
  -- and rerendered on their next BufEnter (a clear+render with no window in
  -- scope drifts the buffer's stored cursor — see mark_dirty_for_deferred_sync).
  local render_ok, render = pcall(require, "obsidian-tasks.render")
  local index_ok, index = pcall(require, "obsidian-tasks.index")
  if
    render_ok
    and index_ok
    and type(index.reverse_index) == "function"
    and type(render.rerender_buffer) == "function"
  then
    local current_buf = vim.api.nvim_get_current_buf()
    local ws
    pcall(function()
      ws = require("obsidian-tasks.util.obsidian").workspace_for_path(file_path)
    end)
    for _, other_bufnr in ipairs(index.reverse_index(file_path)) do
      if other_bufnr ~= current_buf and vim.api.nvim_buf_is_valid(other_bufnr) then
        if #vim.fn.win_findbuf(other_bufnr) > 0 then
          pcall(render.rerender_buffer, other_bufnr, ws)
        elseif type(render.mark_dirty_for_deferred_sync) == "function" then
          pcall(render.mark_dirty_for_deferred_sync, other_bufnr)
        end
      end
    end
  end

  -- Record this edit into the per-dashboard undo ring.  Skipped for
  -- inverse replays from undo/redo (skip_record=true) and for callers that
  -- explicitly opt out.  Forward edits clear the redo ring (new branch).
  if not opts.skip_record then
    local dash = opts.dashboard_bufnr or vim.api.nvim_get_current_buf()
    record_undo_edit(dash, {
      src_path = file_path,
      src_row = row,
      old_count = count,
      old_lines = old_lines,
      new_count = #new_lines,
      new_lines = vim.deepcopy(new_lines),
    })
  end

  return true
end

--- Verify the current disk content of *src_path* against each sub-edit's
--- *expected_key* line-set (drift detection).  Reads the file once; returns
--- false on any mismatch OR read failure (fail-safe → refuse the replay).
---
--- Mirrors the `no_drift` pattern in render/keymap.lua: we refuse a replay when
--- the source changed between the forward edit and the inverse.  The check uses
--- the sub-edits' stored (pre-replay) row positions — correct for 1-for-1
--- replacements (the common case); multi-line expansions may yield a
--- false-positive refusal, which is safe (no data corruption, just a retry).
---
--- @param src_path     string
--- @param subs         table[]  sub-edits, each with .src_row (0-indexed) and an
---                              *expected_key* line-set
--- @param expected_key string   "new_lines" (undo) | "old_lines" (redo)
--- @return boolean   true = every sub matches (safe to replay)
local function disk_subs_match(src_path, subs, expected_key)
  local ok, lines = pcall(vim.fn.readfile, src_path)
  if not ok or type(lines) ~= "table" then
    return false
  end
  for _, sub in ipairs(subs) do
    for i, line in ipairs(sub[expected_key]) do
      if lines[sub.src_row + i] ~= line then
        return false
      end
    end
  end
  return true
end

--- Replay the most recent edit on *dashboard_bufnr*'s undo or redo ring.
---
--- dashboard_undo and dashboard_redo are mirror images parametrized by *dir*:
---   • undo pops the undo ring and applies each edit's `old_lines` (removing
---     `new_count` rows), having verified the disk still holds the `new_lines`
---     we wrote; the popped entry is pushed onto the redo ring.
---   • redo is the same with old/new swapped, and the sub-edit iteration order
---     flipped — forward edits apply bottom-up (descending rows), so their
---     inverse applies top-down (ascending rows).
---
--- All three recorded entry shapes (single, batch_edits, _multi_file) normalize
--- to a list of ordered { src_path, subs } groups so one path handles them.
--- Drift across ALL groups is checked before any mutation; a per-group apply
--- failure restores the popped entry so the user can retry.
---
--- @param dashboard_bufnr integer
--- @param dir table  { from_ring, to_ring, verify_key, apply_key, count_key, reverse_subedits }
--- @return boolean ok
local function replay(dashboard_bufnr, dir)
  local from = dir.from_ring[dashboard_bufnr]
  if not from or #from == 0 then
    return false
  end
  local entry = from[#from]

  -- Normalize the entry into ordered file groups so multi-file, batch, and
  -- single edits share one apply path.
  local groups
  if entry._multi_file then
    groups = {}
    for _, fb in ipairs(entry.file_batches) do
      groups[#groups + 1] = { src_path = fb.src_path, subs = fb.batch_edits }
    end
  elseif entry.batch_edits then
    groups = { { src_path = entry.src_path, subs = entry.batch_edits } }
  else
    groups = { { src_path = entry.src_path, subs = { entry } } }
  end

  -- Drift check across every group BEFORE mutating anything.
  for _, g in ipairs(groups) do
    if not disk_subs_match(g.src_path, g.subs, dir.verify_key) then
      log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
      return false
    end
  end

  from[#from] = nil

  -- Apply the inverse (undo) / forward (redo) edit per group.  Within a group
  -- the sub-edits run in the direction-appropriate row order so line-count
  -- changes shift subsequent rows correctly.
  local function apply_sub(src_path, sub)
    return M.apply_source_edit(src_path, sub.src_row, sub[dir.apply_key], {
      count = sub[dir.count_key],
      dashboard_bufnr = dashboard_bufnr,
      skip_record = true,
    })
  end
  local any_failed = false
  for _, g in ipairs(groups) do
    if dir.reverse_subedits then
      for i = #g.subs, 1, -1 do
        if not apply_sub(g.src_path, g.subs[i]) then
          any_failed = true
        end
      end
    else
      for _, sub in ipairs(g.subs) do
        if not apply_sub(g.src_path, sub) then
          any_failed = true
        end
      end
    end
  end

  if any_failed then
    from[#from + 1] = entry -- restore so the user can retry
    return false
  end

  dir.to_ring[dashboard_bufnr] = dir.to_ring[dashboard_bufnr] or {}
  local to = dir.to_ring[dashboard_bufnr]
  -- Re-stamp the native position at the moment of this replay so the OPPOSITE
  -- direction (redo after undo, or undo after redo) orders correctly against any
  -- native edits the user made in between.  The replay's re-render uses
  -- undolevels = -1, so this seq is the live native position, unchanged by it.
  entry._native_seq = M.native_undo_seq(dashboard_bufnr)
  to[#to + 1] = entry

  -- Rerender the dashboard so the visual state reconciles with the new source.
  local render = require("obsidian-tasks.render")
  if type(render.rerender_buffer) == "function" and vim.api.nvim_buf_is_valid(dashboard_bufnr) then
    pcall(render.rerender_buffer, dashboard_bufnr)
  end
  return true
end

--- Pop the most recent edit from *dashboard_bufnr*'s undo ring and replay the
--- inverse (see replay()).  Refuses on drift; pushes the entry to the redo ring.
---
--- @param dashboard_bufnr integer
--- @return boolean ok
function M.dashboard_undo(dashboard_bufnr)
  return replay(dashboard_bufnr, {
    from_ring = M._undo_ring,
    to_ring = M._redo_ring,
    verify_key = "new_lines",
    apply_key = "old_lines",
    count_key = "new_count",
    reverse_subedits = true,
  })
end

--- Pop the most recent entry from *dashboard_bufnr*'s redo ring and replay it
--- forward (see replay()).  Refuses on drift; pushes the entry to the undo ring.
---
--- @param dashboard_bufnr integer
--- @return boolean ok
function M.dashboard_redo(dashboard_bufnr)
  return replay(dashboard_bufnr, {
    from_ring = M._redo_ring,
    to_ring = M._undo_ring,
    verify_key = "old_lines",
    apply_key = "new_lines",
    count_key = "old_count",
    reverse_subedits = false,
  })
end

--- Drop all undo/redo history for *dashboard_bufnr*.  Called on BufDelete and
--- on manual refresh (<leader>tr / refresh_with_clear_lingers).
---
--- @param dashboard_bufnr integer
function M.clear_dashboard_undo(dashboard_bufnr)
  M._undo_ring[dashboard_bufnr] = nil
  M._redo_ring[dashboard_bufnr] = nil
end

--- Commit a row-level edit for a resolved task.
---   - source kind: mutates the user's open buffer in-place; they save via :w.
---   - render kind: persists directly to disk via apply_source_edit.
---
--- Subcommands should call this instead of nvim_buf_set_lines so the persist
--- strategy is centralised.
---
--- @param resolved  table     result of M.resolve_task_at
--- @param new_lines string[]  replacement (0 = delete, 1 = replace, N = expand)
--- @return boolean ok
function M.commit_line(resolved, new_lines)
  if not resolved then
    return false
  end
  if resolved.kind == "source" then
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, new_lines)
    return true
  elseif resolved.kind == "render" then
    return M.apply_source_edit(resolved.src_path, resolved.lnum, new_lines)
  end
  return false
end

-- Expose internal helpers used by render/revert.lua's status-edit commit pass.
M._read_source_line = read_source_line
M._loaded_source_buf = loaded_source_buf

--- Record a pending linger for the active buffer after a status-changing
--- mutation, so the next rerender can promote it if the task exits the live
--- filter set.  Called by status-change subcommands (toggle/done/cancel/
--- onHold/inProgress).  No-op when the resolved entry isn't a task or when
--- the resolver didn't yield a source path (defensive).
---
--- @param active_bufnr integer  the buffer the user acted in (current_buf at
---                              cmd-dispatch time), NOT the source buffer
--- @param resolved     table    resolve_task_at result
--- @param task         table    parsed Task post-mutation
function M._record_linger(active_bufnr, resolved, task)
  if not resolved or (resolved.kind ~= "source" and resolved.kind ~= "render") then
    return
  end
  local src_path = resolved.src_path
  if not src_path then
    -- Source kind: derive from buffer name.  Normalize so the recorded linger
    -- key matches index-derived task abs_paths (forward slashes) when dashboards
    -- replay lingers — buffer names are all-backslash on Windows.
    src_path = require("obsidian-tasks.util.obsidian").normalize(vim.api.nvim_buf_get_name(resolved.bufnr))
  end
  if not src_path or src_path == "" then
    return
  end
  local src_line = resolved.src_line or (resolved.lnum + 1)
  local render = require("obsidian-tasks.render")
  if type(render._record_pending_linger) == "function" then
    render._record_pending_linger(active_bufnr, src_path, src_line, nil, task)
  end
end

-- ── Resolver ──────────────────────────────────────────────────────────────────

--- Resolve the task at a specific buffer position.
---
--- For rendered task lines: uses managed.task_meta_for_row to look up the
--- extmark side table.  Performs drift detection — if the source file line
--- no longer matches meta.task_text (external edit), the operation is refused
--- and nil is returned with a log.warn notification so the user knows to run
--- <leader>tr.  When no drift is detected the returned record points at the
--- SOURCE file via src_path/src_line so subcommands (via cmd.commit_line)
--- write directly to disk without touching the render buffer.
---
--- The source buffer is NOT auto-loaded: bufadd+bufload would trigger swap-
--- file detection for any vault file with a stale .swp.  bufnr is set only
--- when a buffer for the file is already loaded (so subcommands keep an open
--- view in sync); otherwise bufnr is nil.
---
--- For source-buffer lines: parses the raw buffer line as a task.
---
--- The second return value, *explained*, is true ONLY when the row was a known
--- managed non-task (a description BULLET or tree BLANK) that already emitted the
--- specific "not a task" notice.  Callers (and bulk_range) use it to suppress the
--- redundant generic "no task found in the specified range" warning so the user
--- sees a single message.  It is nil/false for every other nil-result case (e.g.
--- drift, unreadable source, a genuinely non-task source-buffer line) so those
--- still surface the generic warning.
---
--- @param bufnr integer  buffer number (render or source)
--- @param lnum  integer  0-indexed buffer line number
--- @return table|nil resolved
---   Render task:  { kind='render', bufnr=src_bufnr|nil, lnum=src_row, task, src_path, src_line }
---   Source task:  { kind='source', bufnr, lnum, task }
--- @return boolean|nil explained  true when a known non-task already emitted a notice
function M.resolve_task_at(bufnr, lnum)
  -- Check managed task-meta first (render lines).
  local managed = require("obsidian-tasks.render.managed")
  local meta = managed.task_meta_for_row(bufnr, lnum)
  if meta then
    -- Per-node-kind dispatch (Phase 6, requirements §11).  A description BULLET
    -- and a tree BLANK are MANAGED rows but are NOT tasks: they have no own
    -- `- [ ]` source line to mutate.  Task-mutation subcommands must be DISABLED
    -- here with a brief "not a task" notice and NO pass-through to any parent
    -- task — returning nil refuses the mutation at the single shared
    -- target-resolution choke point (every task-mutation subcommand resolves
    -- through here, directly or via bulk_range).  Real TASK rows (top-level
    -- matched OR nested children) carry tree_kind=="task" (or nil for flat
    -- dashboard rows / source buffers) and fall through unchanged.
    if meta.tree_kind == "bullet" or meta.tree_kind == "blank" then
      log.info("obsidian-tasks: not a task — this row has no task to change")
      -- Signal "already explained" so callers skip the redundant generic
      -- "no task found in the specified range" warning (single-notice rule, §11).
      return nil, true
    end

    -- Drift check: compare current source line against the recorded task_text.
    local current_line = read_source_line(meta.source_file, meta.source_row)
    if current_line == nil then
      log.warn("obsidian-tasks: cannot read source file — run <leader>tr to refresh")
      return nil
    end
    if current_line ~= meta.task_text then
      log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
      return nil
    end

    -- Parse the task from the clean source-file text (no wikilink suffix).
    local task = require("obsidian-tasks.task.parse").parse(meta.task_text)

    return {
      kind = "render",
      bufnr = loaded_source_buf(meta.source_file), -- nil when not already open
      lnum = meta.source_row, -- 0-indexed source row
      task = task,
      src_path = meta.source_file,
      src_line = meta.source_row + 1, -- 1-indexed for cursor placement
    }
  end

  -- Fall back to parsing the raw buffer line (source-buffer mode).
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  if #lines == 0 then
    return nil
  end
  local task = require("obsidian-tasks.task.parse").parse(lines[1])
  if not task then
    return nil
  end

  return {
    kind = "source",
    bufnr = bufnr,
    lnum = lnum,
    task = task,
  }
end

-- ── Bulk-range helper ─────────────────────────────────────────────────────────

--- Walk a line range and return all resolved tasks.
--- Non-task lines are silently skipped.
---
--- The second return value, *explained*, is true when the result list is empty
--- AND at least one row in the range was a known managed non-task (bullet/blank)
--- that already emitted the specific "not a task" notice via resolve_task_at.
--- Subcommands use it to suppress their redundant generic "no task found in the
--- specified range" warning, while a genuinely empty/non-managed range (explained
--- = false) still surfaces that generic warning.
---
--- @param bufnr integer   buffer number
--- @param range table     { line1: integer, line2: integer }  1-indexed (from opts)
--- @return table[]        list of resolve_task_at results
--- @return boolean        explained  true when an empty result was a known non-task
function M.bulk_range(bufnr, range)
  local results = {}
  local explained = false
  -- line1/line2 are 1-indexed; resolve_task_at expects 0-indexed.
  for lnum = range.line1 - 1, range.line2 - 1 do
    local resolved, row_explained = M.resolve_task_at(bufnr, lnum)
    if resolved then
      results[#results + 1] = resolved
    elseif row_explained then
      explained = true
    end
  end
  return results, explained
end

-- ── Dispatcher ────────────────────────────────────────────────────────────────

--- Dispatch a :ObsidianTask invocation.
---
--- `opts` matches the shape that nvim_create_user_command callbacks receive:
---   opts.fargs  — split argument list (first element is the subcmd name)
---   opts.line1  — first line of range (1-indexed)
---   opts.line2  — last line of range (1-indexed)
---
--- @param opts table
function M.dispatch(opts)
  local subcmd = opts.fargs and opts.fargs[1]
  if not subcmd or subcmd == "" then
    log.error("ObsidianTask: missing subcommand. Valid: " .. table.concat(VALID_SUBCMDS, " "))
    return
  end

  if not VALID_SUBCMDS_SET[subcmd] then
    log.error("ObsidianTask: unknown subcommand '" .. subcmd .. "'. Valid: " .. table.concat(VALID_SUBCMDS, " "))
    return
  end

  -- Lazy-load the subcommand module.
  local ok, mod = pcall(require, "obsidian-tasks.cmd." .. subcmd)
  if not ok or type(mod.run) ~= "function" then
    log.error("ObsidianTask: subcommand '" .. subcmd .. "' is not yet implemented")
    return
  end

  -- Remaining fargs (after the subcmd name) are passed as args.
  local args = {}
  for i = 2, #(opts.fargs or {}) do
    args[#args + 1] = opts.fargs[i]
  end

  local range = { line1 = opts.line1, line2 = opts.line2 }
  mod.run(args, range)
end

-- ── Completion ────────────────────────────────────────────────────────────────

--- Tab-completion for :ObsidianTask.
---
--- Top-level: completes subcmd names.
--- Second-level: delegates to subcmd module's M.complete(arg_lead, cmdline, cursorpos)
--- if defined.
---
--- @param arg_lead  string  current word being completed
--- @param cmdline   string  full command line so far
--- @param cursorpos integer cursor position in the command line
--- @return string[]
local function completion(arg_lead, cmdline, cursorpos)
  -- Extract the portion of the cmdline after the command name.
  local after_cmd = cmdline:match("^%S+%s+(.*)") or ""
  -- Count tokens that appear BEFORE the current arg_lead.
  local prefix = after_cmd:sub(1, #after_cmd - #arg_lead)
  local pre = vim.trim(prefix)

  if pre == "" then
    -- Completing the subcmd name itself.
    local matches = {}
    for _, name in ipairs(VALID_SUBCMDS) do
      if vim.startswith(name, arg_lead) then
        matches[#matches + 1] = name
      end
    end
    return matches
  end

  -- Delegate to subcmd's M.complete if available.
  local subcmd = pre:match("^%S+")
  if subcmd and VALID_SUBCMDS_SET[subcmd] then
    local ok, mod = pcall(require, "obsidian-tasks.cmd." .. subcmd)
    if ok and type(mod.complete) == "function" then
      return mod.complete(arg_lead, cmdline, cursorpos)
    end
  end
  return {}
end

-- Export for unit testing (prefixed _ to mark as internal).
M._completion = completion

-- ── Setup ─────────────────────────────────────────────────────────────────────

--- Register the :ObsidianTask user command.
--- Called from obsidian-tasks.init.setup().
--- Replaces any previously registered :ObsidianTask command (including the
--- plugin/ stub from F1).
function M.setup()
  -- Remove the stub registered by plugin/obsidian-tasks.lua, if still present.
  pcall(vim.api.nvim_del_user_command, "ObsidianTask")

  vim.api.nvim_create_user_command("ObsidianTask", M.dispatch, {
    nargs = "*",
    range = true,
    complete = completion,
    desc = "ObsidianTask: run a task subcommand (toggle, done, cancel, …)",
  })
end

--- Insert a new task line after the anchor task's continuation block in *src_path*.
---
--- Algorithm:
---   1. Start at anchor_row + 1.
---   2. Walk forward while the row is a continuation of anchor:
---      a. Non-blank line with indent > anchor_indent → continuation.
---      b. Blank line whose NEXT non-blank row has indent > anchor_indent →
---         the blank (and that next row) are part of the continuation.
---   3. Insert new_task_line at the first row that is NOT part of the continuation
---      via apply_source_edit with count=0 (pure insert before that row).
---
--- New task adopts anchor_indent — callers must pass new_task_line with the
--- correct leading spaces already applied.
---
--- *new_task_line* may be a single string (single-line insert, P5b) OR an array
--- of strings (multi-line block insert, P5c).  An array is written as a CONTIGUOUS
--- ordered block at the computed insertion position (one apply_source_edit /
--- count=0 / one undo entry), preserving the array's order.
---
--- @param src_path      string   path to the source file
--- @param anchor_row    integer  0-indexed row of the anchor task in the source
--- @param anchor_indent integer  indent level (number of leading spaces) of the anchor
--- @param new_task_line string|string[]  verbatim new line(s) to insert
--- @param opts          table?   optional: { dashboard_bufnr: integer } for undo ring keying
--- @return boolean ok
function M.insert_after_anchor(src_path, anchor_row, anchor_indent, new_task_line, opts)
  local ok_r, lines = pcall(vim.fn.readfile, src_path)
  if not ok_r or type(lines) ~= "table" then
    log.warn("obsidian-tasks: insert_after_anchor: failed to read " .. tostring(src_path))
    return false
  end

  local n = #lines

  -- Walk forward from anchor_row+1 (0-indexed) past all continuation lines.
  -- lines array is 1-indexed: lines[i+1] is the 0-indexed row i.
  local i = anchor_row + 1 -- first 0-indexed row to test (one after anchor)

  -- FIRST-CHILD insert (Bug 2): when the new line is indented DEEPER than the
  -- anchor, it is a CHILD of the anchor and must land immediately after the
  -- anchor row — becoming the FIRST child, BEFORE the anchor's existing subtree.
  -- A sibling insert (new line at/shallower than the anchor) instead belongs
  -- AFTER the whole subtree, so it still runs the continuation walk below.
  -- The first-child case is the only one where the dashboard row above the
  -- insert is the PARENT itself; any later child has a sibling above it at equal
  -- depth (which anchors to that sibling, not the parent).
  local first_new = type(new_task_line) == "table" and new_task_line[1] or new_task_line
  local is_child_insert = first_new ~= nil and indent_of(first_new) > anchor_indent

  while not is_child_insert and i < n do
    local line = lines[i + 1] -- 1-indexed access into readfile result

    if is_blank(line) then
      -- Blank line: look at the next non-blank row to decide whether this blank
      -- is part of the continuation (blank-followed-by-indented rule).
      local next_i = i + 1
      -- Find the first non-blank row at or after next_i.
      while next_i < n and is_blank(lines[next_i + 1]) do
        next_i = next_i + 1
      end
      -- If no following non-blank row exists, or the following row is NOT
      -- indented more than anchor_indent, the blank ends the continuation.
      if next_i >= n or indent_of(lines[next_i + 1]) <= anchor_indent then
        break
      end
      -- Otherwise the blank is part of the continuation; keep walking.
      i = i + 1
    elseif indent_of(line) <= anchor_indent then
      -- Non-blank row at same or shallower indent: not a continuation.
      break
    else
      -- Non-blank row indented deeper than anchor: continuation line.
      i = i + 1
    end
  end

  -- Insert new_task_line(s) at 0-indexed position i with count=0 (pure insert).
  -- A string is wrapped into a 1-element array; an array is inserted as a
  -- contiguous ordered block (P5c multi-line block insert).
  -- Forward opts.dashboard_bufnr so the undo ring entry is keyed to the correct
  -- dashboard buffer (required for multi-file undo merge in render/edit.flush).
  local new_lines = type(new_task_line) == "table" and new_task_line or { new_task_line }
  local ase_opts = { count = 0 }
  if opts and opts.dashboard_bufnr then
    ase_opts.dashboard_bufnr = opts.dashboard_bufnr
  end
  return M.apply_source_edit(src_path, i, new_lines, ase_opts)
end

--- Delete a task and its continuation block from *src_path*.
---
--- Algorithm:
---   1. Start at task_row.
---   2. Walk forward past all continuation lines:
---      a. Non-blank lines indented more than task_indent are continuations.
---      b. A blank line whose NEXT non-blank row is indented more than
---         task_indent is part of the continuation (blank + following indented
---         lines are included in the delete range).
---      c. A blank line NOT followed by an indented line ends the continuation
---         — the blank itself is NOT deleted.
---   3. Delete task_row through the last continuation row (inclusive) via
---      apply_source_edit with count=N.
---
--- @param src_path    string   path to the source file
--- @param task_row    integer  0-indexed row of the task to delete
--- @param task_indent integer  indent level (number of leading spaces) of the task
--- @return boolean ok
function M.delete_block(src_path, task_row, task_indent)
  local ok_r, lines = pcall(vim.fn.readfile, src_path)
  if not ok_r or type(lines) ~= "table" then
    log.warn("obsidian-tasks: delete_block: failed to read " .. tostring(src_path))
    return false
  end

  local n = #lines

  -- Walk forward from task_row+1, tracking the last row included in the block.
  -- lines is 1-indexed; i is a 0-indexed row number so lines[i+1] accesses it.
  local end_row = task_row
  local i = task_row + 1

  while i < n do
    local line = lines[i + 1]

    if is_blank(line) then
      -- Blank line: look ahead to find the next non-blank row.
      local next_i = i + 1
      while next_i < n and is_blank(lines[next_i + 1]) do
        next_i = next_i + 1
      end
      -- If no following non-blank exists, or it is not indented deeper than
      -- task_indent, the blank ends the continuation block.
      if next_i >= n or indent_of(lines[next_i + 1]) <= task_indent then
        break
      end
      -- Blank is part of the continuation; include it and keep walking.
      end_row = i
      i = i + 1
    elseif indent_of(line) <= task_indent then
      -- Non-blank row at same or shallower indent: end of continuation.
      break
    else
      -- Non-blank row indented deeper: continuation line.
      end_row = i
      i = i + 1
    end
  end

  local count = end_row - task_row + 1
  return M.apply_source_edit(src_path, task_row, {}, { count = count })
end

return M
