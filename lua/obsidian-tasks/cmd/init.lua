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
}

local VALID_SUBCMDS_SET = {}
for _, v in ipairs(VALID_SUBCMDS) do
  VALID_SUBCMDS_SET[v] = true
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

local function record_undo_edit(dashboard_bufnr, entry)
  if not dashboard_bufnr or dashboard_bufnr <= 0 then
    return
  end
  M._undo_ring[dashboard_bufnr] = M._undo_ring[dashboard_bufnr] or {}
  local r = M._undo_ring[dashboard_bufnr]
  r[#r + 1] = entry
  while #r > UNDO_RING_CAP do
    table.remove(r, 1)
  end
  -- A new forward edit invalidates the redo history for this dashboard.
  M._redo_ring[dashboard_bufnr] = nil
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
--- @return boolean ok
function M.apply_source_edit(file_path, row, new_lines, opts)
  opts = opts or {}
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
  local index = require("obsidian-tasks.index")
  if type(index.invalidate) == "function" then
    index.invalidate(file_path)
  end
  if type(index.refresh_file) == "function" then
    index.refresh_file(file_path)
  end

  -- Propagate to every OTHER visible buffer whose render references this path.
  -- writefile() doesn't fire BufWritePost, so the reverse_index propagation in
  -- autocmds.lua never runs for plugin-driven mutations.  We mirror it here.
  -- The user's current buffer is skipped: the dashboard keymap handler that
  -- called us re-renders it separately via do_rerender().
  local render = require("obsidian-tasks.render")
  if type(index.reverse_index) == "function" and type(render.rerender_buffer) == "function" then
    local current_buf = vim.api.nvim_get_current_buf()
    local ws
    pcall(function()
      ws = require("obsidian-tasks.util.obsidian").workspace_for_path(file_path)
    end)
    for _, other_bufnr in ipairs(index.reverse_index(file_path)) do
      if
        other_bufnr ~= current_buf
        and vim.api.nvim_buf_is_valid(other_bufnr)
        and #vim.fn.win_findbuf(other_bufnr) > 0
      then
        render.rerender_buffer(other_bufnr, ws)
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

--- Compare current disk content at *src_row* for *new_count* lines against
--- *expected*.  Returns true iff every line matches (no drift).
---
--- Used by dashboard_undo / dashboard_redo to refuse a replay when the source
--- file changed between the forward edit and the inverse — mirroring the
--- existing `no_drift` pattern in render/keymap.lua.
---
--- @param src_path   string
--- @param src_row    integer  0-indexed
--- @param expected   string[]  lines we wrote at src_row in the forward edit
--- @return boolean   true = matches (safe to replay)
local function disk_lines_match(src_path, src_row, expected)
  local ok, lines = pcall(vim.fn.readfile, src_path)
  if not ok or type(lines) ~= "table" then
    -- Cannot verify — fail safe (refuse the undo).
    return false
  end
  for i, line in ipairs(expected) do
    if lines[src_row + i] ~= line then
      return false
    end
  end
  return true
end

--- Pop the most recent edit from *dashboard_bufnr*'s undo ring and replay
--- the inverse via apply_source_edit (skip_record=true).  Refuses when the
--- disk content at the recorded position no longer matches what we wrote
--- (drift).  Pushes the popped entry onto the redo ring on success.
---
--- @param dashboard_bufnr integer
--- @return boolean ok
function M.dashboard_undo(dashboard_bufnr)
  local r = M._undo_ring[dashboard_bufnr]
  if not r or #r == 0 then
    return false
  end
  local entry = r[#r]
  if not disk_lines_match(entry.src_path, entry.src_row, entry.new_lines) then
    log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
    return false
  end
  r[#r] = nil
  local ok = M.apply_source_edit(entry.src_path, entry.src_row, entry.old_lines, {
    count = entry.new_count,
    dashboard_bufnr = dashboard_bufnr,
    skip_record = true,
  })
  if not ok then
    r[#r + 1] = entry -- restore so the user can retry
    return false
  end
  M._redo_ring[dashboard_bufnr] = M._redo_ring[dashboard_bufnr] or {}
  local rr = M._redo_ring[dashboard_bufnr]
  rr[#rr + 1] = entry
  -- Rerender the dashboard so the visual state reconciles with the new source.
  local render = require("obsidian-tasks.render")
  if type(render.rerender_buffer) == "function" and vim.api.nvim_buf_is_valid(dashboard_bufnr) then
    pcall(render.rerender_buffer, dashboard_bufnr)
  end
  return true
end

--- Pop the most recent entry from *dashboard_bufnr*'s redo ring and replay
--- it forward via apply_source_edit (skip_record=true).  Same drift refusal
--- as dashboard_undo, but compared against old_lines (what the row held
--- before the forward edit / after the undo).
---
--- @param dashboard_bufnr integer
--- @return boolean ok
function M.dashboard_redo(dashboard_bufnr)
  local rr = M._redo_ring[dashboard_bufnr]
  if not rr or #rr == 0 then
    return false
  end
  local entry = rr[#rr]
  if not disk_lines_match(entry.src_path, entry.src_row, entry.old_lines) then
    log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
    return false
  end
  rr[#rr] = nil
  local ok = M.apply_source_edit(entry.src_path, entry.src_row, entry.new_lines, {
    count = entry.old_count,
    dashboard_bufnr = dashboard_bufnr,
    skip_record = true,
  })
  if not ok then
    rr[#rr + 1] = entry
    return false
  end
  M._undo_ring[dashboard_bufnr] = M._undo_ring[dashboard_bufnr] or {}
  local r = M._undo_ring[dashboard_bufnr]
  r[#r + 1] = entry
  local render = require("obsidian-tasks.render")
  if type(render.rerender_buffer) == "function" and vim.api.nvim_buf_is_valid(dashboard_bufnr) then
    pcall(render.rerender_buffer, dashboard_bufnr)
  end
  return true
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
    -- Source kind: derive from buffer name.
    src_path = vim.api.nvim_buf_get_name(resolved.bufnr)
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
--- @param bufnr integer  buffer number (render or source)
--- @param lnum  integer  0-indexed buffer line number
--- @return table|nil
---   Render task:  { kind='render', bufnr=src_bufnr|nil, lnum=src_row, task, src_path, src_line }
---   Source task:  { kind='source', bufnr, lnum, task }
function M.resolve_task_at(bufnr, lnum)
  -- Check managed task-meta first (render lines).
  local managed = require("obsidian-tasks.render.managed")
  local meta = managed.task_meta_for_row(bufnr, lnum)
  if meta then
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
--- @param bufnr integer   buffer number
--- @param range table     { line1: integer, line2: integer }  1-indexed (from opts)
--- @return table[]        list of resolve_task_at results
function M.bulk_range(bufnr, range)
  local results = {}
  -- line1/line2 are 1-indexed; resolve_task_at expects 0-indexed.
  for lnum = range.line1 - 1, range.line2 - 1 do
    local resolved = M.resolve_task_at(bufnr, lnum)
    if resolved then
      results[#results + 1] = resolved
    end
  end
  return results
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

return M
