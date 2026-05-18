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

-- Pending deletes accumulated by on_lines when managed rows are deleted inside
-- a managed region (touched DELETE).  Each entry is { row, meta } where row is
-- the pre-delete buffer row and meta is the task's snapshot meta (same object as
-- _meta_snapshot held before the update).  flush() reads these via
-- take_pending_deletes() so it can do block-aware source deletion for the correct
-- tasks instead of misclassifying them as MUTATEs (the shifted-in neighbour's
-- text at the same row is not nil, triggering MUTATE rather than DELETE).
local _pending_deletes = {} -- [bufnr] = { { row=integer, meta=table }, ... }

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

--- Walk every managed row, classify each via M.classify(), and propagate
--- recognized edits to the source file.
---
--- Rows whose content matches their canonical rendered_text contribute nothing.
--- Rows that classify as MUTATE AND carry a single status-symbol change get
--- committed to source via the resolver pipeline (same path as <leader>tt).
--- All other classifications fall through; the subsequent rerender restores them.
--- Non-status MUTATE edits (description/field changes) also fall through until
--- the batched-flush layer (ot-iyw1) wires them.
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
        -- Route every row through the per-row classifier so that status flips,
        -- description edits, deletes, etc. all follow a single classification
        -- path.  ctx is unused — the classifier only depends on new_text.
        local label = M.classify(bufnr, row, meta.rendered_text, current, {})

        if label == "MUTATE" then
          -- Within the MUTATE branch, only single status-symbol changes are
          -- committed in this phase.  Description/field changes fall through to
          -- the rerender until the batched-flush layer (ot-iyw1) generalises
          -- this path.
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
        -- DELETE / REPAIR_AND_MUTATE all fall through here; the subsequent
        -- rerender restores the managed rows.  (INSERTs are handled by flush()
        -- via its own region scan, not via classify_and_commit.)
      end
    end
  end
end

