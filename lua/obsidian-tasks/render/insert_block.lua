-- lua/obsidian-tasks/render/insert_block.lua
-- Phase 5c: two-pass MULTI-LINE block insert reconciler for the show-tree
-- dashboard.
--
-- A contiguous run of newly-inserted (non-managed) rows typed or pasted into a
-- `show tree` dashboard in ONE InsertLeave is treated as a SINGLE block.  The
-- block's ANCHOR is the first managed row above it (gives source file +
-- insertion position), exactly as in the single-line path (render/edit.lua /
-- insert_classify.lua).
--
-- Today's single-line path (insert_classify.resolve) anchors EACH typed line to
-- a managed row above it.  For a pasted block that mis-nests: a new line whose
-- intended parent is ANOTHER new line in the same block is instead anchored to a
-- managed row.  This module fixes that with the LOCKED two-pass model
-- (show_tree_v1.md §7):
--
--   PASS 1 — build the block's LITERAL relative-indent tree from the typed
--     RELATIVE indentation WITHIN the block.  Each line is classified by marker
--     (reusing insert_classify.classify_kind): a checkbox / bare text → TASK; a
--     "-"/"*"/"+" bullet without a checkbox → DESCRIPTION (marker preserved).
--     Each line's depth is computed from its indentation relative to the line
--     ABOVE it within the block, with the no-skip CLAMP (a line is at most one
--     level deeper than the line immediately above it within the block).  A
--     col-0-within-block line is a provisional ROOT; a deeper line parents to
--     the nearest shallower line above it in the block.
--
--   PASS 2 — resolve provisional ROOTS against the dashboard.  Each root
--     attaches relative to the anchor like a single-line insert (Phase 2 literal
--     depth: NO col-0 promotion):
--       • a col-0 root (TASK or DESCRIPTION) stays a TRUE TOP-LEVEL item;
--       • a below-top line keeps its literal relative depth, clamped.
--     Reshaping (clamp) of a root CASCADES to its descendants uniformly so the
--     subtree keeps its relative shape.
--
-- The module is PURE: it takes the raw typed block lines plus the same
-- `rows_above` description that insert_classify.resolve consumes, and returns an
-- ORDERED array of resolved records.  The caller (render/edit.lua) translates
-- each resolved record's depth into a source indent relative to its resolved
-- PARENT's real on-disk indent and writes the whole block as a contiguous
-- ordered insert after the anchor's existing subtree.
--
-- INVARIANT: a 1-line block is the degenerate case and produces a record set
-- byte-identical in effect to insert_classify.resolve (single-line P5b output).

local classify = require("obsidian-tasks.render.insert_classify")

local M = {}

--- Walk up the within-block parent chain from line *i* to its literal ROOT and
--- return that root's cascade shift (set during PASS 2 root resolution).
--- @param lits table[]
--- @param i    integer
--- @return integer
local function root_shift_of(lits, i)
  local j = i
  while lits[j].block_parent ~= nil do
    j = lits[j].block_parent
  end
  return lits[j].shift or 0
end

