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

--- Strip the wikilink suffix ' [[<target>]]' from *text* when it matches the
--- *target* layout appended at render time ('basename' or 'basename|alias').
--- *target* is nil when the row was rendered without a suffix (no source path,
--- or a `hide backlinks` query), in which case *text* is returned unchanged.
---
--- Delegates to render/wikilink.strip_expected_suffix so the flush path and the
--- public helper share a single implementation (unit tests for strip_expected_suffix
--- therefore cover the code that actually runs during flush).
---
--- @param text   string
--- @param target string|nil  rendered wikilink target (meta.wikilink_target)
--- @return string
local function strip_wikilink_suffix(text, target)
  if not target or target == "" then
    return text
  end
  return require("obsidian-tasks.render.wikilink").strip_expected_suffix(text, target)
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

--- Count the leading whitespace characters in *line*.
--- @param line string
--- @return integer
local function indent_of(line)
  if not line then
    return 0
  end
  local s = line:match("^(%s*)")
  return s and #s or 0
end

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
      if next_i >= n or indent_of(lines[next_i + 1]) <= task_indent then
        break
      end
      end_row = i
      i = i + 1
    elseif indent_of(line) <= task_indent then
      break
    else
      end_row = i
      i = i + 1
    end
  end

  return end_row - task_row + 1
end

--- Compute the re-added structural prefix for a REPAIR_AND_MUTATE row and
--- return the repaired text plus the number of characters inserted at the start.
---
--- @param text string  the write_text after wikilink stripping
--- @return string repaired_text, integer prefix_inserted
local function repair_prefix(text)
  local has_bullet = text:match("^%s*[-*+]%s") ~= nil
  local has_checkbox = text:match("%[.%]") ~= nil

  if has_bullet and has_checkbox then
    -- Already well-formed: idempotent no-op.
    return text, 0
  elseif not has_bullet and not has_checkbox then
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