do_revert = function(bufnr)
  _scheduled[bufnr] = nil

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- User is still in insert/replace mode: rerender_buffer would wipe their
  -- in-flight typing.  Bail; InsertLeave's drain calls force_revert() once
  -- mode is normal.  Don't re-set _scheduled — the next on_lines event will
  -- create a fresh schedule if needed.
  if vim.fn.mode():match("[iR]") then
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
  -- [first_line, check_end) when: r_start < check_end AND r_end >= first_line.
  -- The "+1" on r_end accommodates pure inserts immediately past the region
  -- (e.g. `o` on the last managed row) — that new row should be treated as an
  -- appended task belonging to the region, so flush()'s INSERT detection
  -- can pick it up.
  local touched = false
  for _, region in ipairs(snapshot) do
    if region[1] < check_end and region[2] + 1 >= first_line then
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

  -- Touched edit: update _region_snapshot / _meta_snapshot to reflect the user's
  -- change so do_revert removes/inserts the correct rows and flush() classifies
  -- each row correctly.
  --
  -- PURE INSERTION (last_line == first_line, delta > 0):
  --   Expand any region whose boundary or interior overlaps the insert point.
  --   Three cases for a region R:
  --     R.start == first_line   → boundary-at-start: expand end by delta.
  --     R.start >  first_line   → region strictly below: shift start+end by delta.
  --     R.end + 1 >= first_line → insert INSIDE region OR immediately past its
  --                               end (R.start < first_line <= R.end + 1): expand
  --                               end only.  "Immediately past end" covers
  --                               `o` on the last managed row, which opens a
  --                               new line at R.end + 1 — the new row belongs
  --                               to the region as an appended task.
  --     otherwise               → region entirely above: no change.
  --
  -- PURE DELETION (last_line > first_line, delta < 0):
  --   Record the deleted managed rows as pending_deletes for flush() to handle
  --   as block-aware source DELETEs.  Without this, the next-managed-row shifts
  --   into the deleted slot and flush() misclassifies it as a MUTATE, writing
  --   the wrong task to the deleted task's source position and leaving the
  --   deleted task's continuation note behind.
  local delta = new_lastline - last_line
  if delta > 0 and last_line == first_line then
    -- ── PURE INSERTION ──────────────────────────────────────────────────────────
    local new_snapshot = {}
    for _, region in ipairs(snapshot) do
      if region[1] > first_line then
        -- Region strictly below the insert: shift entirely by delta.
        new_snapshot[#new_snapshot + 1] = { region[1] + delta, region[2] + delta }
      elseif region[2] + 1 >= first_line then
        -- Insert at, inside, or immediately past the region
        -- (region.start <= first_line <= region.end + 1): expand the end to
        -- cover the inserted row(s) and any shifted managed rows.  The "+1"
        -- accommodates `o` on the last managed row, which inserts at
        -- region.end + 1 — the new row belongs to the region as an appended
        -- task and flush()'s INSERT detection needs to see it.
        new_snapshot[#new_snapshot + 1] = { region[1], region[2] + delta }
      else
        -- Region entirely above the insert: position unchanged.
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
  elseif delta < 0 and last_line > first_line then
    -- ── TOUCHED DELETION ────────────────────────────────────────────────────────
    -- Record every managed row in [first_line, last_line) as a pending delete.
    -- flush() will read these via take_pending_deletes() and perform block-aware
    -- source deletion (task + continuation lines) for the correct tasks.
    --
    -- Also update _region_snapshot and _meta_snapshot so subsequent on_lines
    -- events and flush() scans see accurate positions for the surviving rows.
    local old_meta = _meta_snapshot[bufnr] or {}
    local pending = _pending_deletes[bufnr] or {}
    local new_meta = {}
    for row, meta in pairs(old_meta) do
      if row >= first_line and row < last_line then
        -- Row was deleted: record as pending delete for flush().
        pending[#pending + 1] = { row = row, meta = meta }
      elseif row >= last_line then
        -- Row survived and shifted up: move to new position.
        new_meta[row + delta] = meta
      else
        -- Row is above the deletion range: unchanged.
        new_meta[row] = meta
      end
    end
    _pending_deletes[bufnr] = pending
    _meta_snapshot[bufnr] = new_meta

    -- Shrink / shift region snapshot to match the new buffer layout.
    local new_snapshot = {}
    for _, region in ipairs(snapshot) do
      if region[2] < first_line then
        -- Region entirely above deletion: unchanged.
        new_snapshot[#new_snapshot + 1] = region
      elseif region[1] >= last_line then
        -- Region entirely below deletion: shift up.
        new_snapshot[#new_snapshot + 1] = { region[1] + delta, region[2] + delta }
      else
        -- Region overlaps deletion: shrink the end.
        local new_end = region[2] + delta
        if new_end >= region[1] then
          new_snapshot[#new_snapshot + 1] = { region[1], new_end }
        end
        -- else: entire region was deleted → discard.
      end
    end
    _region_snapshot[bufnr] = new_snapshot
  end

  -- Notify the edit flush layer about each touched managed row so that
  -- normal-mode edits are propagated to their source files at end-of-tick
  -- (on_lines_hook → flush_queue → vim.schedule(flush)).
  --
  -- This call must happen BEFORE the debounce guard below so that
  -- multi-row edits within a single tick (e.g. `:s/foo/bar/g`) still call
  -- on_lines_hook for every changed row even when _scheduled was already
  -- set by an earlier on_lines call in the same tick.
  --
  -- Wrapped in pcall: errors in edit.lua must not disrupt the revert path.
  pcall(function()
    local edit_m = require("obsidian-tasks.render.edit")
    local meta_by_row = _meta_snapshot[bufnr] or {}
    for row = first_line, check_end - 1 do
      local meta = meta_by_row[row]
      if meta then
        local cur = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
        edit_m.on_lines_hook(bufnr, row, meta.rendered_text, cur[1], {})
      end
    end
    -- If the deletion erased every managed row in the touched range, the loop
    -- above had no rows to schedule and flush would never run — yet
    -- _pending_deletes still holds the deleted rows that need block-aware
    -- source delete + P7 gate evaluation.  Schedule flush directly so flush
    -- can drain pending_deletes (e.g. ggdG that wipes the whole dashboard).
    if _pending_deletes[bufnr] and #_pending_deletes[bufnr] > 0 then
      edit_m.flush_queue[bufnr] = edit_m.flush_queue[bufnr] or { rows = {}, scheduled = false }
      if not edit_m.flush_queue[bufnr].scheduled then
        edit_m.flush_queue[bufnr].scheduled = true
        vim.schedule(function()
          edit_m.flush(bufnr)
        end)
      end
    end
  end)

  -- Debounce: schedule at most one revert pass per buffer.
  -- (do_revert gates itself on mode at execution time — scheduling
  -- unconditionally is correct for the `r X` path, where mode is briefly "R"
  -- when on_lines fires but normal by the time the schedule executes.)
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

--- Run do_revert unconditionally, ignoring the _scheduled debounce flag.
---
--- Used by the InsertLeave autocmd to drain a revert pass that bailed during
--- typing (when do_revert ran in insert/replace mode it returned early
--- without doing the rerender).  Safe to call when nothing is pending — the
--- buffer-validity and rerender_fn checks make it a no-op.
---
--- @param bufnr integer
function M.force_revert(bufnr)
  do_revert(bufnr)
end

--- Return and clear the pending deletes accumulated by on_lines for *bufnr*.
---
--- flush() calls this once at the start of each flush cycle to collect the
--- managed rows that were deleted since the last snapshot.  The list is cleared
--- atomically so a subsequent re-render (triggered by the same flush via
--- _flush_pending) does not see stale entries from a previous delete event.
---
--- @param bufnr integer
--- @return table  list of { row=integer, meta=table }; empty if none pending
function M.take_pending_deletes(bufnr)
  local pending = _pending_deletes[bufnr] or {}
  _pending_deletes[bufnr] = nil
  return pending
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
  _pending_deletes[bufnr] = nil
  _rerender_fn[bufnr] = nil
end

--- Classify a single-row edit on a managed dashboard row.
---
--- Classification branches:
---   "DELETE"            — new_text is empty or whitespace-only
---   "MUTATE"            — description or field change on a valid task line
---   "REPAIR_AND_MUTATE" — structural repair needed (missing `- ` prefix or
---                         `[ ]` checkbox); description/field change accepted
---
--- Status-flip edits route through this function as a MUTATE branch.
---
--- INSERT and MULTI_LINE classifications were considered but flush() detects
--- INSERTs via its own region/meta scan (no classify call) and never passes a
--- multi-line ctx; the corresponding branches were removed as dead code.
---
--- @param bufnr    integer  dashboard buffer (unused; kept for signature stability)
--- @param row      integer  0-indexed row being classified (unused)
--- @param old_text string   canonical rendered text for this row (unused)
--- @param new_text string   current buffer content for this row after the edit
--- @param ctx      table?   reserved for future use; currently ignored
--- @return string  classification label: DELETE / MUTATE / REPAIR_AND_MUTATE
function M.classify(_bufnr, _row, _old_text, new_text, _ctx)
  -- 1. DELETE — empty or whitespace-only new_text.
  if new_text == nil or new_text:match("^%s*$") then
    return "DELETE"
  end

  -- Structural helpers:
  --   has_bullet   — line starts with optional indent + list marker (`-`, `*`, `+`) + space
  --   has_checkbox — line contains a `[<char>]` pattern (any single-char status symbol)
  local has_bullet = new_text:match("^%s*[-*+]%s") ~= nil
  local has_checkbox = new_text:match("%[.%]") ~= nil

  -- 2. Single-line classification by structural completeness.
  if has_bullet and has_checkbox then
    -- Full `- [<sym>] …` structure: normal mutation (description, field, or status flip).
    return "MUTATE"
  else
    -- Partial or no list structure: re-add the missing prefix via the flush
    -- layer's REPAIR_AND_MUTATE splice (Q10 preserves cursor offset).
    return "REPAIR_AND_MUTATE"
  end
end

--- Return the snapshot of managed regions for *bufnr* at the last render time.
---
--- The snapshot is captured by attach() after each render_buffer call and is
--- NOT shifted when the user replaces rows (unlike live extmarks, which Neovim
--- shifts on replace/paste).  flush() uses this for reliable row → meta lookup.
---
--- @param bufnr integer
--- @return table  list of { start_row, end_row } 0-indexed inclusive
function M.region_snapshot(bufnr)
  return _region_snapshot[bufnr] or {}
end

--- Return the per-row task-meta snapshot for *bufnr* at the last render time.
---
--- Keys are 0-indexed row numbers at the time of the last attach() call.
--- Values are the same meta table objects shared with managed._task_meta, so
--- mutations to returned meta objects (e.g. source_row updates) are visible
--- to all subsequent callers.
---
--- @param bufnr integer
--- @return table  { [row] = { source_file, source_row, task_text, rendered_text } }
function M.meta_snapshot(bufnr)
  return _meta_snapshot[bufnr] or {}
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
