-- lua/obsidian-tasks/render/delete_reflow.lua
-- Phase 5d: delete-promote-orphans reflow for `show tree` dashboards.
--
-- The LOCKED deletion model (show_tree_v1.md §8):
--   • Deletion is LITERAL for the removed line(s).
--   • Any SURVIVING orphaned children are PROMOTED one level via the SAME
--     no-skip structure normalization, written to source in the same edit.
--   • Normalization stays LOCAL: only a deleted line's former descendants are
--     re-resolved; already-valid sibling subtrees do not move.
--   • FOLDED-subtree delete (a closed fold's dd) removes the WHOLE subtree —
--     every descendant row is itself in the delete set, so there are NO
--     survivors and NO promotion happens.
--   • EXPANDED single-line delete removes only that line; its direct children
--     (and their subtrees) shift UP one level — the step between the deleted
--     line and its first child — to take its place, preserving relative shape.
--
-- This module is a PURE function over the source-file lines + the set of
-- explicitly-deleted source rows.  It returns a list of bottom-up apply edits
-- (delete + in-place indent-shift replacements) so the flush layer can hand the
-- whole reflow to cmd.apply_source_edit as ONE batch / ONE undo entry.

local M = {}

--- Expand a leading-whitespace string to its COLUMN width, advancing each tab to
--- the next multiple of 4 columns.  This MUST match index/nodes.lua's
--- `indent_width` EXACTLY: the post-delete re-render re-derives every node's
--- depth from the same column measure, so parent resolution here has to agree
--- with it or a mixed-indent (space-parent / tab-child) document would resolve a
--- different parent and over- or under-strip on promotion.
--- @param ws string  leading whitespace
--- @return integer  column width
local function indent_width(ws)
  local width = 0
  for i = 1, #ws do
    if ws:sub(i, i) == "\t" then
      width = width + (4 - (width % 4))
    else
      width = width + 1
    end
  end
  return width
end

--- COLUMN width of *line*'s leading whitespace (tabs expanded to 4-col stops),
--- matching index/nodes.lua so depth/parent comparisons agree with the
--- post-delete re-render.  (Was a raw char count in earlier P5d; raw chars
--- disagree with nodes.lua on mixed tab/space indentation.)
--- @param line string|nil
--- @return integer
local function indent_of(line)
  if not line then
    return 0
  end
  local s = line:match("^(%s*)")
  return s and indent_width(s) or 0
end

--- Strip the leading whitespace CHARACTERS of *line* that together span at least
--- *cols* columns (tabs expanded to 4-col stops, identically to indent_of), and
--- return the remaining line.  The promotion shift is computed in the COLUMN
--- measure (to match nodes.lua), but the actual edit removes whole leading
--- whitespace BYTES — so the surviving trailing indentation stays byte-for-byte
--- (a tab stays a tab, spaces stay spaces).  We never strip past the line's own
--- leading whitespace.
--- @param line string
--- @param cols integer  columns to remove from the front
--- @return string  line with `cols` columns of leading whitespace consumed
local function strip_leading_columns(line, cols)
  if cols <= 0 then
    return line
  end
  local removed = 0
  local i = 1
  local len = #line
  while i <= len and removed < cols do
    local ch = line:sub(i, i)
    if ch == "\t" then
      removed = removed + (4 - (removed % 4))
    elseif ch == " " then
      removed = removed + 1
    else
      break -- end of leading whitespace
    end
    i = i + 1
  end
  return line:sub(i)
end

--- @param line string|nil
--- @return boolean
local function is_blank(line)
  return line == nil or line:match("^%s*$") ~= nil
end

--- Find the contiguous descendant block of the line at 0-indexed *row* in
--- *lines* (1-indexed array).  A descendant is a following non-blank line
--- indented deeper than *row*'s indent; an interior blank line is part of the
--- block iff some later line (before any shallower non-blank) is still deeper.
---
--- Mirrors the continuation walk in cmd.delete_block / insert_after_anchor so
--- the descendant set agrees with the existing block-aware delete.
---
--- @param lines     string[]  1-indexed source lines
--- @param row       integer   0-indexed row whose subtree to scan
--- @param row_indent integer  leading-ws width of `row`
--- @return integer  0-indexed last row of the contiguous descendant block
---                  (== row when there are no descendants)
local function descendant_end(lines, row, row_indent)
  local n = #lines
  local end_row = row
  local i = row + 1
  while i < n do
    local line = lines[i + 1] -- 1-indexed access
    if is_blank(line) then
      local next_i = i + 1
      while next_i < n and is_blank(lines[next_i + 1]) do
        next_i = next_i + 1
      end
      if next_i >= n or indent_of(lines[next_i + 1]) <= row_indent then
        break
      end
      end_row = i
      i = i + 1
    elseif indent_of(line) <= row_indent then
      break
    else
      end_row = i
      i = i + 1
    end
  end
  return end_row
end

--- Compute the delete-promote reflow for *lines* given the explicitly-deleted
--- source rows *deleted_rows* (0-indexed managed-row deletes — tasks + bullets,
--- never blanks).
---
--- Returns a list of edits in the apply_source_edit single-edit shape, sorted
--- DESCENDING by row so a caller may apply them bottom-up (or hand them to
--- apply_source_edit's batch path, which sorts internally):
---   { row = <0-indexed>, count = <rows-removed>, new_lines = { ... } }
--- A pure delete has new_lines = {}.  A promotion is a 1-for-1 replacement
--- (count = 1) whose new_lines[1] is the same line with its indent reduced.
---
--- @param lines        string[]  1-indexed source lines (verbatim, e.g. readfile)
--- @param deleted_rows integer[] 0-indexed source rows to delete
--- @return table[]  edits sorted descending by row
function M.plan(lines, deleted_rows)
  local n = #lines

  -- del[row] = true for every explicitly-deleted source row (0-indexed).
  local del = {}
  for _, r in ipairs(deleted_rows) do
    del[r] = true
  end

  -- ── Build the parent chain via an indent stack (0-indexed rows) ─────────────
  -- For every NON-BLANK line, resolve its parent (nearest shallower line above)
  -- and the indent STEP from that parent (this line's indent − parent indent).
  -- These let us, for any surviving line, walk up its ancestors and subtract the
  -- step of each DELETED ancestor — uniformly shifting an orphaned subtree up by
  -- exactly the levels that were removed (LOCAL normalization).
  local parent = {} -- row → parent row (0-indexed) | nil
  local step_from_parent = {} -- row → integer indent delta to its parent
  local indent_at = {} -- row → leading-ws width
  do
    local stack = {} -- { row=0-indexed, indent=int }
    for i = 1, n do
      local line = lines[i]
      local row = i - 1
      if not is_blank(line) then
        local ind = indent_of(line)
        indent_at[row] = ind
        while #stack > 0 and stack[#stack].indent >= ind do
          stack[#stack] = nil
        end
        if #stack > 0 then
          local p = stack[#stack]
          parent[row] = p.row
          step_from_parent[row] = ind - p.indent
        else
          parent[row] = nil
          step_from_parent[row] = 0
        end
        stack[#stack + 1] = { row = row, indent = ind }
      end
    end
  end

  -- ── Decide which rows are physically DELETED vs PROMOTED ───────────────────
  -- A FOLDED delete arrives as the whole subtree's managed rows in `del`; the
  -- interior blank rows of such a subtree are NOT managed-deletable (they are
  -- read-only) so they are absent from `del` and must be deleted here as part of
  -- the collapsed block.  An EXPANDED single delete has only the parent in `del`
  -- — its descendants survive and are promoted.
  --
  -- to_delete[row] = true:   physically remove this source row.
  -- to_shift[row]  = delta:  reduce this surviving row's indent by `delta`.
  local to_delete = {}
  for r in pairs(del) do
    to_delete[r] = true
  end

  -- For each explicitly-deleted row, scan its descendant block.  Interior blank
  -- rows whose enclosing subtree is FULLY deleted (no surviving non-blank
  -- descendant after them within the block) collapse with the block.  Surviving
  -- non-blank descendants are promoted via the ancestor-step subtraction below.
  for _, root in ipairs(deleted_rows) do
    local root_indent = indent_of(lines[root + 1])
    local block_end = descendant_end(lines, root, root_indent)
    -- Walk the block bottom-up so a trailing run of blanks/deleted lines (with
    -- no surviving non-blank below) is absorbed into the delete; once we cross a
    -- surviving non-blank line, blanks above it must be kept (they belong to the
    -- surviving, promoted subtree).
    local seen_survivor_below = false
    for d = block_end, root + 1, -1 do
      local line = lines[d + 1]
      if is_blank(line) then
        if not seen_survivor_below then
          to_delete[d] = true
        end
      elseif del[d] then
        -- Explicitly deleted descendant (folded child): removed by its own
        -- entry; does not count as a survivor that would preserve blanks above.
        to_delete[d] = true
      else
        -- Surviving descendant: it (and the blanks above it within the block)
        -- stay.  Promotion is computed by the ancestor walk below.
        seen_survivor_below = true
      end
    end
  end

  -- Compute the promotion shift for every SURVIVING non-blank line: subtract the
  -- step of each DELETED ancestor.  Lines with no deleted ancestor get shift 0
  -- (untouched).  This walks up the parent chain (LOCAL: only descendants of a
  -- deleted line accumulate a shift; valid sibling subtrees never move).
  local to_shift = {}
  for row = 0, n - 1 do
    if indent_at[row] ~= nil and not to_delete[row] then
      local shift = 0
      local p = parent[row]
      local cur = row
      while p ~= nil do
        if to_delete[p] then
          shift = shift + (step_from_parent[cur] or 0)
        end
        cur = p
        p = parent[p]
      end
      if shift > 0 then
        to_shift[row] = shift
      end
    end
  end

  -- ── Absorb blank cruft this reflow created (LOCAL, conservative) ───────────
  -- A coalesced delete can strand a blank that, as a DIRECT result of the
  -- reflow, becomes a LEADING orphan (no surviving non-blank content anywhere
  -- above it) or a TRAILING blank left only because the content it separated was
  -- deleted (no surviving non-blank content anywhere below it).  We absorb only
  -- such blanks, and only when they were KEPT (not already in to_delete) and at
  -- least one non-blank row above-or-below them is deleted — i.e. blanks the
  -- delete itself orphaned.  Blanks bracketed by surviving non-blank content on
  -- BOTH sides are untouched (they belong to the surviving structure).
  do
    -- Precompute, for every row, whether a SURVIVING non-blank row exists above
    -- it and below it (after this delete), and whether a DELETED non-blank row
    -- exists above/below it.  A blank is an orphan the delete CREATED iff one
    -- side has no surviving non-blank AND that same side has a deleted non-blank
    -- (so the delete is what stripped its neighbour).  This refuses to absorb a
    -- pre-existing leading/trailing blank that the delete never touched.
    local survivor_above, deleted_above = {}, {}
    do
      local surv, del_nb = false, false
      for row = 0, n - 1 do
        survivor_above[row] = surv
        deleted_above[row] = del_nb
        if not is_blank(lines[row + 1]) then
          if to_delete[row] then
            del_nb = true
          else
            surv = true
          end
        end
      end
    end
    local survivor_below, deleted_below = {}, {}
    do
      local surv, del_nb = false, false
      for row = n - 1, 0, -1 do
        survivor_below[row] = surv
        deleted_below[row] = del_nb
        if not is_blank(lines[row + 1]) then
          if to_delete[row] then
            del_nb = true
          else
            surv = true
          end
        end
      end
    end
    for row = 0, n - 1 do
      if is_blank(lines[row + 1]) and not to_delete[row] then
        local leading_orphan = not survivor_above[row] and deleted_above[row]
        local trailing_orphan = not survivor_below[row] and deleted_below[row]
        if leading_orphan or trailing_orphan then
          to_delete[row] = true
        end
      end
    end
  end

  -- ── Emit edits ─────────────────────────────────────────────────────────────
  -- Coalesce contiguous deleted rows into one count>1 delete so apply_source_edit
  -- does the minimum number of splices.  Promotions are 1-for-1 replacements.
  local edits = {}

  -- Promotions first (in-place replacements; row identity is preserved).
  --
  -- A promoted line's leftward shift equals the sum of the COLUMN steps
  -- contributed by its DELETED ancestors (steps measured in the same tab-aware
  -- column unit as index/nodes.lua, so this promotion lands the line at the
  -- depth the post-delete re-render expects).  To preserve round-trip
  -- faithfulness we do NOT rebuild the indent from a numeric width as spaces —
  -- that would silently convert a TAB-indented subtree to spaces.  Instead we
  -- consume whole leading whitespace CHARACTERS — the actual tab/space bytes
  -- that were there — from the FRONT of the line until `shift` COLUMNS have been
  -- removed (each tab advances to the next 4-col stop, each space = 1 col),
  -- leaving the surviving trailing indentation byte-for-byte intact.  Column
  -- accounting drives WHICH ancestor steps to drop; byte stripping drives WHAT
  -- gets removed — the two stay reconciled because strip_leading_columns expands
  -- tabs the same way indent_of/step_from_parent do.
  --
  -- NOTE (by design): delete is a LOCAL indent shift only (show_tree_v1.md §8) —
  -- a description promoted to top level is NOT auto-attached under the nearest
  -- top-level task.  Auto-attach is the INSERT rule (§7), not the delete rule.
  for row, shift in pairs(to_shift) do
    local line = lines[row + 1]
    local new_lines = { strip_leading_columns(line, shift) }
    edits[#edits + 1] = {
      row = row,
      count = 1,
      new_lines = new_lines,
    }
  end

  -- Coalesce deletions into contiguous runs (ascending), emitted as count>1
  -- deletes.  A run is broken by any non-deleted row.
  local dels_sorted = {}
  for row in pairs(to_delete) do
    dels_sorted[#dels_sorted + 1] = row
  end
  table.sort(dels_sorted)
  local i = 1
  while i <= #dels_sorted do
    local start = dels_sorted[i]
    local last = start
    while i + 1 <= #dels_sorted and dels_sorted[i + 1] == last + 1 do
      i = i + 1
      last = dels_sorted[i]
    end
    edits[#edits + 1] = { row = start, count = last - start + 1, new_lines = {} }
    i = i + 1
  end

  -- Sort all edits DESCENDING by row (bottom-up apply order).
  table.sort(edits, function(a, b)
    return a.row > b.row
  end)

  return edits
end

-- Expose internals for unit testing.
M._indent_of = indent_of
M._indent_width = indent_width
M._strip_leading_columns = strip_leading_columns
M._descendant_end = descendant_end

return M