--- Collect every managed row strictly above *insert_row* (top→anchor order,
--- read-only BLANK rows excluded) as the `rows_above` description consumed by
--- the INSERT classifier / block reconciler.  rows_above[#rows_above] is the
--- immediate anchor (first managed row above the insert).
---
--- @param meta_by_row table    row→meta snapshot (revert.meta_snapshot)
--- @param insert_row  integer  0-indexed buffer row of the (first) inserted line
--- @return table[]   { {depth, kind, meta, dash_row}, … } top→anchor
local function collect_rows_above(meta_by_row, insert_row)
  local rows_above = {}
  for r = 0, insert_row - 1 do
    local m = meta_by_row[r]
    -- Exclude read-only BLANK rows: they have no stable depth/kind to attach to
    -- or clamp against.  Tree BULLET rows are NOT read-only (Phase 5a) and DO
    -- participate.
    if m and not m.read_only then
      rows_above[#rows_above + 1] = {
        depth = m.depth or 0,
        kind = (m.bullet_marker ~= nil) and "description" or "task",
        meta = m,
        dash_row = r,
        -- Phase 2 group-attr gate context: whether this managed row is a LIT
        -- matched root.  (group_name is intentionally NOT carried here: the gate
        -- now walks parent_line and the P9 context is resolved from blk.line_map
        -- by build_p9_group_context, so a rows_above group_name was dead.)
        matched = m.matched or false,
        -- TRUE structural coordinates for the group-attr gate's parent-chain
        -- walk: source line of this row and its structural parent's source line
        -- (parent_line, nil at top level).  Threaded from the node model via
        -- layout → draw meta.  source_file scopes the (file,line) key so two
        -- files sharing a line number never cross-match.
        src_line = (m.source_row ~= nil) and (m.source_row + 1) or nil,
        src_path = m.source_file,
        parent_line = m.parent_line,
      }
    end
  end
  return rows_above
end

--- Build the P9 group-attr injection context for an INSERT anchored at
--- *anchor_dashboard_row*.  Reads the dashboard's per-block buffer state to
--- resolve the anchor row's group_by directives + group_name into a
--- group_attr.inject_group_attributes context, and infers the emoji/dataview
--- emit form from the anchor task's _origin.
---
--- Supported group types: tag, priority, status.  File / folder / heading /
--- path / root / backlink: no auto-add (skipped).  Returns ({}, nil) when there
--- is no anchor row or no matching block state — a no-op inject.
---
--- Shared by the FLAT and TREE insert paths so P9 behavior is byte-identical
--- across both (the tree path additionally GATES on the matched-ancestor walk).
---
--- @param bufnr                integer
--- @param anchor_dashboard_row integer|nil  0-indexed dashboard row of the anchor
--- @param anchor_meta          table|nil    anchor row meta (for task_text/_origin)
--- @return table p9_group_context, table|nil p9_task_origin
local function build_p9_group_context(bufnr, anchor_dashboard_row, anchor_meta)
  local p9_group_context = {}
  local p9_task_origin = nil
  if anchor_dashboard_row == nil then
    return p9_group_context, p9_task_origin
  end
  local render_init = require("obsidian-tasks.render.init")
  local bs = render_init._buffer_state[bufnr]
  if bs then
    for _, blk in ipairs(bs) do
      local row_meta = blk.line_map and blk.line_map[anchor_dashboard_row]
      if row_meta then
        local group_by = blk.group_by or {}
        local gname = row_meta.group_name or ""
        -- Combined group_name "seg1 / seg2 / …" split by level.
        local segments = vim.split(gname, " / ", { plain = true })
        for i, directive in ipairs(group_by) do
          local key = directive.key
          local seg = segments[i] or ""
          if key == "tags" then
            -- Strip the "#" prefix so inject receives the bare tag name.
            p9_group_context[#p9_group_context + 1] = {
              by = "tag",
              value = seg:match("^#(.+)$") or seg,
            }
          elseif key == "priority" then
            -- Reverse-parse "Priority N: Name" to the canonical level name.
            local level = seg:match("Priority %d+: (%a+)$")
            if level then
              level = level:lower()
            else
              level = seg:lower()
            end
            p9_group_context[#p9_group_context + 1] = {
              by = "priority",
              value = level,
            }
          elseif key == "status" then
            -- Pass the status group name (e.g. "In Progress"); inject will look
            -- up the symbol via status.by_name.
            p9_group_context[#p9_group_context + 1] = {
              by = "status",
              value = seg,
            }
          end
          -- Other keys (file/folder/heading/path/date/…): no auto-add.
        end
        break
      end
    end
  end
  -- Infer task_origin from the anchor task's _origin so inject knows whether to
  -- emit emoji or dataview form for the appended attribute.
  if anchor_meta and anchor_meta.task_text then
    local task_parse_p9 = require("obsidian-tasks.task.parse")
    local anchor_task_p9 = task_parse_p9.parse(anchor_meta.task_text)
    if anchor_task_p9 then
      p9_task_origin = anchor_task_p9._origin
    end
  end
  return p9_group_context, p9_task_origin
end

--- Walk the resolved parent chain of a tree INSERT among *rows_above* and report
--- whether any ANCESTOR is a LIT MATCHED row.
---
--- The new row is dragged into its group by subtree-drag IFF it sits beneath a
--- matched task (or any of that task's lit descendants).  This walk starts at the
--- resolved PARENT row and climbs the TRUE STRUCTURAL parent chain — each step
--- follows the row's `parent_line` (the node model's real parent source line) to
--- the ancestor row that owns it — returning true as soon as it hits a row with
--- matched == true.  Climbing by parent_line (not by nearest-row-at-depth-1) is
--- correct when a group holds MULTIPLE matched roots whose breadcrumb chains
--- share depths: the depth heuristic could land on an unrelated sibling subtree
--- and mis-decide injection; following parent_line stays on the row's own branch.
---
--- When true, the group attribute must NOT be injected (the row is already pulled
--- into the group); when false (top-level insert, or a chain of only DIM
--- breadcrumbs / non-matched rows), it MUST be injected.
---
--- @param rows_above   table[]    { {depth, matched, src_path, src_line, parent_line, …}, … } top→anchor
--- @param parent_index integer|nil  resolved parent's index into rows_above (nil = top-level)
--- @return boolean  true when a matched ancestor is present in the parent chain
local function has_matched_ancestor_in_chain(rows_above, parent_index)
  if parent_index == nil then
    return false -- top-level insert: no parent chain, always inject.
  end
  -- Index rows by their (src_path, src_line) so a parent_line resolves to the
  -- exact owning row, scoped per file.
  local by_line = {}
  for _, row in ipairs(rows_above) do
    if row.src_path and row.src_line then
      by_line[row.src_path .. "\0" .. tostring(row.src_line)] = row
    end
  end

  local row = rows_above[parent_index]
  local guard = 0 -- defensive bound against a malformed parent cycle
  while row ~= nil and guard <= #rows_above do
    guard = guard + 1
    if row.matched then
      return true
    end
    -- Climb to this row's TRUE structural parent via parent_line.  nil → reached
    -- a top-level row with no matched ancestor.
    local pl = row.parent_line
    if pl == nil or row.src_path == nil then
      break
    end
    row = by_line[row.src_path .. "\0" .. tostring(pl)]
  end
  return false
end

--- Group an ASCENDING-row-ordered insert_rows array into CONTIGUOUS blocks.
--- Two inserted rows belong to the same block iff their buffer rows are adjacent
--- (row, row+1, …) — i.e. a single InsertLeave's typed/pasted run with no managed
--- row interleaved.  A non-contiguous gap (a managed row between two inserts)
--- starts a new block.
---
--- @param insert_rows table[]   { {row, new_text}, … } ascending by row
--- @return table[]   array of blocks, each { {row, new_text}, … }
local function group_insert_blocks(insert_rows)
  local blocks = {}
  local cur = nil
  for _, ir in ipairs(insert_rows) do
    if cur and ir.row == cur[#cur].row + 1 then
      cur[#cur + 1] = ir
    else
      cur = { ir }
      blocks[#blocks + 1] = cur
    end
  end
  return blocks
end

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
  local mode = vim.fn.mode()
  if mode:match("[iR]") then
    -- Insert/Replace mode: the buffer has unwritten user content, so any
    -- plugin re-render must NOT clear the modified flag silently.
    require("obsidian-tasks.render.hygiene").mark_dirty(bufnr)
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
  if vim.fn.mode():match("[iR]") then
    if M.flush_queue[bufnr] then
      M.flush_queue[bufnr].scheduled = false
    end
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
    pcall(render_init.rerender_buffer, bufnr, nil)
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
    -- branch below).
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
            new_text = strip_wikilink_suffix(new_text, target)
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

      -- Step A: strip the wikilink suffix layout appended.  meta.wikilink_target
      -- is the exact link text rendered (alias or basename), or nil when the
      -- row carried no suffix (e.g. a `hide backlinks` query) — in which case
      -- wikilink_suffix is "" so flush re-applies nothing.
      local wikilink_suffix = meta.wikilink_target and (" [[" .. meta.wikilink_target .. "]]") or ""
      local write_text = strip_wikilink_suffix(new_text, meta.wikilink_target)

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
          body, prefix_inserted = repair_prefix(body)
        end

        -- Step C: Q2 — normalize natural-language date field values to ISO dates.
        -- Run on the bare body, then re-derive both indented forms from the same
        -- final_body so they stay byte-identical apart from the indent.
        local final_body = normalize_date_fields(body)

        write_text = meta.source_indent .. final_body
        -- Dashboard form re-appends the wikilink suffix that was stripped above so
        -- the spliced line / rendered_text matches the actual buffer content
        -- (which carries the suffix) on the next on_lines comparison.
        dash_rendered = depth_indent .. final_body .. wikilink_suffix
      else
        -- Flat (non-tree) row: original pipeline.
        -- Step B: REPAIR_AND_MUTATE — re-add missing structural prefix.
        if label == "REPAIR_AND_MUTATE" then
          write_text, prefix_inserted = repair_prefix(write_text)
        end

        -- Step C: Q2 — normalize natural-language date field values to ISO dates.
        write_text = normalize_date_fields(write_text)

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
    -- the separate region/meta scan below.
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
      local task_indent = indent_of(meta.task_text)
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

  -- ── 3. Apply edits per source file ─────────────────────────────────────────

  -- Track per-flush pushes explicitly so the multi-file merge below works
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
  -- this flag is set we issue ONE canonical rerender_buffer at the very end of
  -- flush — the index is already fresh (apply_source_edit ran refresh_file
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
    local ok, result = cmd.apply_source_edit(src_path, 0, {}, {
      batch = file_data.batch,
      dashboard_bufnr = bufnr,
    })

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

  -- ── 3b. Process INSERT rows (Q4 + Q11) ────────────────────────────────────
  --
  -- For each INSERT row (non-meta, non-blank row within a managed region):
  --   1. Walk backward to find the first managed row above it (Q4 anchor).
  --      No anchor above → revert the buffer row + notify (top-of-dashboard).
  --   2. Strip expected wikilink suffix, re-apply anchor indent, Q2 date
  --      normalization (same normalization as the MUTATE path).
  --   3. Call cmd.insert_after_anchor so the new task is written after the
  --      anchor's continuation block in source (Q11).
  --   4. On write failure (e.g. read-only file): revert the buffer row + set
  --      partial_failure so the Q15 notification fires (Q15 isolation — other
  --      files' edits in the same tick are unaffected).
  --   INSERT entries skip the linger check: there is no pre-existing dashboard
  --   position for a just-inserted row (per architect note on ot-q2da).
  --
  -- Phase 5b: a newly-typed line in a `show tree` dashboard is now CLASSIFIED
  -- and PLACED per §6/§7 — a checkbox / bare text → TASK (repaired); a "-"/"*"/"+"
  -- bullet without a checkbox → DESCRIPTION (marker preserved, no checkbox).  The
  -- typed depth is clamped to (anchor_depth + 1); a col-0 description auto-attaches
  -- to the nearest preceding TOP-LEVEL TASK (scan-up past intervening bullets);
  -- a below-top description keeps its literal clamped depth.  This is gated to the
  -- TREE path (anchor carries source_indent/tree_kind/depth) so the FLAT insert
  -- path below stays byte-identical (col-0 bare/checkbox → top-level sibling task).
  --
  -- Phase 5c: insert_rows are GROUPED into contiguous blocks below
  -- (group_insert_blocks) so a multi-line run typed/pasted in ONE InsertLeave is
  -- reconciled as a single structured block via the two-pass model (§7,
  -- render/insert_block.lua): PASS 1 builds the block's literal relative-indent
  -- tree off the block's own left margin, PASS 2 resolves each within-block root
  -- against the dashboard and cascades the reshape to its descendants.  A 1-line
  -- block is the degenerate single-line case and stays byte-identical to P5b.
  local had_successful_insert = false
  -- Phase 5c: group the (ascending-row) insert_rows into CONTIGUOUS blocks so a
  -- multi-line run typed/pasted in ONE InsertLeave reconciles as a single block
  -- (the two-pass model), instead of per-line anchoring that can mis-nest a
  -- pasted subtree.  A 1-line block is the degenerate single-line case and stays
  -- byte-identical to P5b; the FLAT path runs per-line (each line anchors to the
  -- same managed row above the block, matching prior per-line behavior).
  for _, block in ipairs(group_insert_blocks(insert_rows)) do
    local first_row = block[1].row

    -- Q4: collect EVERY managed row above the block (top→anchor order, read-only
    -- BLANK rows excluded).  rows_above[#rows_above] is the immediate anchor.
    local rows_above = collect_rows_above(meta_by_row, first_row)
    local anchor_meta = nil
    local anchor_dashboard_row = nil
    if #rows_above > 0 then
      local last = rows_above[#rows_above]
      anchor_meta = last.meta
      anchor_dashboard_row = last.dash_row
    end

    -- ── Same-tick INSERT + DELETE coordination (P5c handoff / P5d) ─────────────
    -- The anchor meta's source_row is a PRE-delete snapshot.  When this same
    -- flush also deleted rows (delete_rows non-empty), those deletes were already
    -- applied to disk in section 3 above, so the anchor's stored source_row is
    -- STALE — using it would insert at the wrong place (mis-place / corrupt an
    -- unrelated line).  Re-LOCATE the anchor against the now-updated disk by its
    -- verbatim task_text (cmd.locate searches ±10 rows around the stale row, so a
    -- delete-above that shifted the anchor up is recovered).  If the anchor can no
    -- longer be located (it was itself deleted, or drifted out of range), DETECT
    -- the overlap and revert this insert block + warn rather than corrupt source.
    local same_tick_conflict = false
    if anchor_meta and #delete_rows > 0 and anchor_meta.source_file and anchor_meta.source_row ~= nil then
      local relocated = cmd.locate(anchor_meta.source_file, anchor_meta.source_row, anchor_meta.task_text)
      if relocated == nil then
        same_tick_conflict = true
      elseif relocated ~= anchor_meta.source_row then
        -- Adopt the post-delete source_row so insert_after_anchor inserts after
        -- the anchor's CURRENT position.  The trailing canonical re-render rebuilds
        -- meta fresh, so mutating the shared object here is safe.
        anchor_meta.source_row = relocated
      end
    end

    -- A tree dashboard row carries source_indent / tree_kind / depth; flat rows
    -- carry none of these.  The tree INSERT classifier/reconciler only runs when
    -- the anchor is a tree row, so the FLAT insert path stays byte-identical.
    local anchor_is_tree = anchor_meta ~= nil
      and (anchor_meta.source_indent ~= nil or anchor_meta.tree_kind ~= nil or anchor_meta.depth ~= nil)

    if same_tick_conflict then
      -- Anchor vanished in the same-tick delete: revert this insert block + warn.
      log.warn("insert anchor deleted in same edit — insert reverted")
      revert.suppress(bufnr)
      for bi = #block, 1, -1 do
        pcall(vim.api.nvim_buf_set_lines, bufnr, block[bi].row, block[bi].row + 1, false, {})
      end
      revert.unsuppress(bufnr)
    elseif not anchor_meta then
      -- Q4 no-anchor (e.g. a zero-result dashboard): there is no managed task to
      -- attach to.  Rather than LOSE the typed content, keep it as plain NOTE
      -- content right where it was typed — just below the query block's closing
      -- fence, OUTSIDE the rendered region — so it survives and the user can
      -- relocate it.  The dashboard buffer IS the note file, so we keep the buffer
      -- AUTHORITATIVE: rebuild it from its own source (rendered rows stripped),
      -- splice the typed line(s) back at their position, reset the buffer, and
      -- re-render.  A later :w then persists the line (no buffer⇄disk divergence).
      --
      -- Falls back to the original revert+notify when the buffer has no backing
      -- file (a scratch dashboard can't persist note content).
      local note_path = vim.api.nvim_buf_get_name(bufnr)
      if note_path == nil or note_path == "" then
        log.warn("no anchor above insert — insert reverted")
        revert.suppress(bufnr)
        for bi = #block, 1, -1 do
          pcall(vim.api.nvim_buf_set_lines, bufnr, block[bi].row, block[bi].row + 1, false, {})
        end
        revert.unsuppress(bufnr)
      else
        local save = require("obsidian-tasks.render.save")
        local hygiene = require("obsidian-tasks.render.hygiene")

        -- Rows to drop when reconstructing the note source: every rendered
        -- (managed) row PLUS the typed rows themselves (on_lines may have absorbed
        -- them into the adjacent managed region, so strip them explicitly to avoid
        -- duplicating them when we re-splice).
        local exclude = {}
        for _, r in ipairs(save.compute_managed_ranges(bufnr)) do
          for row = r[1], r[2] do
            exclude[row] = true
          end
        end
        for bi = 1, #block do
          exclude[block[bi].row] = true
        end

        -- Split the surviving note lines around the typed block's position so the
        -- typed line(s) land exactly where the user put them (below the fence).
        local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        local before, after, past = {}, {}, false
        for row = 0, #all - 1 do
          if row >= first_row then
            past = true
          end
          if not exclude[row] then
            if past then
              after[#after + 1] = all[row + 1]
            else
              before[#before + 1] = all[row + 1]
            end
          end
        end
        local new_source = {}
        vim.list_extend(new_source, before)
        for bi = 1, #block do
          new_source[#new_source + 1] = block[bi].new_text
        end
        vim.list_extend(new_source, after)

        revert.suppress(bufnr)
        hygiene.with_clean_buffer(bufnr, function()
          managed_mod.clear_buffer(bufnr)
          vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_source)
        end)
        revert.unsuppress(bufnr)
        -- rerender_buffer (not render_buffer): D1 — preserve any user-closed
        -- subtree fold + cursor across this no-anchor reconstruction re-render.
        render_init.rerender_buffer(bufnr, nil)
        -- The typed line is unsaved note content: keep the buffer modified + dirty
        -- so the user is prompted to save and cross-buffer re-renders don't clear it.
        hygiene.mark_dirty(bufnr)
        pcall(function()
          vim.bo[bufnr].modified = true
        end)
        log.warn("no task to anchor to — kept below the dashboard; move it where it belongs")
      end
    elseif anchor_is_tree and #block > 1 then
      -- ── Phase 5c: tree MULTI-LINE block — two-pass reconcile + write ─────────
      --
      -- NIL-GUARD: a tree anchor must carry source_row / source_file to know
      -- WHERE in the file to insert.  If either is nil (an unexpected meta with
      -- no source coords), skip the source write and revert the block so we
      -- never feed nil into source arithmetic (insert_after_anchor).
      local block_lines = {}
      for bi = 1, #block do
        block_lines[bi] = block[bi].new_text
      end

      if anchor_meta.source_row == nil or anchor_meta.source_file == nil then
        log.warn("anchor missing source coords — block insert reverted")
        revert.suppress(bufnr)
        for bi = #block, 1, -1 do
          pcall(vim.api.nvim_buf_set_lines, bufnr, block[bi].row, block[bi].row + 1, false, {})
        end
        revert.unsuppress(bufnr)
      else
        local insert_block = require("obsidian-tasks.render.insert_block")
        local resolved = insert_block.resolve(block_lines, rows_above)

        do
          -- Resolve, for each record, the rows_above index its block-root
          -- ultimately attaches to (nil = a top-level block root), so the
          -- group-attr gate can walk the SAME matched-ancestor chain a single-line
          -- insert would.  Walk block-scope parents up to the root, then read the
          -- root's "above" parent index.
          local function above_parent_index_of(ri)
            local rec = resolved[ri]
            -- Climb within-block parents to the literal root of this record.
            while rec.parent and rec.parent.scope == "block" do
              rec = resolved[rec.parent.index]
            end
            if rec.parent and rec.parent.scope == "above" then
              return rec.parent.index
            end
            return nil -- top-level block root: no above-parent.
          end

          -- Translate each resolved record's depth into a SOURCE indent off its
          -- resolved PARENT's REAL on-disk indent.  Records are processed
          -- top→bottom so a block-scope parent's computed indent is available to
          -- its children (each subtree step is exactly one 2-space level).
          local out_lines = {}
          local rec_indent = {} -- 1-based: computed source indent per record
          for ri, rec in ipairs(resolved) do
            local source_indent
            local parent = rec.parent
            if parent == nil then
              -- Top-level line (depth 0): no indent.
              source_indent = ""
            elseif parent.scope == "above" then
              -- Parent is a managed row: parent real indent + 2-space levels for
              -- the depth steps from the parent.
              local prow = rows_above[parent.index]
              local parent_indent = prow.meta.source_indent or string.rep(" ", indent_of(prow.meta.task_text))
              local steps = rec.depth - (prow.depth or 0)
              if steps < 1 then
                steps = 1
              end
              source_indent = parent_indent .. string.rep("  ", steps)
            else
              -- Parent is an EARLIER line in this same block: exactly one level
              -- deeper than the parent's computed indent (subtree shape preserved).
              source_indent = (rec_indent[parent.index] or "") .. "  "
            end
            rec_indent[ri] = source_indent

            local new_line
            if rec.kind == "description" then
              -- DESCRIPTION → keep the bullet, preserve the typed marker (default
              -- "-"), NEVER force a checkbox; written RAW (no task serialize).
              local marker = rec.marker or "-"
              local body = rec.body or ""
              new_line = source_indent .. marker .. " " .. body
            else
              -- TASK → repair into a well-formed "- [ ] …" task.
              local body = (repair_prefix(rec.body or ""))
              body = normalize_date_fields(body)
              -- Phase 2 GROUP-ATTR INJECTION (block path, mirrors single-line):
              -- inject IFF this record's block-root has NO matched ancestor in its
              -- "above" parent chain (top-level block root, or only DIM
              -- breadcrumbs).  A record dragged beneath a matched task is NOT
              -- injected.
              if not has_matched_ancestor_in_chain(rows_above, above_parent_index_of(ri)) then
                local p9_group_context, p9_task_origin =
                  build_p9_group_context(bufnr, anchor_dashboard_row, anchor_meta)
                local group_attr = require("obsidian-tasks.render.group_attr")
                body = group_attr.inject_group_attributes(body, p9_group_context, p9_task_origin)
              end
              new_line = source_indent .. body
            end
            out_lines[ri] = new_line
          end

          -- Write the WHOLE block as a contiguous ordered insert after the
          -- anchor's existing subtree (single apply_source_edit / one undo entry).
          local src_path = anchor_meta.source_file
          local anchor_indent_n = anchor_meta.source_indent and #anchor_meta.source_indent
            or indent_of(anchor_meta.task_text)
          local ok = cmd.insert_after_anchor(src_path, anchor_meta.source_row, anchor_indent_n, out_lines, {
            dashboard_bufnr = bufnr,
          })
          if not ok then
            partial_failure = true
            revert.suppress(bufnr)
            for bi = #block, 1, -1 do
              pcall(vim.api.nvim_buf_set_lines, bufnr, block[bi].row, block[bi].row + 1, false, {})
            end
            revert.unsuppress(bufnr)
          else
            had_successful_insert = true
            pushes_in_flush = pushes_in_flush + 1
          end
        end
      end
    elseif anchor_is_tree then
      -- ── Phase 5b: tree free-form SINGLE-LINE INSERT — classify + place ───────
      -- A 1-line block: byte-identical to the P5b single-line path.
      local insert_row = first_row
      local new_text = block[1].new_text
      local classify = require("obsidian-tasks.render.insert_classify")
      local resolved = classify.resolve(new_text, rows_above)

      do
        -- NIL-GUARD: a tree anchor must carry source_row / source_file to know
        -- WHERE in the file to insert (anchor_meta.source_row is passed straight
        -- into insert_after_anchor as anchor_row+1 arithmetic).  Guard against a
        -- nil source_row/source_file (skip + revert + warn rather than crash).
        if anchor_meta.source_row == nil or anchor_meta.source_file == nil then
          log.warn("anchor missing source coords — insert reverted")
          revert.suppress(bufnr)
          pcall(vim.api.nvim_buf_set_lines, bufnr, insert_row, insert_row + 1, false, {})
          revert.unsuppress(bufnr)
        else
          -- Translate the resolved DEPTH into a SOURCE indent that makes the new
          -- line a proper child of its resolved PARENT node: parent source indent
          -- + one 2-space level per depth step from the parent.  A top-level line
          -- (depth 0, no parent) gets an empty indent.
          --
          -- The typed indentation (including any editor autoindent inherited from
          -- the anchor via `o`) is INTENTIONAL and load-bearing here: insert_classify
          -- maps it to the resolved depth per the locked "literal below top level"
          -- rule.  It must NOT be stripped — a bullet typed under an INDENTED anchor
          -- stays at its literal (autoindent) depth and is NOT promoted to top-level.
          local parent_row = resolved.parent_index and rows_above[resolved.parent_index] or nil
          local source_indent
          if parent_row then
            local parent_indent = parent_row.meta.source_indent or string.rep(" ", indent_of(parent_row.meta.task_text))
            local parent_depth = parent_row.depth or 0
            local steps = resolved.depth - parent_depth
            if steps < 1 then
              steps = 1
            end
            source_indent = parent_indent .. string.rep("  ", steps)
          else
            source_indent = ""
          end

          -- Build the new line BODY by kind:
          --   • DESCRIPTION → keep the bullet, preserve the typed marker (default
          --     "-"), NEVER force a checkbox; written RAW (no task serialize).
          --   • TASK → repair into a well-formed "- [ ] …" task (existing behavior).
          local new_line
          if resolved.kind == "description" then
            local marker = resolved.marker or "-"
            local body = resolved.body or ""
            new_line = source_indent .. marker .. " " .. body
          else
            local body = (repair_prefix(resolved.body or ""))
            body = normalize_date_fields(body)
            -- Phase 2 GROUP-ATTR INJECTION: inject the group's defining attribute
            -- IFF the new row has NO matched ancestor in its resolved parent chain
            -- (top-level insert, or a chain of only DIM breadcrumbs).  A row
            -- inserted beneath a MATCHED task (or its lit descendants) is already
            -- dragged into the group by subtree-drag, so we do NOT inject.  Same
            -- p9 context extraction + group_attr.inject as the flat path.
            if not has_matched_ancestor_in_chain(rows_above, resolved.parent_index) then
              local p9_group_context, p9_task_origin = build_p9_group_context(bufnr, anchor_dashboard_row, anchor_meta)
              local group_attr = require("obsidian-tasks.render.group_attr")
              body = group_attr.inject_group_attributes(body, p9_group_context, p9_task_origin)
            end
            new_line = source_indent .. body
          end

          -- Insertion position: the IMMEDIATE anchor gives the file + position;
          -- insert_after_anchor walks past the anchor's continuation subtree.  The
          -- anchor may be a BULLET or a TASK (any-kind anchor) — insert_after_anchor
          -- uses only the anchor row + numeric indent, never task-only fields.
          local src_path = anchor_meta.source_file
          local anchor_indent_n = anchor_meta.source_indent and #anchor_meta.source_indent
            or indent_of(anchor_meta.task_text)
          local ok = cmd.insert_after_anchor(src_path, anchor_meta.source_row, anchor_indent_n, new_line, {
            dashboard_bufnr = bufnr,
          })
          if not ok then
            partial_failure = true
            revert.suppress(bufnr)
            pcall(vim.api.nvim_buf_set_lines, bufnr, insert_row, insert_row + 1, false, {})
            revert.unsuppress(bufnr)
          else
            had_successful_insert = true
            pushes_in_flush = pushes_in_flush + 1
          end
        end
      end
    else
      -- ── FLAT insert path — per-line, byte-identical to P5b ───────────────────
      -- Each line of the block anchors to the same managed row above the block;
      -- run the original per-line flat pipeline for every line in order.
      for _, ir in ipairs(block) do
        local insert_row = ir.row
        local new_text = ir.new_text
        local src_path = anchor_meta.source_file
        local anchor_indent = indent_of(anchor_meta.task_text)

        -- Apply same normalization as the MUTATE path.  A freshly inserted row
        -- rarely carries a suffix; strip the anchor's rendered target defensively.
        local write_text = strip_wikilink_suffix(new_text, anchor_meta.wikilink_target)
        -- Strip leading whitespace so repair_prefix sees the bare content.
        local content_after_indent = write_text:match("^%s*(.*)")
        -- Repair structural prefix: if the user typed a bare word, a bulleted
        -- line, or a checkbox-only line, prepend "- ", "[ ] ", or "- [ ] " so
        -- the new line parses as a task on re-render.  Without this, typing
        -- "test" on a dashboard row would write "test" to source as orphan
        -- content (not a task), the line would disappear from the dashboard,
        -- and the source would be left with useless junk.
        content_after_indent = (repair_prefix(content_after_indent))
        -- Re-apply anchor indent so the new task aligns with its anchor (Q11).
        write_text = string.rep(" ", anchor_indent) .. content_after_indent
        -- Q2: normalize natural-language date fields.
        write_text = normalize_date_fields(write_text)

        -- P9: build group context from buffer state so inject_group_attributes
        -- can append the group-defining attribute(s) to the new task line.
        -- Supported group types: tag, priority, status.
        -- File / folder / heading / path / root / backlink: no auto-add (skipped).
        local p9_group_context, p9_task_origin = build_p9_group_context(bufnr, anchor_dashboard_row, anchor_meta)

        -- P9: append group-defining attribute(s) to the new task line so it
        -- inherits the tag/priority/status of the group it was inserted into.
        local group_attr = require("obsidian-tasks.render.group_attr")
        write_text = group_attr.inject_group_attributes(write_text, p9_group_context, p9_task_origin)

        -- Write to source; pass dashboard_bufnr so the undo ring entry is
        -- recorded under the correct buffer key (required for Q13 merge).
        local ok = cmd.insert_after_anchor(src_path, anchor_meta.source_row, anchor_indent, write_text, {
          dashboard_bufnr = bufnr,
        })

        if not ok then
          -- Q15: write failed (e.g. read-only source) → revert INSERT row.
          partial_failure = true
          revert.suppress(bufnr)
          pcall(vim.api.nvim_buf_set_lines, bufnr, insert_row, insert_row + 1, false, {})
          revert.unsuppress(bufnr)
        else
          had_successful_insert = true
          -- insert_after_anchor pushes its own undo-ring entry; count it so
          -- the Q13 merge below combines it with any apply_source_edit pushes.
          pushes_in_flush = pushes_in_flush + 1
        end
      end -- per-line flat loop
    end
  end

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
