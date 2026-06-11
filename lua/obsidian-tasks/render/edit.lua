-- lua/obsidian-tasks/render/edit.lua
-- Tick-coalesced flush queue for managed dashboard edits (P5).
--
-- Design:
--   • flush(bufnr) scans all managed rows in the buffer, compares each row's
--     current text against its canonical rendered_text, and classifies the diff.
--   • MUTATE and REPAIR_AND_MUTATE rows are queued into per-src_path batches.
--   • For each src_path: a single read+write round-trip is performed via
--     cmd.apply_source_edit (Q13 coalescing).
--   • A single undo block per flush (per tick) is maintained across all
--     affected src_paths: if multiple files are written, their individual undo
--     ring entries are merged into a single _multi_file entry so that one
--     dashboard_undo() call reverses every source mutation from that tick.
--   • InsertLeave fires flush(bufnr) for insert-mode edits (wired in ot-v0s1).
--   • Per-file write failure: failed files revert their own dashboard rows;
--     other files in the same flush proceed (Q15, partial-success notify).
--   • REPAIR_AND_MUTATE: re-add missing structural prefix, splice the repaired
--     row back into the dashboard buffer, and shift the cursor right by the
--     number of characters inserted (Q10).
--
-- flush() is the ORCHESTRATOR; the pipeline phases live in sibling modules:
--   • render/edit_apply.lua  — per-file batch building + file writes/post-write
--   • render/edit_insert.lua — INSERT classification + block reconciliation
--   • render/edit_util.lua   — shared text helpers (strip/normalize/repair)

local M = {}

-- ── Per-buffer flush queue ────────────────────────────────────────────────────

--- Per-buffer pending flush queue.
--- Shape: flush_queue[bufnr] = { rows = { [row] = {old_text, new_text, mode} }, scheduled = bool }
---
--- Populated by on_lines_hook; consumed and cleared by flush.
M.flush_queue = {}

-- ── Public API ────────────────────────────────────────────────────────────────

--- Compute whether a successfully-propagated inline edit would visually move
--- the task row to a different group or within-group position.
---
--- Algorithm:
---   1. If both group_by and sort_by are empty → short-circuit moves=false
---      (optimization: no query dimension references any field, so no visual change).
---   2. If group_by is non-empty: resolve the post-edit group name(s) via
---      group_mod.resolve.  If the current group name is absent from the
---      post-edit set → moves=true (task left its current group).
---   3. If the task stays in the same group AND sort_by is non-empty: compare
---      the pre-edit and post-edit sort values via make_comparator.  If the
---      comparator orders them differently → the within-group position would
---      change → moves=true.
---   4. Otherwise → moves=false.
---
--- @param task_before table  Parsed Task at render time (pre-edit source state)
--- @param task_after  table  Parsed Task after the edit is applied
--- @param layout_ctx  table  { group_by, sort_by, src_path?, current_group_name, current_index }
--- @return table  { moves = bool, prior_group_name?, prior_index_within_group? }
function M._would_move(task_before, task_after, layout_ctx)
  local group_by = layout_ctx.group_by or {}
  local sort_by = layout_ctx.sort_by or {}

  -- Optimization: if neither group-by nor sort-by can produce a visual change,
  -- skip all computation.
  if #group_by == 0 and #sort_by == 0 then
    return { moves = false }
  end

  local src_path = layout_ctx.src_path
  local current_group = layout_ctx.current_group_name or ""
  local current_index = layout_ctx.current_index

  -- ── Step 1: group-change detection ─────────────────────────────────────────
  if #group_by > 0 then
    local group_mod = require("obsidian-tasks.query.group")
    local after_groups = group_mod.resolve(task_after, src_path, group_by)

    -- Check whether the task's current group is still present in the post-edit
    -- group set.  For tags (which can produce multiple groups per task), the
    -- task only leaves a group if that specific group name disappears.
    local still_in_group = false
    for _, name in ipairs(after_groups) do
      if name == current_group then
        still_in_group = true
        break
      end
    end

    if not still_in_group then
      return {
        moves = true,
        prior_group_name = current_group,
        prior_index_within_group = current_index,
      }
    end
  end

  -- ── Step 2: within-group sort-order shift detection ────────────────────────
  -- Conservative: if the comparator orders task_before and task_after
  -- differently from equal (i.e., one is strictly less than the other), the
  -- task's within-group position would change → record a linger.
  if #sort_by > 0 then
    local sort_mod = require("obsidian-tasks.query.sort")
    local before_wrapper = { task = task_before, path = src_path or "", _idx = 0 }
    local after_wrapper = { task = task_after, path = src_path or "", _idx = 0 }
    local cmp = sort_mod.make_comparator(sort_by)
    -- If before < after or after < before, the values differ in sort order.
    if cmp(before_wrapper, after_wrapper) or cmp(after_wrapper, before_wrapper) then
      return {
        moves = true,
        prior_group_name = current_group,
        prior_index_within_group = current_index,
      }
    end
  end

  return { moves = false }
