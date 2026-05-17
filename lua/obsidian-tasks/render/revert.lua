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

-- Snapshot of per-task meta keyed by the row position at the time of the last
-- render: _meta_snapshot[bufnr][row] = { source_file, source_row, task_text, rendered_text }.
--
-- Captured by attach() (called at end of every render_buffer) so the classify-
-- and-commit pass can look up canonical-rendered-text and source coordinates
-- by row without depending on the live extmark position, which Neovim shifts
-- when the user replaces or pastes over a managed row.
--
-- Shifted in tandem with _region_snapshot when prose is inserted/deleted above
-- managed rows so keys stay aligned with the live row numbers.
local _meta_snapshot = {} -- [bufnr] = { [row] = task_meta }

-- Rerender function injected by render/init.lua at attach time.
-- Stored as a closure that captures the real module table M so that test mocks
-- replacing package.loaded["obsidian-tasks.render.init"] cannot intercept it.
-- nil when the buffer was attached without a rerender_fn (e.g. from unit tests
-- that call revert.attach directly and supply their own mock via mock_module).
local _rerender_fn = {} -- [bufnr] = function(bufnr, workspace) | nil

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

-- ── Internal: revert execution ────────────────────────────────────────────────

--- Execute the revert for *bufnr* immediately (synchronous, no vim.schedule).
---
--- Used by both the async vim.schedule path (normal operation) and the
--- synchronous test seam M._flush_pending.
---
--- Forward-declared so on_lines (defined next) can reference it by upvalue
--- while do_revert itself is defined after.
---
--- @param bufnr integer
local do_revert

