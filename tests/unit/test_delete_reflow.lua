-- tests/unit/test_delete_reflow.lua
-- Phase 5d: pure delete-promote-orphans reflow (render/delete_reflow.lua).
--
-- The LOCKED model (show_tree_v1.md §8) verified at the byte level:
--   • Expanded single-line delete of a parent → child promotes up one level.
--   • Multi-level subtree → whole subtree shifts up one level, shape preserved.
--   • Folded delete (parent + all descendants in the delete set) → whole subtree
--     removed, nothing promoted.
--   • Leaf delete → plain literal one-line delete.
--   • Description bullet with its own children → children promote.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local reflow = require("obsidian-tasks.render.delete_reflow")

--- Apply plan() edits to a 1-indexed lines array, bottom-up, returning the
--- resulting file content.  Mirrors apply_source_edit's batch application.
local function apply(lines, edits)
  local out = vim.deepcopy(lines)
  -- edits come sorted descending by row; apply in that order so indices hold.
  for _, e in ipairs(edits) do
    -- remove e.count rows at e.row (0-indexed → row+1 1-indexed)
    for _ = 1, (e.count or 1) do
      table.remove(out, e.row + 1)
    end
    for k = #e.new_lines, 1, -1 do
      table.insert(out, e.row + 1, e.new_lines[k])
    end
  end
  return out
end

-- ── (d) leaf delete → plain literal one-line delete ──────────────────────────

T["leaf delete: single line removed, nothing else moves"] = function()
  local lines = {
    "- [ ] Root task",
    "- [ ] Other task",
  }
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  eq(got, { "- [ ] Other task" })
end

-- ── (a) parent with a surviving child bullet → child promotes one level ──────

T["parent delete: surviving child bullet promotes up one level"] = function()
  local lines = {
    "- [ ] Parent task",
    "  - child bullet",
  }
  -- Only the parent (row 0) is deleted (expanded single-line dd).
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  -- Child shifted up one level (2-space step removed) → top level.
  eq(got, { "- child bullet" })
end

-- ── (b) multi-level subtree → whole subtree shifts up one level uniformly ────

T["parent delete: multi-level subtree shifts up uniformly, shape preserved"] = function()
  local lines = {
    "- [ ] Parent",
    "  - [ ] Child",
    "    - grandchild bullet",
    "  - second child",
  }
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  -- Parent removed; every descendant shifts left by the 2-space step:
  eq(got, {
    "- [ ] Child",
    "  - grandchild bullet",
    "- second child",
  })
end

-- ── (c) folded delete: parent + ALL descendants deleted → no promotion ───────

T["folded delete: parent and all descendants removed, nothing left behind"] = function()
  local lines = {
    "- [ ] Parent",
    "  - [ ] Child",
    "    - grandchild bullet",
    "- [ ] Sibling",
  }
  -- Folded dd deletes the whole subtree: rows 0,1,2 all in the delete set.
  local edits = reflow.plan(lines, { 0, 1, 2 })
  local got = apply(lines, edits)
  eq(got, { "- [ ] Sibling" })
end

-- ── folded delete with an INTERIOR BLANK collapses the blank too ─────────────

T["folded delete: interior blank inside the subtree is removed with the block"] = function()
  local lines = {
    "- [ ] Parent",
    "  - [ ] Child",
    "",
    "  - trailing bullet",
    "- [ ] Sibling",
  }
  -- Folded dd: the managed rows (parent, child, trailing bullet) are all
  -- deleted; the interior blank (row 2) is read-only so it is NOT in the set
  -- but must collapse with the fully-deleted subtree.
  local edits = reflow.plan(lines, { 0, 1, 3 })
  local got = apply(lines, edits)
  eq(got, { "- [ ] Sibling" })
end

-- ── (e) description bullet with its own children → children promote ──────────

T["bullet delete: bullet's own child bullets promote up one level"] = function()
  local lines = {
    "- [ ] Task",
    "  - parent bullet",
    "    - child of bullet",
    "- [ ] Other",
  }
  -- dd on the parent bullet (row 1) only; its child (row 2) survives.
  local edits = reflow.plan(lines, { 1 })
  local got = apply(lines, edits)
  eq(got, {
    "- [ ] Task",
    "  - child of bullet",
    "- [ ] Other",
  })
end

-- ── preserved blank ABOVE a surviving descendant is kept ─────────────────────

T["expanded delete: blank above a surviving descendant is preserved & shifted-neutral"] = function()
  local lines = {
    "- [ ] Parent",
    "  - [ ] Child",
    "",
    "  - trailing bullet",
  }
  -- Only the parent is deleted; child + trailing bullet survive and promote.
  -- The interior blank sits between two survivors → it is kept.
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  eq(got, {
    "- [ ] Child",
    "",
    "- trailing bullet",
  })
end

-- ── sibling subtrees do NOT move (LOCAL normalization) ───────────────────────

