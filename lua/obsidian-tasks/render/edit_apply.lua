-- lua/obsidian-tasks/render/edit_apply.lua
-- Per-file batch building + file-write/post-write phase of the dashboard flush
-- pipeline.  Extracted mechanically from render/edit.lua's flush(); edit.lua
-- remains the orchestrator and calls build_batches → apply_batches in order.
--
--   • build_batches: classified rows (MUTATE / REPAIR_AND_MUTATE) and DELETE
--     rows → per-src_path batches for cmd.apply_source_edit (Q13 coalescing),
--     including the flat block-count and tree delete_reflow.plan DELETE paths.
--   • apply_batches: per-file write via cmd.apply_source_edit + post-write
--     dashboard reconciliation (linger recording, meta refresh, Q10 splice,
--     extmark reanchor, Q15 per-file failure revert).

local edit_util = require("obsidian-tasks.render.edit_util")

local M = {}

--- Compute the number of lines in the deletion block rooted at *task_row* in
--- *lines* (1-indexed array of source file content).
---
--- Mirrors the Q14 walk in cmd.delete_block: walk forward past all continuation
--- lines (indented deeper than task_indent, or blank-followed-by-indented) and
--- return task_row..end_row inclusive count.  Falls back to 1 when *lines* is
--- nil.
---
--- @param lines       table    1-indexed array of source file lines (from readfile)
--- @param task_row    integer  0-indexed source row of the task to delete
--- @param task_indent integer  number of leading whitespace chars of the task line
--- @return integer  count (>= 1)
local function compute_block_count(lines, task_row, task_indent)
  if not lines then
    return 1
  end
  local n = #lines

  local function is_blank(line)
    return line:match("^%s*$") ~= nil
  end

  local end_row = task_row
  local i = task_row + 1

  while i < n do
    local line = lines[i + 1] -- 1-indexed

    if is_blank(line) then
      local next_i = i + 1
      while next_i < n and is_blank(lines[next_i + 1]) do
        next_i = next_i + 1
      end
      if next_i >= n or edit_util.indent_of(lines[next_i + 1]) <= task_indent then
        break
      end
      end_row = i
      i = i + 1
    elseif edit_util.indent_of(line) <= task_indent then
      break
    else
      end_row = i
      i = i + 1
    end
  end

  return end_row - task_row + 1
end