--- Resolve a contiguous block of typed lines into ordered placement records.
---
--- *block_lines* is an array of raw typed dashboard lines (top→bottom order),
--- representing one contiguous run of newly-inserted rows.
---
--- *rows_above* is the same array insert_classify.resolve consumes: the managed
--- rows strictly above the block (top-of-buffer → anchor order), each
---   { depth = <integer>, kind = "task"|"description" }
--- with rows_above[#rows_above] == the immediate anchor.  Read-only BLANK rows
--- must be EXCLUDED by the caller.
---
--- Returns an ORDERED array (same order as block_lines) of records:
---   { kind = "task"|"description",
---     marker = <bullet marker or nil>,
---     body = <content after the marker, or the whole task body>,
---     depth = <final resolved depth — the visual level the line lands at>,
---     parent = { scope = "above", index = <1-based index into rows_above> }
---              | { scope = "block", index = <1-based index into the returned
---                    records of the PARENT line within this block> }
---              | nil  (top-level: depth 0, no parent) }
---
--- @param block_lines string[]   raw typed lines, top→bottom
--- @param rows_above   table[]    { {depth, kind}, … } in top→anchor order
--- @return table[]                ordered resolved records
function M.resolve(block_lines, rows_above)
  local n = #block_lines

  -- Degenerate case: a 1-line block must match single-line P5b output exactly.
  -- Delegate to insert_classify.resolve and adapt the record shape (its
  -- parent_index always indexes rows_above).
  if n == 1 then
    local r = classify.resolve(block_lines[1], rows_above)
    local parent = nil
    if r.parent_index ~= nil then
      parent = { scope = "above", index = r.parent_index }
    end
    return {
      {
        kind = r.kind,
        marker = r.marker,
        body = r.body,
        depth = r.depth,
        parent = parent,
      },
    }
  end

  -- ── PASS 1: literal relative-indent tree within the block ──────────────────
  --
  -- Compute each line's kind/body/marker and its LITERAL within-block depth.
  -- Depth is RELATIVE to the block's own left margin: the SHALLOWEST typed line
  -- in the block defines within-block depth 0 (so a uniformly-indented paste — a
  -- subtree whose lines all carry a leading indent — still roots at relative 0).
  -- Each subsequent line is clamped to at most one level deeper than the line
  -- immediately above it within the block (no level-skipping).  A line at
  -- within-block depth 0 is a provisional ROOT; a deeper line parents to the
  -- nearest shallower line above it in the block.
  local lits = {} -- per-line: { kind, marker, body, typed, litdepth, block_parent }
  local base = math.huge
  for i = 1, n do
    local line = block_lines[i]
    local kind, marker, body = classify.classify_kind(line)
    local typed = classify.typed_depth(line)
    lits[i] = { kind = kind, marker = marker, body = body, typed = typed }
    if typed < base then
      base = typed
    end
  end
  if base == math.huge then
    base = 0
  end

  -- First line: its within-block depth is its typed indent relative to the base
  -- (>= 0).  It is the first line, so there is nothing above it to clamp against.
  --
  -- EDGE: a ROOT may carry litdepth > 0.  When a LATER line lowers the base (e.g.
  -- a 2-space line, then a 0-space line), line 1 has a positive base-relative depth
  -- yet has NO shallower predecessor, so block_parent stays nil — it is a root with
  -- litdepth > 0.  PASS 2 resolves it at that litdepth (a below-top literal root),
  -- and its cascade shift carries any descendants uniformly; the 'root at relative
  -- 0' invariant only holds for the SHALLOWEST line, not necessarily the first.
  lits[1].litdepth = math.max(0, lits[1].typed - base)
  lits[1].block_parent = nil
  for i = 2, n do
    local prev = lits[i - 1]
    -- Relative typed depth (off the block's left margin), clamped to at most one
    -- level deeper than the line immediately above it within the block; floored 0.
    local rel = math.max(0, lits[i].typed - base)
    local d = math.min(rel, prev.litdepth + 1)
    if d < 0 then
      d = 0
    end
    lits[i].litdepth = d
    -- Parent within the block = nearest shallower line above.  A within-block
    -- root (d == 0) has no block parent.
    if d == 0 then
      lits[i].block_parent = nil
    else
      local bp = nil
      for j = i - 1, 1, -1 do
        if lits[j].litdepth < d then
          bp = j
          break
        end
      end
      lits[i].block_parent = bp
    end
  end

  -- ── PASS 2: resolve provisional ROOTS against the dashboard ────────────────
  --
  -- A literal root (block_parent == nil) attaches relative to the anchor like a
  -- single-line insert.  Resolve via insert_classify.resolve so the single-line
  -- rules (col-0 → top-level for BOTH kinds / below-top keeps literal depth /
  -- clamp) are reused VERBATIM — the single source of truth.  The root's FINAL
  -- depth may differ from its literal depth (a below-top clamp): the difference
  -- is a SHIFT that must CASCADE uniformly to the whole sub-block so the subtree
  -- keeps its relative shape.
  local records = {}
  for i = 1, n do
    records[i] = {
      kind = lits[i].kind,
      marker = lits[i].marker,
      body = lits[i].body,
    }
  end

  for i = 1, n do
    local lit = lits[i]
    if lit.block_parent == nil then
      -- ROOT: resolve against the dashboard EXACTLY like a single-line insert,
      -- reading the root's RAW typed line so its depth is ANCHOR-RELATIVE — its
      -- literal typed indentation mapped to a level and clamped to anchor_depth+1.
      --
      -- This keeps a multi-line block EQUIVALENT to typing each line as a separate
      -- single-line insert (insert_classify.resolve).  Critically, that is what the
      -- user gets from `o`: pressing `o` under a task autoindents to the task's
      -- column, one extra indent makes the new line a CHILD of that task, and a
      -- deeper next line makes the grandchild — so the first child must attach
      -- UNDER the anchor, not be re-rooted to top-level.
      --
      -- (Earlier this base-stripped the block — re-synthesizing the shallowest line
      -- at col-0 — on a "paste lands at the cursor column" assumption.  But vim
      -- yank/paste keeps each line's verbatim indentation, and an `o`-typed block's
      -- indent IS meaningful relative to the anchor; base-stripping forced the first
      -- child to top-level whenever it had its own child, mis-nesting the subtree.)
      --
      -- A col-0 raw line still resolves to depth 0 (true top-level, both kinds — no
      -- promotion), so an explicitly outdented root keeps that meaning.
      local r = classify.resolve(block_lines[i], rows_above)

      records[i].depth = r.depth
      if r.parent_index ~= nil then
        records[i].parent = { scope = "above", index = r.parent_index }
      else
        records[i].parent = nil
      end
      -- Cascade shift for this root's descendants: the root's FINAL resolved depth
      -- minus its within-block literal depth.  Descendants are reshaped uniformly
      -- by this shift so the subtree keeps its relative structure.
      lit.shift = r.depth - lit.litdepth
    else
      -- NON-ROOT: keep literal relative depth, shifted by the ROOT's cascade
      -- shift (descendants move uniformly with their reshaped root so the
      -- subtree keeps its shape).  Parent is the within-block parent line.
      local root_shift = root_shift_of(lits, i)
      records[i].depth = lit.litdepth + root_shift
      records[i].parent = { scope = "block", index = lit.block_parent }
    end
  end

  return records
end

return M