T["local normalization: an already-valid sibling subtree is untouched"] = function()
  local lines = {
    "- [ ] A",
    "  - [ ] A-child",
    "- [ ] B",
    "  - [ ] B-child",
  }
  -- Delete A (row 0): A-child promotes; B and B-child must not move at all.
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  eq(got, {
    "- [ ] A-child",
    "- [ ] B",
    "  - [ ] B-child",
  })
end

-- ── nested deletes in one tick: surviving leaf shifts by BOTH removed levels ──

T["two deleted ancestors: surviving grandchild shifts by the sum of removed steps"] = function()
  local lines = {
    "- [ ] Grandparent",
    "  - [ ] Parent",
    "    - surviving bullet",
  }
  -- Both grandparent (0) and parent (1) deleted; the bullet (row 2) survives and
  -- must shift up by BOTH 2-space steps → top level.
  local edits = reflow.plan(lines, { 0, 1 })
  local got = apply(lines, edits)
  eq(got, { "- surviving bullet" })
end

-- ── TAB-indented subtree promotion preserves tabs byte-for-byte ──────────────

T["tab-indented promotion preserves tabs byte-for-byte"] = function()
  local lines = {
    "- [ ] Root",
    "\t- [ ] Child",
    "\t\t- grand",
  }
  -- Delete Root (row 0): Child promotes to top level; grand promotes one level
  -- but stays TAB-indented (a single tab), NOT converted to spaces.
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  eq(got, {
    "- [ ] Child",
    "\t- grand",
  })
end

-- ── mixed / 4-space subtree promotion preserves the 4-space unit ─────────────

T["4-space-indented promotion preserves the 4-space unit byte-for-byte"] = function()
  local lines = {
    "- [ ] Root",
    "    - [ ] Child",
    "        - grand",
  }
  -- Delete Root (row 0): the 4-space step is stripped from the front; Child →
  -- top level, grand → one 4-space step (the trailing indentation bytes are kept).
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  eq(got, {
    "- [ ] Child",
    "    - grand",
  })
end

-- ── MIXED indent: space-parent with a tab-child → column measure, not chars ──
--
-- A space-indented parent (`  ` = 2 chars / 2 cols) with a TAB-indented child
-- (`\t` = 1 char / 4 cols) and a deeper grandchild (`\t\t` = 2 chars / 8 cols).
-- By COLUMN depth (matching index/nodes.lua) the child IS under the parent
-- (col 4 > col 2) at depth 1, and the grandchild is at depth 2.  Deleting the
-- parent must shift the child up exactly ONE level (→ top) and the grandchild
-- up exactly one level (→ a single tab), with surviving indentation bytes kept.
--
-- A RAW-CHARACTER indent measure (tab = 1) gets this WRONG: it reads the child's
-- 1-char indent as SHALLOWER than the parent's 2-char indent, reparents the
-- child to top-level on its own, and then promotes nothing — leaving the child
-- still tab-indented while the re-render (column depth) expects it at top level.
-- This test pins the COLUMN behavior and fails against the char-based code.
T["mixed indent: space parent, tab child — child shifts one level by column depth"] = function()
  local lines = {
    "  - [ ] Parent", -- 2 spaces  → col 2, depth 0
    "\t- child", -- 1 tab     → col 4, depth 1 (under Parent)
    "\t\t- grand", -- 2 tabs    → col 8, depth 2 (under child)
  }
  -- Delete the space-indented parent (row 0) only.
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  -- Child promotes ONE level: the 2-column step to Parent is removed.  Stripping
  -- 2 columns consumes the single leading tab (0→4 cols), landing the child at
  -- top level.  The grandchild likewise drops 2 columns (one leading tab),
  -- leaving exactly one tab — relative shape (one level deeper than child)
  -- preserved, surviving indentation bytes intact (still a TAB, not spaces).
  eq(got, {
    "- child",
    "\t- grand",
  })
end

-- ── blank-line residue: a LEADING blank the delete creates is absorbed ────────

T["coalesced delete absorbs a leading blank it created"] = function()
  -- Root / Child / blank / deeper survivor.  Delete {Root, Child}: the blank
  -- between them becomes a LEADING orphan (no non-blank content above it in the
  -- affected region).  The reflow absorbs that delete-created leading blank so
  -- the file does not start with a stray blank line.
  local lines = {
    "- [ ] Root",
    "\t- [ ] Child",
    "",
    "\t\t- deeper survivor",
  }
  local edits = reflow.plan(lines, { 0, 1 })
  local got = apply(lines, edits)
  -- deeper survivor promotes by both removed steps → top level; no leading blank.
  eq(got, { "- deeper survivor" })
end

-- ── (f) promoted description reaching top level is preserved in source ───────

T["promoted description reaching top level is preserved (orphan, not crash)"] = function()
  local lines = {
    "- [ ] Parent",
    "  - lonely note",
  }
  -- Delete the parent: the description promotes to top level.  In source it
  -- survives (the dashboard re-render decides display); plan must not crash and
  -- must keep the line.
  local edits = reflow.plan(lines, { 0 })
  local got = apply(lines, edits)
  eq(got, { "- lonely note" })
end

return T