end

--- Hook called from the on_lines listener when a managed row edit is queued
--- for deferred propagation to the source file.
---
--- In normal mode:
---   1. Enqueues the per-row old/new text into flush_queue[bufnr].rows[row].
---   2. Schedules flush(bufnr) for end-of-tick via vim.schedule (debounced:
---      at most one scheduled flush per buffer per tick).
---
--- In insert / replace mode: marks the buffer dirty and returns.  Flush will
--- be triggered by InsertLeave (wired in ot-v0s1).
---
--- @param bufnr     integer  dashboard buffer
--- @param row       integer  0-indexed row that changed
--- @param old_text  string   canonical rendered text for this row
--- @param new_text  string   current buffer content for this row after the edit
--- @param _ctx      table?   extra context forwarded from on_lines (reserved)
function M.on_lines_hook(bufnr, row, old_text, new_text, _ctx)
  -- Always enqueue the row.  Required so that insert-mode edits (i/a/o + typing)
  -- accumulate the FINAL edited text in the queue; flush() drains the queue at
  -- InsertLeave time.  The pre-fix code bailed before enqueue, leaving the
  -- queue empty so InsertLeave's flush was a no-op.
  M.flush_queue[bufnr] = M.flush_queue[bufnr] or { rows = {}, scheduled = false }
  M.flush_queue[bufnr].rows[row] = { old_text = old_text, new_text = new_text }
  local hygiene = require("obsidian-tasks.render.hygiene")
  if hygiene.in_insert_mode() then
    -- Insert/Replace mode: the buffer has unwritten user content, so any
    -- plugin re-render must NOT clear the modified flag silently.
    hygiene.mark_dirty(bufnr)
  end
  -- Schedule flush regardless of mode.  Flush gates itself at execution time
  -- (see flush()): a vim.schedule callback firing mid-typing would commit a
  -- half-typed line to source, so flush bails if mode is still i/R when it
  -- runs, leaving the queue intact for the next pass or InsertLeave drain.
  -- (Gating at schedule time would skip the `r X` path: mode is briefly "R"
  -- when on_lines fires, but normal again by the time the schedule executes.)
  if not M.flush_queue[bufnr].scheduled then
    M.flush_queue[bufnr].scheduled = true
    vim.schedule(function()
      M.flush(bufnr)
    end)
  end
end

--- Drain the pending flush for *bufnr* synchronously (test seam).
---
--- In normal operation flush is deferred via vim.schedule so that Neovim
--- finishes processing the user's change before we write.  During tests,
--- vim.schedule callbacks interleave with other case-callbacks and make
--- assertions unreachable.  _flush_pending() executes flush() directly,
--- giving tests a deterministic, synchronous execution path.
---
--- No-op when no flush is pending for *bufnr*.
--- @param bufnr integer
function M._flush_pending(bufnr)
  if not (M.flush_queue[bufnr] and M.flush_queue[bufnr].scheduled) then
    return
  end
  M.flush(bufnr)
end