--- Detect whether *current* equals *canonical* except for a single character
--- change between the [ and ] of the first checkbox occurrence in either string.
--- If so, and the new char is a known status symbol, return that symbol;
--- otherwise return nil.
---
--- @param canonical string  the rendered-text the plugin wrote to this row
--- @param current   string  the buffer's current content for this row
--- @return string|nil  the new status symbol, or nil if not a recognized status edit
local function recognize_status_edit(canonical, current)
  if canonical == nil or current == nil or #canonical ~= #current then
    return nil
  end
  -- Find the [ in the canonical line.  Tasks have the shape `<indent>- [<sym>] …`
  -- so the status char sits at byte position `bracket+1` (1-indexed).
  local bracket = canonical:find("%[")
  if bracket == nil then
    return nil
  end
  local sym_pos = bracket + 1
  -- The closing bracket must sit at sym_pos+1 (single char between brackets).
  if canonical:sub(sym_pos + 1, sym_pos + 1) ~= "]" then
    return nil
  end
  if current:sub(sym_pos + 1, sym_pos + 1) ~= "]" then
    return nil
  end
  -- All chars except the status char must be identical.
  if canonical:sub(1, sym_pos - 1) ~= current:sub(1, sym_pos - 1) then
    return nil
  end
  if canonical:sub(sym_pos + 1) ~= current:sub(sym_pos + 1) then
    return nil
  end
  local new_sym = current:sub(sym_pos, sym_pos)
  -- The new symbol must be in the configured status set.
  local status_mod = require("obsidian-tasks.task.status")
  if not status_mod.by_symbol[new_sym] then
    return nil
  end
  -- Also: don't treat a no-op (same symbol) as an edit.
  if new_sym == canonical:sub(sym_pos, sym_pos) then
    return nil
  end
  return new_sym
end

--- Walk every managed row, classify each as canonical / status edit / other,
--- and propagate recognized status edits to the source file.
---
--- Rows whose content matches their canonical rendered_text contribute nothing.
--- Rows whose only diff is a status symbol change to a known status symbol get
--- committed to source via the resolver pipeline (same path as <leader>tt).
--- Rows with any other diff fall through; the subsequent rerender restores them.
---
--- @param bufnr integer
local function classify_and_commit(bufnr)
  local snapshot = _region_snapshot[bufnr] or {}
  local meta_by_row = _meta_snapshot[bufnr] or {}
  local cmd = require("obsidian-tasks.cmd")
  local task_parse = require("obsidian-tasks.task.parse")
  local serialize = require("obsidian-tasks.task.serialize")
  local log = require("obsidian-tasks.log")

  for _, region in ipairs(snapshot) do
    for row = region[1], region[2] do
      local cur_lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
      local current = cur_lines[1]
      local meta = meta_by_row[row]
      if current ~= nil and meta ~= nil and meta.rendered_text ~= nil then
        local new_sym = recognize_status_edit(meta.rendered_text, current)
        if new_sym ~= nil then
          -- Disk is source of truth: queries reflect disk state, and edits
          -- from queries persist to disk via writefile.  The drift check
          -- compares meta.task_text (the source line at render time) to the
          -- current ON-DISK line — reading the loaded buffer instead would
          -- silently mask external concurrent edits AND it would let us
          -- commit on top of an unrelated unsaved buffer state.  Inline a
          -- disk-only read; do NOT call cmd._read_source_line (which prefers
          -- the loaded buffer).
          local current_src
          do
            local ok, lines = pcall(vim.fn.readfile, meta.source_file)
            if ok and type(lines) == "table" then
              current_src = lines[meta.source_row + 1]
            end
          end

          if current_src == nil then
            log.warn("obsidian-tasks: cannot read source file — run <leader>tr to refresh")
          elseif current_src ~= meta.task_text then
            log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
          else
            -- cmd.apply_source_edit refuses to commit when a loaded source
            -- buffer has unsaved changes (which would otherwise silently
            -- commit those pending edits alongside our toggle).  It also
            -- handles index invalidate+refresh and avoids bufload (so a stale
            -- swap file from a crashed nvim session cannot truncate the file).
            local task = task_parse.parse(meta.task_text)
            if task then
              task.status_symbol = new_sym
              local new_line = serialize.serialize(task)
              local ok_commit = cmd.apply_source_edit(meta.source_file, meta.source_row, { new_line })
              if ok_commit then
                -- Record a pending linger keyed to the dashboard buffer — the
                -- same bufnr we're processing here is the one the user typed
                -- the status edit on, so it satisfies the "originated in this
                -- buffer" rule.  Promotion is gated on linger_on_filter_exit.
                local rmod = require("obsidian-tasks.render")
                if type(rmod._record_pending_linger) == "function" then
                  rmod._record_pending_linger(bufnr, meta.source_file, meta.source_row + 1, nil, task)
                end
              end
            end
          end
        end
      end
    end
  end
end

do_revert = function(bufnr)
  _scheduled[bufnr] = nil

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local hygiene = require("obsidian-tasks.render.hygiene")

  -- Capture cursor position before re-render.
  local wins = vim.fn.win_findbuf(bufnr)
  local cursor_save = nil
  if #wins > 0 then
    cursor_save = vim.api.nvim_win_get_cursor(wins[1])
  end

  -- Pass 1: propagate any recognized status edits to source BEFORE we wipe
  -- the managed rows.  After this pass, source files reflect any valid status
  -- changes the user typed directly on rendered rows.  Other edits do nothing
  -- in this pass — the subsequent rerender will visually restore them.
  --
  -- Run with on_lines suppressed: writes to the source buffer must not feed
  -- back into the dashboard's on_lines listener.  (The source buffer is a
  -- different buffer in any case, so the suppress is defensive — but cheap.)
  M.suppress(bufnr)
  pcall(classify_and_commit, bufnr)
  M.unsuppress(bufnr)

  -- undojoin merges the revert into the preceding user change so pressing
  -- <u> undoes the user's original edit rather than the revert separately.
  pcall(vim.cmd, "silent! undojoin")

  -- Wrap plugin mutations: keep them out of TextChanged/undo/modified.
  -- After a successful revert the managed rows are back to canonical, so the
  -- user has no pending source-changing edit on the dashboard — mark_clean.
  local ok, err
  hygiene.with_clean_buffer(bufnr, function()
    -- Suppress on_lines during our own buffer mutations to avoid recursion.
    M.suppress(bufnr)
    ok, err = pcall(function()
      -- Use the stored render function (injected by render/init.lua at attach
      -- time) rather than a lazy require.  The lazy-require path is kept as a
      -- fallback for callers (e.g. unit tests) that attach without providing a
      -- render_fn.  Importantly, the stored closure captures the real module
      -- table `M` of render/init.lua, so test mocks that replace
      -- package.loaded["obsidian-tasks.render.init"] cannot intercept it.
      local fn = _rerender_fn[bufnr]
      if fn then
        -- Two-step snapshot-based clear before re-render:
        --
        -- Step 1: Clear managed-namespace extmarks before removing lines.
        -- When the user's edit spans the entire managed region (e.g. a paste that
        -- replaces all rows including the task line), Neovim's extmark gravity
        -- heuristics can displace the region extmark to a wrong row.  If we let
        -- draw.clear() remove lines using the live extmark position it would delete
        -- the wrong line (e.g. a prose row).  Clearing managed extmarks first makes
        -- managed.all_regions() return {} during the subsequent render_buffer →
        -- clear_buffer → draw.clear call, so draw.clear only cleans up draw-NS
        -- extmarks without attempting any line removal.
        managed.clear_buffer(bufnr)

        -- Step 2: Remove managed task lines using snapshot positions.
        -- _region_snapshot holds the positions recorded at the last attach() call
        -- (i.e. just after the previous render), which are the correct pre-edit
        -- positions.  Remove from bottom to top so earlier indices stay valid.
        local snap = _region_snapshot[bufnr]
        if snap then
          for i = #snap, 1, -1 do
            vim.api.nvim_buf_set_lines(bufnr, snap[i][1], snap[i][2] + 1, false, {})
          end
        end

        -- Step 3: Re-render.  render_buffer calls clear_buffer internally; since
        -- managed extmarks were cleared in step 1, draw.clear's line-removal step
        -- is a no-op and only cleans up draw-NS extmarks and state tables.
        fn(bufnr, _workspace[bufnr])
      else
        local render = require("obsidian-tasks.render.init")
        render.rerender_buffer(bufnr, _workspace[bufnr])
      end
    end)
    M.unsuppress(bufnr)

    -- After the revert lands, the buffer text matches canonical — there are
    -- no pending user changes outside what we've just written.
    hygiene.mark_clean(bufnr)
  end)

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
    -- It is a real user edit, so the buffer now has pending unsaved content
    -- outside what we wrote — subsequent plugin re-renders must NOT clear the
    -- modified flag silently.
    require("obsidian-tasks.render.hygiene").mark_dirty(bufnr)

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
      -- Shift _meta_snapshot keys in tandem so row → meta lookups stay aligned.
      local old_meta = _meta_snapshot[bufnr] or {}
      local new_meta = {}
      for row, meta in pairs(old_meta) do
        if row >= last_line then
          new_meta[row + delta] = meta
        else
          new_meta[row] = meta
        end
      end
      _meta_snapshot[bufnr] = new_meta
    end
    return
  end

  -- Touched edit: also shift _region_snapshot / _meta_snapshot when the user
  -- inserts new line(s) at a region boundary (e.g. `o` on a folded fence row,
  -- which Vim resolves to "insert below the fold" — landing at the first row
  -- of the rendered region).  Without this update, do_revert deletes using
  -- stale pre-edit positions and corrupts every subsequent block.
  --
  -- Only apply to PURE INSERTIONS (last_line == first_line).  For replacements
  -- and deletes, the snapshot's pre-edit positions remain the safer reference:
  -- live extmark gravity becomes unreliable when a paste replaces a row
  -- that's adjacent to (or covers) a region.
  local delta = new_lastline - last_line
  if delta ~= 0 and last_line == first_line then
    local new_snapshot = {}
    for _, region in ipairs(snapshot) do
      if region[1] == first_line then
        -- Boundary insert at region start: expand to cover the inserted row(s)
        -- so revert removes both the user's edit and the (shifted) managed rows.
        new_snapshot[#new_snapshot + 1] = { region[1], region[2] + delta }
      elseif region[1] >= first_line then
        -- Region strictly below the insert: shift entirely by delta.
        new_snapshot[#new_snapshot + 1] = { region[1] + delta, region[2] + delta }
      else
        -- Region above the insert: position unchanged.
        new_snapshot[#new_snapshot + 1] = region
      end
    end
    _region_snapshot[bufnr] = new_snapshot

    -- Shift _meta_snapshot keys in tandem so row → meta lookups stay aligned
    -- with the live row numbers after the user's insert.
    local old_meta = _meta_snapshot[bufnr] or {}
    local new_meta = {}
    for row, meta in pairs(old_meta) do
      if row >= first_line then
        new_meta[row + delta] = meta
      else
        new_meta[row] = meta
      end
    end
    _meta_snapshot[bufnr] = new_meta
  end

  -- Debounce: schedule at most one revert pass per buffer.
  if _scheduled[bufnr] then
    return
  end
  _scheduled[bufnr] = true

  vim.schedule(function()
    do_revert(bufnr)
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Attach the on_lines listener to *bufnr*.
---
--- Idempotent: if already attached, only updates the stored workspace,
--- the rerender function, and the region snapshot from the current managed state.
--- Call this at the end of render_buffer (after managed regions are established).
---
--- @param bufnr       integer
--- @param workspace   table?     workspace object passed to rerender_buffer on revert
--- @param rerender_fn function?  function(bufnr, workspace) that performs the rerender.
---                               When provided, do_revert calls this directly instead
---                               of lazy-requiring render/init.lua.  The closure
---                               must capture the real module table so that test
---                               mocks cannot intercept it.
function M.attach(bufnr, workspace, rerender_fn)
  -- Always refresh workspace (may differ across rerenders), rerender function,
  -- and snapshot (managed regions are re-set by each render_buffer call).
  _workspace[bufnr] = workspace
  _region_snapshot[bufnr] = managed.all_regions(bufnr)

  -- Snapshot per-row task meta so classify_and_commit (do_revert pass 1) can
  -- look up canonical text + source coords by attach-time row, independent of
  -- where Neovim moves the extmark after the user's edit.
  local meta_snap = {}
  for _, region in ipairs(_region_snapshot[bufnr]) do
    for row = region[1], region[2] do
      local meta = managed.task_meta_for_row(bufnr, row)
      if meta then
        meta_snap[row] = meta
      end
    end
  end
  _meta_snapshot[bufnr] = meta_snap

  if rerender_fn ~= nil then
    _rerender_fn[bufnr] = rerender_fn
  end

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

--- Run the pending revert for *bufnr* synchronously (test seam).
---
--- In the normal event-loop path the revert is deferred via vim.schedule so
--- that Neovim finishes applying the user's change before we rewrite.  During
--- tests, vim.schedule inside mini.test case bodies causes callbacks to be
--- interleaved with other test callbacks, which makes assertions unreachable.
--- _flush_pending() bypasses vim.schedule and executes do_revert() directly,
--- giving tests a deterministic, synchronous execution path.
---
--- No-op when no revert is pending for *bufnr*.
--- @param bufnr integer
function M._flush_pending(bufnr)
  if not _scheduled[bufnr] then
    return
  end
  do_revert(bufnr)
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
  _meta_snapshot[bufnr] = nil
  _rerender_fn[bufnr] = nil
end

--- Classify a single-row edit on a managed dashboard row.
---
--- Classification branches:
---   "DELETE"            — new_text is empty or whitespace-only
---   "MUTATE"            — description or field change on a valid task line
---   "REPAIR_AND_MUTATE" — structural repair needed (missing `- ` prefix or
---                         `[ ]` checkbox); description/field change accepted
---   "INSERT"            — unmanaged row appearing between managed rows
---   "MULTI_LINE"        — neighbouring rows also changed in the same tick
---   "REVERT"            — no bullet/checkbox in a multi-line context → revert
---
--- Status-flip edits route through this function as a MUTATE branch.
---
--- @param bufnr    integer  dashboard buffer
--- @param row      integer  0-indexed row being classified
--- @param old_text string   canonical rendered text for this row (at render time)
--- @param new_text string   current buffer content for this row after the edit
--- @param ctx      table    edit context: { is_multi_line: boolean, is_insert: boolean, ... }
--- @return string  classification label
function M.classify(_bufnr, _row, _old_text, new_text, ctx)
  ctx = ctx or {}

  -- 1. DELETE — empty or whitespace-only new_text.
  if new_text == nil or new_text:match("^%s*$") then
    return "DELETE"
  end

  -- 2. INSERT — caller signals an unmanaged row appeared (old_text is nil).
  if ctx.is_insert then
    return "INSERT"
  end

  -- Structural helpers:
  --   has_bullet   — line starts with optional indent + list marker (`-`, `*`, `+`) + space
  --   has_checkbox — line contains a `[<char>]` pattern (any single-char status symbol)
  local has_bullet = new_text:match("^%s*[-*+]%s") ~= nil
  local has_checkbox = new_text:match("%[.%]") ~= nil

  -- 3. MULTI_LINE context — neighbouring rows also changed in the same tick.
  --    A structurally-valid row classifies as MULTI_LINE (flush layer decides
  --    whether to propagate or revert per Q3/Q6).  A row without structure reverts.
  if ctx.is_multi_line then
    if has_bullet and has_checkbox then
      return "MULTI_LINE"
    else
      return "REVERT"
    end
  end

  -- 4. Single-line classification by structural completeness.
  if has_bullet and has_checkbox then
    -- Full `- [<sym>] …` structure: normal mutation (description, field, or status flip).
    return "MUTATE"
  elseif has_bullet or has_checkbox then
    -- Partial structure: bullet without checkbox, or checkbox without bullet.
    -- Re-add the missing structural prefix so the flush layer can splice it back.
    return "REPAIR_AND_MUTATE"
  else
    -- No list structure at all on a managed row — revert.
    return "REVERT"
  end
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