--- Build the per-src_path batch edits for one flush tick.
---
--- @param changed     table[]  { {row, meta, new_text, old_text, label}, … }
--- @param delete_rows table[]  { {row, meta}, … }
--- @return table edits_by_file, boolean had_tree_delete
---   edits_by_file[src_path] = { batch = [...], dash_entries = [...] }
---   where batch entries are passed to apply_source_edit,
---   and dash_entries carry dashboard-side state for post-write updates.
function M.build_batches(changed, delete_rows)
  local edits_by_file = {}

  for _, entry in ipairs(changed) do
    local label = entry.label
    if label == "MUTATE" or label == "REPAIR_AND_MUTATE" then
      local meta = entry.meta
      local src_path = meta.source_file
      local new_text = entry.new_text

      -- Step A: strip the wikilink suffix layout appended.  meta.wikilink_target
      -- is the exact link text rendered (alias or basename), or nil when the
      -- row carried no suffix (e.g. a `hide backlinks` query) — in which case
      -- wikilink_suffix is "" so flush re-applies nothing.
      local wikilink_suffix = meta.wikilink_target and (" [[" .. meta.wikilink_target .. "]]") or ""
      local write_text = edit_util.strip_wikilink_suffix(new_text, meta.wikilink_target)

      -- Tree task rows render with a depth-relative 2-space indent that differs
      -- from the task's ON-DISK indent whenever the vault doesn't nest with
      -- exactly 2 spaces.  meta.source_indent (set only for tree task rows) is the
      -- original source leading whitespace; the dashboard line keeps its
      -- depth-relative indent.  Flat rows have no source_indent → is_tree=false.
      --
      -- INDENT and BODY are kept SEPARATE through the whole write pipeline so the
      -- source form and the dashboard form derive from the SAME repaired body and
      -- can never diverge.  Marker repair (repair_prefix) operates on the BODY
      -- ONLY (never on indent), then the appropriate indent is prepended AFTER:
      --   • SOURCE write      = meta.source_indent .. final_body
      --   • DASHBOARD rendered = depth_indent      .. final_body
      -- This is correct on BOTH the MUTATE and REPAIR_AND_MUTATE paths; flat rows
      -- skip the split entirely and run the original pipeline byte-for-byte.
      local is_tree = meta.source_indent ~= nil
      -- A tree BULLET row (description line, no checkbox).  Its write-back is RAW
      -- (Phase 5a): no task serialize, no `- [ ]` repair_prefix, no date
      -- normalization — the body is written verbatim, prefixed by the original
      -- marker + a space.  bullet_marker presence (set by draw from layout)
      -- distinguishes a bullet from a tree TASK row that also carries
      -- source_indent.  A user who edits a bullet INTO a checkbox ("- [ ] x")
      -- is NOT special-cased: the raw write lands the literal text and the next
      -- index/render reclassifies the line as a child task (§6 classifier).
      local is_bullet = meta.bullet_marker ~= nil
      local dash_rendered
      local prefix_inserted = 0
      -- Bug 1: set when a FLAT row's source indent was re-applied (flush display,
      -- indented source) so the dash_entries splice uses the flush dash_rendered.
      local flat_reindented = false

      if is_bullet then
        local marker = meta.bullet_marker
        -- The dashboard line's leading whitespace IS the depth-relative indent.
        local depth_indent = new_text:match("^(%s*)") or ""
        -- Strip the depth indent AND the displayed marker (+ following space) to
        -- recover the edited BODY.  Pattern: optional ws, the marker, optional
        -- space.  If the user removed/changed the marker, the strip falls back to
        -- just removing leading whitespace so their literal text round-trips raw
        -- (reclassified on the next index pass).
        local body = write_text:gsub("^%s*", "")
        local stripped = body:match("^" .. vim.pesc(marker) .. "%s?(.*)$")
        if stripped ~= nil then
          body = stripped
        end
        -- SOURCE form: original raw indent + marker + space + body.
        -- DASHBOARD form: depth-relative indent + marker + space + body.
        -- Both derive from the SAME body so they can never diverge.
        write_text = meta.source_indent .. marker .. " " .. body
        dash_rendered = depth_indent .. marker .. " " .. body .. wikilink_suffix
      elseif is_tree then
        -- The dashboard line's leading whitespace IS the depth-relative indent.
        local depth_indent = new_text:match("^(%s*)") or ""
        -- Strip the depth indent so repair operates on the bare body.
        local body = write_text:gsub("^%s*", "")

        -- Step B (tree): REPAIR_AND_MUTATE — re-add missing structural prefix on
        -- the indent-stripped BODY (the marker is repaired into the body, never
        -- ahead of the indent).
        if label == "REPAIR_AND_MUTATE" then
          body, prefix_inserted = edit_util.repair_prefix(body)
        end

        -- Step C: Q2 — normalize natural-language date field values to ISO dates.
        -- Run on the bare body, then re-derive both indented forms from the same
        -- final_body so they stay byte-identical apart from the indent.
        local final_body = edit_util.normalize_date_fields(body)

        write_text = meta.source_indent .. final_body
        -- Dashboard form re-appends the wikilink suffix that was stripped above so
        -- the spliced line / rendered_text matches the actual buffer content
        -- (which carries the suffix) on the next on_lines comparison.
        dash_rendered = depth_indent .. final_body .. wikilink_suffix
      else
        -- Flat (non-tree) row: original pipeline.
        -- Step B: REPAIR_AND_MUTATE — re-add missing structural prefix.
        if label == "REPAIR_AND_MUTATE" then
          write_text, prefix_inserted = edit_util.repair_prefix(write_text)
        end

        -- Step C: Q2 — normalize natural-language date field values to ISO dates.
        write_text = edit_util.normalize_date_fields(write_text)

        -- Bug 1: a matched CHILD in a FLAT query renders FLUSH-LEFT, but its
        -- source line is indented.  Re-apply the original on-disk indent to the
        -- SOURCE write while the DASHBOARD keeps the flush form — the same
        -- source-indent/display-indent split the tree branch performs above.
        if meta.flat_source_indent then
          local body = write_text:gsub("^%s*", "")
          dash_rendered = body .. wikilink_suffix
          write_text = meta.flat_source_indent .. body
          flat_reindented = true
        end
      end

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
        -- Dashboard-side rendered form (depth-relative indent + repaired body);
        -- used to refresh meta.rendered_text AND to splice the repaired row back
        -- into the buffer for tree rows whose source indent differs from their
        -- dashboard indent.  nil for non-tree rows (falls back to write_text ..
        -- suffix, the prior behavior).
        dash_rendered = (is_tree or is_bullet or flat_reindented) and dash_rendered or nil,
        wikilink_suffix = wikilink_suffix,
        prefix_inserted = prefix_inserted,
        label = label,
      }
    end
    -- DELETE: handled below via the per-file batch DELETE path (block-aware).
    -- The classifier no longer returns INSERT / MULTI_LINE / REVERT (the
    -- corresponding ctx flags were never wired) — INSERTs are detected by
    -- the separate region/meta scan in flush().
  end

  -- ── DELETE rows → block-aware (flat) OR delete-promote-orphans (tree) ───────
  -- FLAT delete (no tree meta): each deleted managed row removes its source task
  -- AND all continuation lines (Q14 block-aware delete) via apply_source_edit
  -- with new_lines={}, count=N.  N is computed by walking the source file from
  -- the task row forward past all continuation lines (cmd.delete_block algorithm).
  --
  -- TREE delete (Phase 5d, show_tree_v1.md §8): deletion is LITERAL for the
  -- removed line(s), THEN any SURVIVING orphaned children are PROMOTED one level
  -- via render/delete_reflow.plan and the reflow is written as part of the SAME
  -- batch / undo entry.  A FOLDED-subtree dd arrives with the whole subtree's
  -- managed rows in the delete set → plan() finds no survivors → no promotion
  -- (whole block removed).  An EXPANDED single-line dd has only the parent in the
  -- set → plan() shifts its surviving descendants up one level.  All tree deletes
  -- for ONE file are reconciled together (one plan() call) so same-tick deletes
  -- coordinate against a single fresh disk read.
  --
  -- Source file content is cached per src_path so that multiple DELETE rows from
  -- the same file read the file only once during batch construction.
  -- (apply_source_edit reads the file again when applying — that is acceptable.)
  local src_lines_cache = {}
  local function disk_lines_for(src_path)
    if src_lines_cache[src_path] == nil then
      local ok_r, sl = pcall(vim.fn.readfile, src_path)
      src_lines_cache[src_path] = (ok_r and type(sl) == "table") and sl or false
    end
    return src_lines_cache[src_path] or nil
  end

  -- A delete row is a TREE row when its meta carries any tree marker (depth /
  -- source_indent / tree_kind / bullet_marker).  Flat rows carry none of these
  -- and keep the byte-identical block-aware delete path.
  local function is_tree_delete(meta)
    return meta.source_indent ~= nil or meta.depth ~= nil or meta.tree_kind ~= nil or meta.bullet_marker ~= nil
  end

  -- Partition deletes: flat rows handled per-row; tree rows grouped per src_path
  -- for a single delete_reflow.plan() pass.
  local tree_deletes_by_file = {} -- src_path → { rows = {0-indexed}, dash_rows = {row→dr} }
  for _, dr in ipairs(delete_rows) do
    local meta = dr.meta
    local src_path = meta.source_file
    if is_tree_delete(meta) and meta.source_row ~= nil then
      local g = tree_deletes_by_file[src_path]
      if not g then
        g = { rows = {}, metas = {}, dash_rows = {} }
        tree_deletes_by_file[src_path] = g
      end
      g.rows[#g.rows + 1] = meta.source_row
      g.metas[meta.source_row] = meta
      g.dash_rows[meta.source_row] = dr.row
    else
      -- FLAT delete: block-aware count (byte-identical prior behavior).
      if not edits_by_file[src_path] then
        edits_by_file[src_path] = { batch = {}, dash_entries = {} }
      end
      local file_data = edits_by_file[src_path]
      local idx = #file_data.batch + 1
      local task_indent = edit_util.indent_of(meta.task_text)
      local block_count = compute_block_count(disk_lines_for(src_path), meta.source_row, task_indent)
      file_data.batch[idx] = {
        row = meta.source_row,
        new_lines = {},
        count = block_count,
        expected_text = meta.task_text,
      }
      file_data.dash_entries[idx] = {
        dash_row = dr.row,
        meta = meta,
        write_text = nil,
        wikilink_suffix = "",
        prefix_inserted = 0,
        label = "DELETE",
      }
    end
  end

  -- TREE delete-promote-orphans: one plan() per file over all its tree deletes.
  local delete_reflow = require("obsidian-tasks.render.delete_reflow")
  local had_tree_delete = false
  for src_path, g in pairs(tree_deletes_by_file) do
    local disk = disk_lines_for(src_path)
    if disk then
      had_tree_delete = true
      if not edits_by_file[src_path] then
        edits_by_file[src_path] = { batch = {}, dash_entries = {} }
      end
      local file_data = edits_by_file[src_path]
      local plan_edits = delete_reflow.plan(disk, g.rows)
      for _, pe in ipairs(plan_edits) do
        local idx = #file_data.batch + 1
        -- expected_text = the verbatim disk line at pe.row so M.locate matches
        -- exactly (drift recovery).  For a count>1 delete this is the first
        -- removed line; for a 1-for-1 promotion replacement it is the line being
        -- re-indented.
        file_data.batch[idx] = {
          row = pe.row,
          new_lines = pe.new_lines,
          count = pe.count,
          expected_text = disk[pe.row + 1],
        }
        -- dash_entries carry DELETE for removed rows so the post-write loops skip
        -- meta/extmark updates; a promotion replacement also routes through the
        -- canonical re-render (the dashboard rebuilds from the reflowed source),
        -- so it needs no dashboard-side splice — mark it DELETE-like (no buffer
        -- mutation here) and let the trailing re-render reconcile the view.
        file_data.dash_entries[idx] = {
          dash_row = g.dash_rows[pe.row],
          meta = g.metas[pe.row],
          write_text = nil,
          wikilink_suffix = "",
          prefix_inserted = 0,
          label = "DELETE",
        }
      end
    end
  end

  return edits_by_file, had_tree_delete
end

--- Apply the per-src_path batches built by build_batches and perform all
--- post-write dashboard reconciliation (linger recording, meta refresh, Q10
--- splice, extmark reanchor, Q15 per-file failure revert).
---
--- @param bufnr         integer  dashboard buffer
--- @param edits_by_file table    result of build_batches
--- @return table  { pushes_in_flush, had_mutate_applied, partial_failure,
---                  locate_miss_occurred }
function M.apply_batches(bufnr, edits_by_file)
  local revert = require("obsidian-tasks.render.revert")
  local managed_mod = require("obsidian-tasks.render.managed")
  local cmd = require("obsidian-tasks.cmd")
  local render_init = require("obsidian-tasks.render.init")

  -- Track per-flush pushes explicitly so the multi-file merge in flush() works
  -- even when the undo ring is at UNDO_RING_CAP.  Using `#ring` delta is
  -- unreliable at the cap: each push triggers a shift-out, so ring_after -
  -- ring_before underreports (or returns 0).
  cmd._undo_ring[bufnr] = cmd._undo_ring[bufnr] or {}
  local pushes_in_flush = 0

  -- Set when an APPLIED (not missed) MUTATE / REPAIR_AND_MUTATE on the CURRENT
  -- dashboard could change its GROUPING.  A grouped query (`group by ...`) maps
  -- one source task to one OR MORE rows by its field values, so a mutate can:
  --   • leave sibling instances of a duplicated task stale (the surgical reanchor
  --     below only fixes the edited row), and/or
  --   • change which groups the task belongs to — e.g. adding a tag for a group
  --     that does not exist yet must CREATE that group with the task in it.
  -- Neither is handled by the surgical reanchor, and both need a re-query.  When
  -- this flag is set, flush() issues ONE canonical rerender_buffer at the very
  -- end — the index is already fresh (apply_source_edit ran refresh_file
  -- synchronously), so the rerender re-queries, re-groups by any new tags, and
  -- rebuilds ALL instances.  Gated to dashboards that actually GROUP so a flat
  -- (ungrouped) dashboard keeps the cheaper surgical reanchor (and its extmark
  -- source_row is not reset by a re-query); INSERT / DELETE keep their existing
  -- _flush_pending re-render.
  local had_mutate_applied = false

  -- Does any rendered block in this dashboard have a `group by`?  Grouping is the
  -- only thing a same-buffer mutate can restructure (duplicate instances and
  -- new-group creation both stem from it); a flat dashboard never needs the
  -- re-query.  Read from the render-time buffer state (block.group_by, [] when
  -- ungrouped).
  local has_grouping = false
  do
    local bs = render_init._buffer_state and render_init._buffer_state[bufnr]
    if bs then
      for _, blk in ipairs(bs) do
        if blk.group_by and #blk.group_by > 0 then
          has_grouping = true
          break
        end
      end
    end
  end

  local partial_failure = false
  -- Set when ANY entry came back unapplied with reason=="locate_miss" (genuine
  -- concurrent external drift).  Recovery is deferred to a single canonical
  -- full re-render at the end of flush (the same <leader>tr / do_revert path),
  -- which rebuilds the view from source/index with zero row-shift hazard — so
  -- MUTATE, DELETE, and REPAIR_AND_MUTATE misses are all handled uniformly and
  -- no managed row can be clobbered or vanish.  Per-row nvim_buf_set_lines
  -- surgery here is unsafe for DELETE: the deleted row is already gone from the
  -- buffer, so de.dash_row now holds the (shifted-up) NEXT row and overwriting
  -- it would clobber an innocent neighbour.
  local locate_miss_occurred = false

  for src_path, file_data in pairs(edits_by_file) do
    -- Q13: single read+write per src_path; one undo ring entry per file.
    -- pcall guard: a THROWN error from apply_source_edit (as opposed to a
    -- returned ok=false) must not escape the per-file loop — it would skip the
    -- revert for this file AND every remaining file, leaving buffer/snapshot
    -- state inconsistent.  Route a throw into the same Q15 revert path below.
    local call_ok, ok, result = pcall(cmd.apply_source_edit, src_path, 0, {}, {
      batch = file_data.batch,
      dashboard_bufnr = bufnr,
    })
    if not call_ok then
      require("obsidian-tasks.log").error("apply_source_edit failed for " .. src_path .. ": " .. tostring(ok))
      ok, result = false, nil
    end

    if ok then
      pushes_in_flush = pushes_in_flush + 1

      -- A successful batch write (ok==true) can still contain entries that were
      -- NOT applied because M.locate could not find their expected source line
      -- (reason=="locate_miss") — genuine concurrent external drift.  Left
      -- unhandled these are SILENT DATA LOSS: meta is not updated, the row is not
      -- reverted, and the user's typed edit vanishes on the next rerender with no
      -- feedback.  Mirror the status-flip path's drift handling (revert.lua
      -- classify_and_commit): revert each missed dashboard row to its canonical
      -- rendered_text AND warn.  Applies to BOTH bullet and task rows.  Missed
      -- entries are collected so the per-entry update loops below skip them
      -- (their meta must stay canonical, not adopt the un-written edit).
      -- Collect missed entries so the per-entry meta/extmark update loops below
      -- skip them (their meta must stay canonical, not adopt the un-written
      -- edit).  Do NOT touch the buffer here — recovery is the deferred full
      -- re-render (locate_miss_occurred), which is DELETE-safe.  The drift warn
      -- is emitted ONCE per flush after the file loop, not once per entry.
      local missed = {}
      if result and result.entries then
        for i, re in ipairs(result.entries) do
          if not re.applied and re.reason == "locate_miss" then
            missed[i] = true
            locate_miss_occurred = true
          end
        end
      end

      -- Q12: update extmark source_row when drift recovery located a different row.
      -- Tree delete-promote-orphans (Phase 5d) emits reflow entries (promotion
      -- replacements + coalesced deletes) that do NOT map back to a single managed
      -- row, so de.meta is nil for them — guard before indexing.  Those rows are
      -- reconciled by the trailing canonical re-render, not by extmark surgery.
      if result and result.entries then
        for i, re in ipairs(result.entries) do
          local de = file_data.dash_entries[i]
          if de.meta and re.applied and re.located_row ~= nil then
            de.meta.source_row = re.located_row
          end
        end
      end

      -- Record a pending linger for each successfully applied MUTATE.  The
      -- promotion step in render_buffer only emits a linger when the task
      -- actually exits the live filter set, so recording unconditionally here
      -- is safe — it covers status flips that filter the task out (the
      -- common case for `<CR>` smart-toggle and direct `r x` edits) AND
      -- group/sort moves, with the same single code path that toggle.lua
      -- uses for `<leader>tt`.
      --
      -- Performed BEFORE the meta update below so de.meta carries pre-edit
      -- source coords.
      if result and result.entries then
        local task_parse_mod = require("obsidian-tasks.task.parse")
        for i, re in ipairs(result.entries) do
          if re.applied then
            local de = file_data.dash_entries[i]
            if (de.label == "MUTATE" or de.label == "REPAIR_AND_MUTATE") and has_grouping then
              -- An applied mutate on a GROUPED dashboard: a re-query is required so
              -- sibling instances pick up the new text/tags AND group membership is
              -- recomputed (a new tag may create a brand-new group, or move/remove
              -- the task from existing groups).  See had_mutate_applied.  Flat
              -- dashboards skip this (cheaper surgical reanchor suffices).
              had_mutate_applied = true
            end
            if de.label ~= "DELETE" then
              local task_after = task_parse_mod.parse(de.write_text)
              if task_after then
                render_init._record_pending_linger(
                  bufnr,
                  de.meta.source_file,
                  (de.meta.source_row or 0) + 1,
                  nil,
                  task_after
                )
              end
            end
          end
        end
      end

      -- Update live extmark meta to reflect the new canonical state so future
      -- on_lines comparisons use the post-flush rendered and source texts.
      -- DELETE entries have no new content and their extmarks will be orphaned;
      -- skip the update to avoid nil-concatenation crashes.
      for i, de in ipairs(file_data.dash_entries) do
        -- Skip entries that hit locate_miss: their meta must stay canonical (not
        -- adopt an edit that never reached disk).  The deferred full re-render at
        -- the end of flush rebuilds their row from source.
        if de.label ~= "DELETE" and not missed[i] then
          de.meta.task_text = de.write_text
          -- For tree rows the dashboard line keeps its depth-relative indent
          -- (de.dash_rendered), which differs from the source-indented write_text;
          -- use the dashboard form so the next on_lines comparison matches the
          -- actual buffer line.  Flat rows have nil dash_rendered → prior path.
          de.meta.rendered_text = de.dash_rendered or (de.write_text .. de.wikilink_suffix)
        end
      end

      -- Q10: REPAIR_AND_MUTATE — splice the repaired row back into the buffer
      -- and shift the cursor right by the number of inserted prefix chars.
      for i, de in ipairs(file_data.dash_entries) do
        if de.label == "REPAIR_AND_MUTATE" and de.prefix_inserted > 0 and not missed[i] then
          -- Tree rows splice the DEPTH-indented dashboard form (de.dash_rendered,
          -- which already carries the wikilink suffix); flat rows fall back to the
          -- source-indented write_text + suffix (prior, byte-identical behavior).
          local new_rendered = de.dash_rendered or (de.write_text .. de.wikilink_suffix)
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
      -- DELETE entries have no live dashboard row to anchor to; skip them.
      -- locate_miss entries had no edit land; the deferred full re-render at the
      -- end of flush rebuilds their extmarks, so skip the reanchor here.
      for i, de in ipairs(file_data.dash_entries) do
        if de.label ~= "DELETE" and not missed[i] then
          managed_mod.reanchor_task(bufnr, de.meta, de.dash_row)
        end
      end

      -- Refresh source-buffer diagnostics so invalid-field highlights are
      -- retained after the flush (lenient-parser P2 invariant, Q3).
      local src_bufnr_val = vim.fn.bufnr(src_path, false)
      if src_bufnr_val ~= -1 and vim.api.nvim_buf_is_valid(src_bufnr_val) then
        render_init.refresh_source_diagnostics(src_bufnr_val, src_path)
      end
    else
      -- Q15: per-file write failure — revert this file's dashboard rows to
      -- their canonical rendered_text so the buffer stays consistent.  Tree
      -- delete-promote-orphans (Phase 5d) reflow entries have no single managed
      -- row (de.meta / de.dash_row are nil) — skip them; the trailing canonical
      -- re-render reconciles the unchanged source for those.
      partial_failure = true
      for _, de in ipairs(file_data.dash_entries) do
        if de.meta and de.dash_row ~= nil and de.meta.rendered_text ~= nil then
          revert.suppress(bufnr)
          pcall(vim.api.nvim_buf_set_lines, bufnr, de.dash_row, de.dash_row + 1, false, { de.meta.rendered_text })
          revert.unsuppress(bufnr)
        end
      end
    end
  end

  return {
    pushes_in_flush = pushes_in_flush,
    had_mutate_applied = had_mutate_applied,
    partial_failure = partial_failure,
    locate_miss_occurred = locate_miss_occurred,
  }
end

return M