--- Flush all pending edits for *bufnr* to their respective source files.
---
--- Scans all managed rows in the buffer, classifies each against its canonical
--- rendered_text, and propagates MUTATE / REPAIR_AND_MUTATE rows to source.
---
---   1. For each changed managed row: classify → build per-src_path batch.
---   2. Per src_path: locate (drift recovery), read once, apply bottom-up, write once.
---   3. All file writes in one flush share a single undo block: if > 1 file was
---      written, their individual undo ring entries are merged into a single
---      _multi_file entry (Q13: "single `u` reverses the tick").
---   4. On REPAIR_AND_MUTATE success: splice the repaired row back into the
---      dashboard buffer and shift the cursor right by prefix_inserted (Q10).
---   5. On per-file write failure: revert that file's dashboard rows to their
---      canonical rendered_text; emit a partial-success notification (Q15).
---
--- @param bufnr integer  dashboard buffer whose queued edits should be flushed
function M.flush(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    M.flush_queue[bufnr] = nil
    return
  end

  -- User is still in insert/replace mode: a vim.schedule callback fires
  -- between keystrokes, and writing the half-typed line to source would
  -- corrupt it.  Reset `scheduled` so the next on_lines event re-schedules,
  -- and leave the queue intact.  InsertLeave's drain calls flush() directly
  -- once mode is normal.
  if require("obsidian-tasks.render.hygiene").in_insert_mode() then
    if M.flush_queue[bufnr] then
      M.flush_queue[bufnr].scheduled = false
    end
    return
  end

  local revert = require("obsidian-tasks.render.revert")
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local render_init = require("obsidian-tasks.render.init")
  local edit_util = require("obsidian-tasks.render.edit_util")

  -- ── 1. Collect changed managed rows ────────────────────────────────────────
  --
  -- Use the render-time snapshot from revert.lua rather than live extmarks.
  -- Neovim shifts right-gravity extmarks when the user replaces a managed row
  -- (the extmark drifts past the replacement), making task_meta_for_row return
  -- nil at the original row.  The snapshot preserves the render-time row→meta
  -- mapping and is immune to this drift.
  --
  -- Pending deletes from on_lines are captured FIRST (before any INSERT
  -- processing that may trigger a re-render and reset snapshot state).
  -- on_lines accumulates managed rows that were deleted inside a region into
  -- _pending_deletes and updates _meta_snapshot / _region_snapshot in tandem,
  -- so those rows no longer appear in meta_by_row (preventing MUTATE
  -- misclassification when the next managed row shifts into the deleted slot).

  -- Capture pending deletes recorded by on_lines for touched DELETE events.
  local pending_on_lines_deletes = revert.take_pending_deletes(bufnr)

  local all_regions = revert.region_snapshot(bufnr)
  local meta_by_row = revert.meta_snapshot(bufnr)

  if #all_regions == 0 and #pending_on_lines_deletes == 0 then
    M.flush_queue[bufnr] = nil
    return
  end

  -- ── Sentinel growth: real newline(s) typed at the EOF sentinel ──────────────
  -- A <CR> on the sentinel row — which sits BELOW the virtual footer, OUTSIDE the
  -- dashboard — is the user adding a real newline to the end of the file.  Those
  -- blank rows were absorbed into the managed region (on_lines INSERT detection
  -- ignores blank rows); release them so they persist as real note content, then
  -- re-render so the footer re-anchors above the new content and the now-unneeded
  -- sentinel is not re-added (a real EOF line separates our footer from
  -- obsidian.nvim's).  See draw.release_sentinel_growth.
  if require("obsidian-tasks.render.draw").release_sentinel_growth(bufnr) then
    M.flush_queue[bufnr] = nil
    -- rerender_buffer (not render_buffer): D1 — a user-closed subtree fold (and the
    -- cursor) must survive the sentinel-release re-render.  render_buffer rebuilds
    -- every fold OPEN; rerender_buffer captures the closed (src_path:src_line)
    -- subtree roots first and re-closes them after the redraw.
    local rr_ok, rr_err = pcall(render_init.rerender_buffer, bufnr, nil)
    if not rr_ok then
      -- Do not swallow: a failed sentinel-release rerender leaves the footer
      -- anchored stale; the user needs a signal to run <leader>tr.
      log.warn("sentinel-release rerender failed: " .. tostring(rr_err))
    end
    -- Dirty-marking must run REGARDLESS of rerender success (and AFTER it: a
    -- successful render_buffer ends with mark_clean, which would otherwise
    -- erase the dirty baseline).  The released newline(s) are real unsaved
    -- note content — the buffer must never look saved/clean here.
    require("obsidian-tasks.render.hygiene").mark_dirty(bufnr)
    pcall(function()
      vim.bo[bufnr].modified = true
    end)
    return
  end

  -- Collect changed rows (MUTATE / REPAIR_AND_MUTATE), deleted rows, and
  -- inserted rows.
  --
  -- MUTATE / DELETE scan: iterates ALL meta_by_row entries.  With the
  -- pending_deletes mechanism, touched DELETE rows are removed from
  -- meta_by_row by on_lines; the remaining entries should match their
  -- rendered_text (shifted rows now occupy the correct keys after the
  -- on_lines meta update).  The nil-text check below is kept as a fallback
  -- for edge cases not covered by pending_deletes (e.g. out-of-region
  -- deletions that the untouched path handles differently).
  --
  -- INSERT scan: limited to the region snapshot, since INSERT rows are
  -- new rows the user typed inside a managed region (there is no meta).
  local changed = {} -- { row, meta, new_text, old_text, label }
  local delete_rows = {} -- { row, meta } for rows where new_text == nil
  local insert_rows = {} -- { row, new_text } for unmanaged rows with content

  -- Seed delete_rows with the pending deletes from on_lines touched DELETEs.
  -- These are processed with the same block-aware count logic as nil-text deletes.
  -- Read-only tree rows (BLANK only, Phase 5a) are never propagated to source;
  -- skip them here so deleting a blank doesn't issue a source DELETE.  Tree BULLET
  -- rows ARE deletable (Phase 5a): a deleted bullet issues a LITERAL source-line
  -- delete for its src_line (block-aware count covers its continuation lines).
  -- A literal bullet delete may orphan its children for now; Phase 5d adds
  -- delete-promote-orphans.  The subsequent rerender restores read-only blanks.
  for _, pd in ipairs(pending_on_lines_deletes) do
    if not (pd.meta and pd.meta.read_only) then
      delete_rows[#delete_rows + 1] = { row = pd.row, meta = pd.meta }
    end
  end

  for row, meta in pairs(meta_by_row) do
    -- Read-only tree rows (BLANK only, Phase 5a) are managed but never
    -- propagated to source: an edit to one is reverted by do_revert.  Skip
    -- classification so no MUTATE/DELETE write is queued.  Tree BULLET rows are
    -- NOT read-only — they fall through and are written back raw (is_bullet
    -- branch in edit_apply.build_batches).
    if not meta.read_only then
      local cur_lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
      local new_text = cur_lines[1]
      local old_text = meta.rendered_text
      if new_text == nil then
        -- Row no longer exists in the buffer → DELETE candidate (fallback path
        -- for cases where on_lines did not record a pending delete, e.g. the
        -- very last managed row was deleted and there are no rows below to shift).
        delete_rows[#delete_rows + 1] = { row = row, meta = meta }
      elseif old_text ~= nil and new_text ~= old_text then
        local label = revert.classify(bufnr, row, old_text, new_text, {})
        changed[#changed + 1] = {
          row = row,
          meta = meta,
          new_text = new_text,
          old_text = old_text,
          label = label,
        }
      end
    end
  end

  -- Map each managed row's canonical rendered_text → the ' [[target]]' backlink
  -- the plugin appended to it.  A row pasted in NORMAL mode (`p`) from elsewhere
  -- in the dashboard carries that rendered backlink verbatim; writing it to
  -- source as-is would bake a spurious backlink into the new task (and make it
  -- double-render on refresh).  When a freshly-inserted row's text matches a
  -- known rendered row, strip the appended backlink so source gets clean bytes.
  local rendered_backlink = {}
  for _, m in pairs(meta_by_row) do
    if m.rendered_text and m.wikilink_target and m.wikilink_target ~= "" then
      rendered_backlink[m.rendered_text] = m.wikilink_target
    end
  end

  -- INSERT detection: scan regions for non-meta rows with non-blank content.
  for _, region in ipairs(all_regions) do
    for row = region[1], region[2] do
      if not meta_by_row[row] then
        local cur_lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
        local new_text = cur_lines[1]
        if new_text ~= nil and not new_text:match("^%s*$") then
          local target = rendered_backlink[new_text]
          if target then
            new_text = edit_util.strip_wikilink_suffix(new_text, target)
          end
          insert_rows[#insert_rows + 1] = { row = row, new_text = new_text }
        end
      end
    end
  end

  -- ── P7: mass-delete safety gate ───────────────────────────────────────────
  -- If 2+ managed rows were deleted in this tick, check whether every
  -- registered tasks block still has its opening and closing fences.
  --
  --   delete_count == 1  → single `dd`; skip gate, propagate normally.
  --   delete_count >= 2, block intact  → propagate (intact multi-delete).
  --   delete_count >= 2, block broken  → revert all; warn; return early.
  --
  -- Gate runs BEFORE apply_source_edit so no linger entries are recorded for
  -- the rejected batch (satisfies the ot-3scr architect note).
  if #delete_rows >= 2 then
    local gate = require("obsidian-tasks.render.gate")
    if not gate.query_block_intact(bufnr) then
      log.warn("dashboard cleared — source untouched")
      M.flush_queue[bufnr] = nil
      return
    end
  end

  if #changed == 0 and #delete_rows == 0 and #insert_rows == 0 then
    M.flush_queue[bufnr] = nil
    return
  end

  -- ── 2. Build per-src_path batch edits (render/edit_apply.lua) ──────────────
  local edit_apply = require("obsidian-tasks.render.edit_apply")
  local edits_by_file, had_tree_delete = edit_apply.build_batches(changed, delete_rows)

  -- ── 3. Apply edits per source file (render/edit_apply.lua) ─────────────────
  local apply_res = edit_apply.apply_batches(bufnr, edits_by_file)
  local pushes_in_flush = apply_res.pushes_in_flush
  local had_mutate_applied = apply_res.had_mutate_applied
  local partial_failure = apply_res.partial_failure
  local locate_miss_occurred = apply_res.locate_miss_occurred

  -- ── 3b. Process INSERT rows (Q4 + Q11) — render/edit_insert.lua ────────────
  local edit_insert = require("obsidian-tasks.render.edit_insert")
  local ins = edit_insert.process_inserts(bufnr, insert_rows, delete_rows, meta_by_row)
  local had_successful_insert = ins.had_successful_insert
  pushes_in_flush = pushes_in_flush + ins.pushes_in_flush
  partial_failure = partial_failure or ins.partial_failure

  -- After successful INSERT(s): synchronously re-render the buffer so that
  -- _meta_snapshot and _region_snapshot reflect the new task(s).  Without this,
  -- the INSERT row has no managed extmark and every subsequent flush in the same
  -- tick re-detects it as an INSERT, writing duplicates to source.  Worse, rows
  -- that shifted down during the INSERT are misclassified as MUTATEs (their
  -- neighbour's text now occupies their stale meta slot) rather than DELETEs when
  -- the user removes them.  The re-render (via the already-scheduled do_revert
  -- path) reads fresh source state, assigns correct source_rows to all tasks, and
  -- makes subsequent flushes in the same session operate on accurate snapshots.
  -- A locate_miss recovers via the SAME canonical full re-render as a
  -- successful INSERT (do_revert reads fresh source/index and rebuilds the
  -- view).  Trigger it for either cause, but only once per flush so a flush
  -- that both inserted and hit drift does not re-render twice.
  --
  -- TREE delete (Phase 5d) also forces the canonical re-render here so the
  -- promote-orphans reflow is reflected in the dashboard from the UPDATED source.
  -- The revert debounce may schedule its own do_revert, but flush has already
  -- written + index-invalidated source, so rebuilding now reconciles the view
  -- against the reflowed bytes; the deferred do_revert is then a no-op (the
  -- buffer already matches canonical).
  if had_successful_insert or locate_miss_occurred or had_tree_delete then
    revert._flush_pending(bufnr)
  elseif had_mutate_applied then
    -- Grouped-dashboard live sync: under `group by ...` a mutate can leave sibling
    -- instances of a duplicated task stale (the surgical reanchor only updated the
    -- edited row) AND/OR change group membership — e.g. a newly-added tag must
    -- create its group, or move/remove the task from existing groups.  Issue ONE
    -- canonical re-render now — apply_source_edit already ran refresh_file
    -- synchronously, so the index is fresh and the re-render re-queries → re-groups
    -- → rebuilds ALL instances (picking up new tags/metadata).  This supersedes the
    -- surgical reanchor.  rerender_buffer suppresses on_lines internally (clean-buffer +
    -- revert.suppress), and flush_queue[bufnr] is cleared at the end of this flush,
    -- so it cannot recurse.  Gated to the mutate path; INSERT/DELETE keep their
    -- existing do_revert path above.  ws falls back to nil, mirroring the
    -- render_buffer(bufnr, nil) flush calls elsewhere.
    local render = require("obsidian-tasks.render")
    if type(render.rerender_buffer) == "function" then
      local ws
      pcall(function()
        ws = require("obsidian-tasks.util.obsidian").workspace_for_path(vim.api.nvim_buf_get_name(bufnr))
      end)
      pcall(render.rerender_buffer, bufnr, ws)
    end
  end

  -- Drift warn: emit ONCE per flush (not once per missed entry).  The write
  -- SUCCEEDED — the entry just could not be LOCATED — so this is distinct from
  -- the generic partial-write failure below.
  if locate_miss_occurred then
    log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
  end

  -- Q15: partial-success notification.  Fires only on a genuine write failure
  -- (per-file or INSERT).  A locate_miss does NOT set partial_failure, so this
  -- misleading notice is suppressed when drift is the sole cause.
  if partial_failure then
    log.warn("partial write failure — some files could not be written")
  end

  -- ── 4. Q13 multi-file undo merge ───────────────────────────────────────────
  -- All per-file undo entries added in this flush belong to the same "tick".
  -- Merge them into a single _multi_file entry so that one dashboard_undo()
  -- call reverses every source mutation from this tick.
  --
  -- We locate the new entries by their COUNT (pushes_in_flush), not by ring
  -- length delta: when the ring is at UNDO_RING_CAP, each push triggers a
  -- shift-out that hides the new entries behind a stable ring length.  The
  -- last `pushes_in_flush` entries of the ring are always the new ones.

  local ring = cmd._undo_ring[bufnr]
  local ring_after = ring and #ring or 0
  local new_entries = math.min(pushes_in_flush, ring_after)

  if new_entries > 1 then
    local merge_start = ring_after - new_entries + 1
    -- All merged entries share this tick's native undo position; carry it onto
    -- the combined entry so recency arbitration still works (see cmd.native_undo_seq).
    local merged_native_seq = ring[merge_start]._native_seq
    -- Collect per-file undo data from the individual entries that were just pushed.
    local file_batches = {}
    for i = merge_start, ring_after do
      local e = ring[i]
      file_batches[#file_batches + 1] = {
        src_path = e.src_path,
        batch_edits = e.batch_edits or {
          {
            src_row = e.src_row,
            old_count = e.old_count,
            old_lines = e.old_lines,
            new_count = e.new_count,
            new_lines = e.new_lines,
          },
        },
      }
    end
    -- Remove the individual entries.
    for i = ring_after, merge_start, -1 do
      ring[i] = nil
    end
    -- Push a single combined entry in their place.
    ring[merge_start] = {
      _multi_file = true,
      file_batches = file_batches,
      _native_seq = merged_native_seq,
    }
    cmd._undo_ring[bufnr] = ring
    -- Multi-file forward edit invalidates redo history (same contract as record_undo_edit).
    cmd._redo_ring[bufnr] = nil
  end

  -- ── 5. Q10 cursor shift ────────────────────────────────────────────────────
  -- For REPAIR_AND_MUTATE rows that were successfully flushed, shift the
  -- cursor right by prefix_inserted in any window currently showing this buffer.

  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    for _, file_data in pairs(edits_by_file) do
      for _, de in ipairs(file_data.dash_entries) do
        if de.label == "REPAIR_AND_MUTATE" and de.prefix_inserted > 0 then
          for _, win in ipairs(wins) do
            local cur_ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
            if cur_ok and cursor[1] == de.dash_row + 1 then
              pcall(vim.api.nvim_win_set_cursor, win, { cursor[1], cursor[2] + de.prefix_inserted })
            end
          end
        end
      end
    end
  end

  -- ── Cleanup ────────────────────────────────────────────────────────────────

  M.flush_queue[bufnr] = nil
end

return M
