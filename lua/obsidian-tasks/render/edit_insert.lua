-- lua/obsidian-tasks/render/edit_insert.lua
-- INSERT classification + block reconciliation phase of the dashboard flush
-- pipeline (Q4 + Q11, Phases 5b/5c, P9 group-attr injection).  Extracted
-- mechanically from render/edit.lua's flush(); edit.lua remains the
-- orchestrator and calls process_inserts after the per-file batch writes.

local edit_util = require("obsidian-tasks.render.edit_util")

local M = {}

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

--- Process INSERT rows (Q4 + Q11) for one flush tick.
---
--- For each INSERT row (non-meta, non-blank row within a managed region):
---   1. Walk backward to find the first managed row above it (Q4 anchor).
---      No anchor above → revert the buffer row + notify (top-of-dashboard).
---   2. Strip expected wikilink suffix, re-apply anchor indent, Q2 date
---      normalization (same normalization as the MUTATE path).
---   3. Call cmd.insert_after_anchor so the new task is written after the
---      anchor's continuation block in source (Q11).
---   4. On write failure (e.g. read-only file): revert the buffer row + set
---      partial_failure so the Q15 notification fires (Q15 isolation — other
---      files' edits in the same tick are unaffected).
---   INSERT entries skip the linger check: there is no pre-existing dashboard
---   position for a just-inserted row (per architect note on ot-q2da).
---
--- Phase 5b: a newly-typed line in a `show tree` dashboard is now CLASSIFIED
--- and PLACED per §6/§7 — a checkbox / bare text → TASK (repaired); a "-"/"*"/"+"
--- bullet without a checkbox → DESCRIPTION (marker preserved, no checkbox).  The
--- typed depth is clamped to (anchor_depth + 1); a col-0 description auto-attaches
--- to the nearest preceding TOP-LEVEL TASK (scan-up past intervening bullets);
--- a below-top description keeps its literal clamped depth.  This is gated to the
--- TREE path (anchor carries source_indent/tree_kind/depth) so the FLAT insert
--- path stays byte-identical (col-0 bare/checkbox → top-level sibling task).
---
--- Phase 5c: insert_rows are GROUPED into contiguous blocks
--- (group_insert_blocks) so a multi-line run typed/pasted in ONE InsertLeave is
--- reconciled as a single structured block via the two-pass model (§7,
--- render/insert_block.lua): PASS 1 builds the block's literal relative-indent
--- tree off the block's own left margin, PASS 2 resolves each within-block root
--- against the dashboard and cascades the reshape to its descendants.  A 1-line
--- block is the degenerate single-line case and stays byte-identical to P5b.
---
--- @param bufnr       integer  dashboard buffer
--- @param insert_rows table[]  { {row, new_text}, … } ascending by row
--- @param delete_rows table[]  { {row, meta}, … } same-tick deletes (overlap check)
--- @param meta_by_row table    row→meta snapshot (revert.meta_snapshot)
--- @return table  { had_successful_insert, pushes_in_flush, partial_failure }
function M.process_inserts(bufnr, insert_rows, delete_rows, meta_by_row)
  local revert = require("obsidian-tasks.render.revert")
  local managed_mod = require("obsidian-tasks.render.managed")
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local render_init = require("obsidian-tasks.render.init")

  local indent_of = edit_util.indent_of
  local repair_prefix = edit_util.repair_prefix
  local normalize_date_fields = edit_util.normalize_date_fields
  local strip_wikilink_suffix = edit_util.strip_wikilink_suffix

  local had_successful_insert = false
  local partial_failure = false
  local pushes_in_flush = 0

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
    -- applied to disk by apply_batches, so the anchor's stored source_row is
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

        revert.with_suppressed(bufnr, function()
          hygiene.with_clean_buffer(bufnr, function()
            managed_mod.clear_buffer(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_source)
          end)
        end)
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
          -- the Q13 merge in flush() combines it with any apply_source_edit pushes.
          pushes_in_flush = pushes_in_flush + 1
        end
      end -- per-line flat loop
    end
  end

  return {
    had_successful_insert = had_successful_insert,
    pushes_in_flush = pushes_in_flush,
    partial_failure = partial_failure,
  }
end

return M
