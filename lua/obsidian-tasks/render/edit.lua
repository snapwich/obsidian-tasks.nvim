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

local M = {}

-- ── Per-buffer flush queue ────────────────────────────────────────────────────

--- Per-buffer pending flush queue.
--- Shape: flush_queue[bufnr] = { rows = { [row] = {old_text, new_text, mode} }, scheduled = bool }
---
--- Populated by on_lines_hook; consumed and cleared by flush.
M.flush_queue = {}

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Strip the wikilink suffix ' [[<basename>]]' from *text* when it matches
--- the expected basename for *src_path*.  Returns *text* unchanged otherwise.
---
--- @param text     string
--- @param src_path string
--- @return string
local function strip_wikilink_suffix(text, src_path)
  if not src_path or src_path == "" then
    return text
  end
  local basename = vim.fn.fnamemodify(src_path, ":t:r")
  local suffix = " [[" .. basename .. "]]"
  if #text >= #suffix and text:sub(-#suffix) == suffix then
    return text:sub(1, -(#suffix + 1))
  end
  return text
end

--- Q2 date normalization: replace natural-language date values with ISO dates.
---
--- Parses *text* as a task.  For each date field whose value failed ISO
--- validation (stored in task._raw_fields), attempts to convert the value via
--- cmp/date_nl.lua.  If successful, promotes the value to task.fields and
--- re-serializes the task.  Returns *text* unchanged when no normalization is
--- needed (including when parse returns nil, e.g. for a bare description).
---
--- Re-serialization preserves the per-field format (emoji vs dataview) via
--- format="preserve".  Field ORDER in the output follows FIELD_ORDER (the
--- canonical order from serialize.lua) — this is an acceptable side effect of
--- parse-and-reserialize; the locked Q2 decision explicitly permits value
--- normalization while accepting that structural re-ordering is a by-product
--- when NL dates are present.
---
--- @param text string
--- @return string
local function normalize_date_fields(text)
  local task_parse = require("obsidian-tasks.task.parse")
  local task_serialize = require("obsidian-tasks.task.serialize")
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  local fields_mod = require("obsidian-tasks.task.fields")

  local task = task_parse.parse(text)
  if not task then
    return text
  end

  local raw_fields = task._raw_fields or {}
  local normalized = false

  for _, f in ipairs(fields_mod.fields) do
    if f.kind == "date" then
      local raw_val = raw_fields[f.key]
      if raw_val ~= nil then
        local iso = date_nl.parse(raw_val)
        if iso then
          -- Promote from invalid → valid
          task.fields[f.key] = iso
          task._raw_fields[f.key] = nil
          if task._errors then
            task._errors[f.key] = nil
          end
          if task._invalid_ranges then
            task._invalid_ranges[f.key] = nil
          end
          normalized = true
        end
      end
    end
  end

  if not normalized then
    return text
  end

  -- Re-serialize preserving emoji/dataview format per field.
  return task_serialize.serialize(task)
end

--- Compute the re-added structural prefix for a REPAIR_AND_MUTATE row and
--- return the repaired text plus the number of characters inserted at the start.
---
--- @param text string  the write_text after wikilink stripping
--- @return string repaired_text, integer prefix_inserted
local function repair_prefix(text)
  local has_bullet = text:match("^%s*[-*+]%s") ~= nil
  local has_checkbox = text:match("%[.%]") ~= nil

  if not has_bullet and not has_checkbox then
    -- Neither present: prepend the full "- [ ] " prefix.
    return "- [ ] " .. text, 6
  elseif not has_checkbox then
    -- Has bullet but no checkbox: insert "[ ] " right after the bullet + space.
    local after_bullet = text:match("^%s*[-*+]%s()")
    if after_bullet then
      return text:sub(1, after_bullet - 1) .. "[ ] " .. text:sub(after_bullet), 4
    end
    -- Fallback (shouldn't happen given has_bullet is true).
    return "- [ ] " .. text, 6
  else
    -- Has checkbox but no bullet: prepend "- ".
    return "- " .. text, 2
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Hook called from the on_lines listener when a managed row edit is queued
--- for deferred propagation to the source file.
---
--- In the real implementation this:
---   1. Classifies the edit via render/revert.classify.
---   2. On MUTATE / REPAIR_AND_MUTATE: enqueues a per-file edit record into
---      flush_queue[bufnr].
---   3. Schedules flush(bufnr) for end-of-tick via vim.schedule (at most once
---      per buffer per tick — debounced).
---
--- Insert-mode path (marks dirty, defers to InsertLeave) is wired in ot-v0s1.
---
--- @param bufnr     integer  dashboard buffer
--- @param row       integer  0-indexed row that changed
--- @param old_text  string   canonical rendered text for this row
--- @param new_text  string   current buffer content for this row after the edit
--- @param ctx       table?   extra context forwarded from on_lines
function M.on_lines_hook(_bufnr, _row, _old_text, _new_text, _ctx) end

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

  local revert = require("obsidian-tasks.render.revert")
  local managed_mod = require("obsidian-tasks.render.managed")
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local render_init = require("obsidian-tasks.render.init")

  -- ── 1. Collect changed managed rows ────────────────────────────────────────
  --
  -- Use the render-time snapshot from revert.lua rather than live extmarks.
  -- Neovim shifts right-gravity extmarks when the user replaces a managed row
  -- (the extmark drifts past the replacement), making task_meta_for_row return
  -- nil at the original row.  The snapshot preserves the render-time row→meta
  -- mapping and is immune to this drift.

  local all_regions = revert.region_snapshot(bufnr)
  local meta_by_row = revert.meta_snapshot(bufnr)

  if #all_regions == 0 then
    M.flush_queue[bufnr] = nil
    return
  end

  local changed = {} -- { row, meta, new_text, old_text, label }
  for _, region in ipairs(all_regions) do
    for row = region[1], region[2] do
      local meta = meta_by_row[row]
      if meta then
        local cur_lines = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)
        local new_text = cur_lines[1]
        local old_text = meta.rendered_text
        if new_text ~= nil and old_text ~= nil and new_text ~= old_text then
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
  end

  if #changed == 0 then
    M.flush_queue[bufnr] = nil
    return
  end

  -- ── 2. Build per-src_path batch edits ──────────────────────────────────────

  -- edits_by_file[src_path] = { batch = [...], dash_entries = [...] }
  -- where batch entries are passed to apply_source_edit,
  -- and dash_entries carry dashboard-side state for post-write updates.
  local edits_by_file = {}

  for _, entry in ipairs(changed) do
    local label = entry.label
    if label == "MUTATE" or label == "REPAIR_AND_MUTATE" then
      local meta = entry.meta
      local src_path = meta.source_file
      local new_text = entry.new_text

      -- Step A: strip expected wikilink suffix.
      local wikilink_suffix = " [[" .. vim.fn.fnamemodify(src_path, ":t:r") .. "]]"
      local write_text = strip_wikilink_suffix(new_text, src_path)

      -- Step B: REPAIR_AND_MUTATE — re-add missing structural prefix.
      local prefix_inserted = 0
      if label == "REPAIR_AND_MUTATE" then
        write_text, prefix_inserted = repair_prefix(write_text)
      end

      -- Step C: Q2 — normalize natural-language date field values to ISO dates.
      write_text = normalize_date_fields(write_text)

      -- Accumulate into per-file batch.
      if not edits_by_file[src_path] then
        edits_by_file[src_path] = { batch = {}, dash_entries = {} }
      end
      local file_data = edits_by_file[src_path]
      local idx = #file_data.batch + 1
      file_data.batch[idx] = {
        row = meta.source_row,
        new_lines = { write_text },
        count = 1,
        expected_text = meta.task_text, -- used by M.locate for drift recovery (Q12)
      }
      file_data.dash_entries[idx] = {
        dash_row = entry.row,
        meta = meta,
        write_text = write_text,
        wikilink_suffix = wikilink_suffix,
        prefix_inserted = prefix_inserted,
        label = label,
      }
    end
    -- DELETE / INSERT / MULTI_LINE / REVERT: do nothing here; the scheduled
    -- do_revert (from the on_lines listener) will restore those rows.
  end

  -- ── 3. Apply edits per source file ─────────────────────────────────────────

  -- Note the undo ring length before writes so we can merge multi-file entries.
  cmd._undo_ring[bufnr] = cmd._undo_ring[bufnr] or {}
  local ring_before = #cmd._undo_ring[bufnr]

  local partial_failure = false

  for src_path, file_data in pairs(edits_by_file) do
    -- Q13: single read+write per src_path; one undo ring entry per file.
    local ok, result = cmd.apply_source_edit(src_path, 0, {}, {
      batch = file_data.batch,
      dashboard_bufnr = bufnr,
    })

    if ok then
      -- Q12: update extmark source_row when drift recovery located a different row.
      if result and result.entries then
        for i, re in ipairs(result.entries) do
          local de = file_data.dash_entries[i]
          if re.applied and re.located_row ~= nil then
            de.meta.source_row = re.located_row
          end
        end
      end

      -- Update live extmark meta to reflect the new canonical state so future
      -- on_lines comparisons use the post-flush rendered and source texts.
      for _, de in ipairs(file_data.dash_entries) do
        de.meta.task_text = de.write_text
        de.meta.rendered_text = de.write_text .. de.wikilink_suffix
      end

      -- Q10: REPAIR_AND_MUTATE — splice the repaired row back into the buffer
      -- and shift the cursor right by the number of inserted prefix chars.
      for _, de in ipairs(file_data.dash_entries) do
        if de.label == "REPAIR_AND_MUTATE" and de.prefix_inserted > 0 then
          local new_rendered = de.write_text .. de.wikilink_suffix
          revert.suppress(bufnr)
          pcall(vim.api.nvim_buf_set_lines, bufnr, de.dash_row, de.dash_row + 1, false, { new_rendered })
          revert.unsuppress(bufnr)
        end
      end

      -- Re-anchor task extmarks at their render-time dashboard rows.
      -- Neovim shifts right-gravity extmarks when the user replaces a managed
      -- row; we restore the extmark position after each successful flush so
      -- task_meta_for_row remains callable at the original row (Q12 post-flush
      -- source_row check, future edits, etc.).
      for _, de in ipairs(file_data.dash_entries) do
        managed_mod.reanchor_task(bufnr, de.meta, de.dash_row)
      end

      -- Refresh source-buffer diagnostics so invalid-field highlights are
      -- retained after the flush (lenient-parser P2 invariant, Q3).
      local src_bufnr_val = vim.fn.bufnr(src_path, false)
      if src_bufnr_val ~= -1 and vim.api.nvim_buf_is_valid(src_bufnr_val) then
        render_init.refresh_source_diagnostics(src_bufnr_val, src_path)
      end
    else
      -- Q15: per-file write failure — revert this file's dashboard rows to
      -- their canonical rendered_text so the buffer stays consistent.
      partial_failure = true
      for _, de in ipairs(file_data.dash_entries) do
        revert.suppress(bufnr)
        pcall(vim.api.nvim_buf_set_lines, bufnr, de.dash_row, de.dash_row + 1, false, { de.meta.rendered_text })
        revert.unsuppress(bufnr)
      end
    end
  end

  -- Q15: partial-success notification.
  if partial_failure then
    log.warn("partial write failure — some files could not be written")
  end

  -- ── 4. Q13 multi-file undo merge ───────────────────────────────────────────
  -- All per-file undo entries added in this flush belong to the same "tick".
  -- Merge them into a single _multi_file entry so that one dashboard_undo()
  -- call reverses every source mutation from this tick.

  local ring = cmd._undo_ring[bufnr]
  local ring_after = ring and #ring or 0
  local new_entries = ring_after - ring_before

  if new_entries > 1 then
    -- Collect per-file undo data from the individual entries that were just pushed.
    local file_batches = {}
    for i = ring_before + 1, ring_after do
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
    for i = ring_after, ring_before + 1, -1 do
      ring[i] = nil
    end
    -- Push a single combined entry.
    ring[ring_before + 1] = {
      _multi_file = true,
      file_batches = file_batches,
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
