-- tests/unit/test_insert_block.lua
-- Phase 5c: pure two-pass MULTI-LINE block insert reconciler.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local block = require("obsidian-tasks.render.insert_block")

-- ── degenerate 1-line block matches single-line P5b ──────────────────────────

T["1-line block: col-0 task → top-level (matches single-line)"] = function()
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({ "new task" }, rows)
  eq(#recs, 1)
  eq(recs[1].kind, "task")
  eq(recs[1].depth, 0)
  eq(recs[1].parent, nil)
end

T["1-line block: col-0 description → top-level (Phase 2: no promotion)"] = function()
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({ "- note" }, rows)
  eq(#recs, 1)
  eq(recs[1].kind, "description")
  -- Phase 2 literal depth: a col-0 description is a true top-level item.
  eq(recs[1].depth, 0)
  eq(recs[1].parent, nil)
end

-- ── clean nested paste under a top-level task ────────────────────────────────

T["clean nested block: root + child + grandchild keep relative shape"] = function()
  -- Block typed/pasted under a top-level task:
  --   - [ ] root        (litdepth 0, col-0 task → top-level)
  --     - [ ] child      (litdepth 1, block child)
  --       - grandchild   (litdepth 2, block child)
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "- [ ] root",
    "  - [ ] child",
    "    - grandchild",
  }, rows)
  eq(#recs, 3)
  -- root: col-0 task → top-level.
  eq(recs[1].kind, "task")
  eq(recs[1].depth, 0)
  eq(recs[1].parent, nil)
  -- child: block-scope parent = root (record 1).
  eq(recs[2].kind, "task")
  eq(recs[2].depth, 1)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
  -- grandchild: description, block-scope parent = child (record 2).
  eq(recs[3].kind, "description")
  eq(recs[3].depth, 2)
  eq(recs[3].parent.scope, "block")
  eq(recs[3].parent.index, 2)
end

-- ── indented block root resolves ANCHOR-RELATIVE (like a single-line insert) ──

T["indented block root resolves anchor-relative (raw typed depth, not base-stripped)"] = function()
  -- A block whose shallowest line carries a leading indent resolves that root by
  -- its RAW typed depth relative to the anchor — EXACTLY as the same line typed as
  -- a single-line insert would (insert_classify.resolve).  This is the `o` case:
  -- `o` under a top-level task autoindents to col 0, one extra indent → the first
  -- line is a CHILD of the anchor (depth 1), and a deeper next line its grandchild.
  -- The whole subtree keeps its relative shape, shifted to sit under the anchor.
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "  - [ ] child",
    "    - [ ] grandchild",
    "      - note",
  }, rows)
  eq(#recs, 3)
  -- child: typed depth 1 under a depth-0 anchor → child of the anchor (depth 1).
  eq(recs[1].kind, "task")
  eq(recs[1].depth, 1, "indented root attaches UNDER the anchor, not re-rooted to top-level")
  eq(recs[1].parent.scope, "above")
  eq(recs[1].parent.index, 1)
  -- grandchild: one level deeper than the root.
  eq(recs[2].kind, "task")
  eq(recs[2].depth, 2)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
  -- note: two levels deeper than the root.
  eq(recs[3].kind, "description")
  eq(recs[3].depth, 3)
  eq(recs[3].parent.scope, "block")
  eq(recs[3].parent.index, 2)
end

T["indented description root resolves anchor-relative (clamped), sub-block rides along"] = function()
  -- A block whose root is an indented DESCRIPTION resolves anchor-relative: typed
  -- depth 2 under a depth-0 anchor clamps to anchor+1 = depth 1 (a child of the
  -- anchor), and its sub-block keeps its relative shape one level deeper.  A col-0
  -- root would instead stay top-level (covered elsewhere) — depth is literal.
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "    - note",
    "      - subnote",
  }, rows)
  eq(#recs, 2)
  eq(recs[1].kind, "description")
  eq(recs[1].depth, 1, "indented description root clamps to a child of the anchor")
  eq(recs[1].parent.scope, "above")
  eq(recs[1].parent.index, 1)
  eq(recs[2].depth, 2)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
end

-- ── first-line litdepth > 0 when a LATER line lowers the base (MINOR-1) ───────

T["root may carry litdepth > 0 when a later line lowers the base"] = function()
  -- base is set by the LAST line (col 0), so line 1 (2-space) has litdepth 1 yet
  -- is a ROOT (no shallower predecessor).  It must resolve at its below-top
  -- literal depth, and the col-0 last line starts a fresh root.
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "  - [ ] mid",
    "    - [ ] deep",
    "- [ ] top",
  }, rows)
  eq(#recs, 3)
  -- line 1: litdepth 1 root → resolves at depth 1 (below-top literal), under anchor.
  eq(recs[1].kind, "task")
  eq(recs[1].depth, 1)
  eq(recs[1].parent.scope, "above")
  eq(recs[1].parent.index, 1)
  -- line 2: block child of line 1, depth 2.
  eq(recs[2].depth, 2)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
  -- line 3: col-0 within block → fresh top-level task root.
  eq(recs[3].kind, "task")
  eq(recs[3].depth, 0)
  eq(recs[3].parent, nil)
end

-- ── col-0 description root promotes carrying its sub-block ────────────────────

T["description root → top-level, sub-block keeps relative shape (no promotion)"] = function()
  -- Block under a top-level task:
  --   - note          (litdepth 0 description → top-level depth 0)
  --     - subnote     (litdepth 1 → depth 1, block child of root)
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "- note",
    "  - subnote",
  }, rows)
  eq(#recs, 2)
  -- root description is top-level: depth 0, no parent (Phase 2: no promotion).
  eq(recs[1].kind, "description")
  eq(recs[1].depth, 0)
  eq(recs[1].parent, nil)
  -- sub-block child rides along: depth 1, block parent = root.
  eq(recs[2].kind, "description")
  eq(recs[2].depth, 1)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
end

-- ── mixed block: task root stays top-level, description root promotes ─────────

T["mixed block: task root top-level + later description root also top-level"] = function()
  -- Block under a top-level task:
  --   - [ ] task root     (litdepth 0 task → top-level depth 0)
  --   - desc root         (litdepth 0 description → top-level depth 0)
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "- [ ] task root",
    "- desc root",
  }, rows)
  eq(#recs, 2)
  eq(recs[1].kind, "task")
  eq(recs[1].depth, 0)
  eq(recs[1].parent, nil)
  -- Phase 2: the second col-0 description is ALSO a true top-level item — no
  -- promotion under the anchor.
  eq(recs[2].kind, "description")
  eq(recs[2].depth, 0)
  eq(recs[2].parent, nil)
end

-- ── outdent back to col-0 mid-block re-attaches to the right ancestor ─────────

T["outdent back to col-0 mid-block starts a new root"] = function()
  -- Block under a top-level task:
  --   - [ ] a          (litdepth 0 task root → top-level)
  --     - [ ] b        (litdepth 1 block child of a)
  --   - [ ] c          (outdent to col-0 → NEW task root, top-level)
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "- [ ] a",
    "  - [ ] b",
    "- [ ] c",
  }, rows)
  eq(#recs, 3)
  eq(recs[1].depth, 0)
  eq(recs[1].parent, nil)
  eq(recs[2].depth, 1)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
  -- c outdented back to col-0: a fresh top-level task root, NOT a child of b.
  eq(recs[3].kind, "task")
  eq(recs[3].depth, 0)
  eq(recs[3].parent, nil)
end

-- ── level-skip within the block clamps ───────────────────────────────────────

T["level-skip within the block clamps to parent + 1"] = function()
  -- Block under a top-level task:
  --   - [ ] root       (litdepth 0)
  --         - [ ] deep (typed depth 3 → clamps to within-block depth 1)
  local rows = { { depth = 0, kind = "task" } }
  local recs = block.resolve({
    "- [ ] root",
    "      - [ ] deep",
  }, rows)
  eq(#recs, 2)
  eq(recs[1].depth, 0)
  eq(recs[2].depth, 1, "typed depth 3 clamps to root + 1 within the block")
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
end

-- ── below-top anchor: roots resolve anchor-relative by raw typed depth ────────

T["block under a below-top anchor: indented root resolves anchor-relative"] = function()
  -- Anchor is a depth-1 child task; a root-then-child block typed under it.
  --   rows_above: top task (0), child task (1)
  --   block:
  --     - note         (typed depth 1 — same indent as the depth-1 anchor)
  --       - subnote    (block child)
  -- The root resolves by its RAW typed depth (1) just like a single-line insert:
  -- clamped to anchor_depth(1)+1 = 1, parent = the depth-0 row above → it lands a
  -- SIBLING of the depth-1 anchor (depth 1).  Its sub-block rides along at depth 2.
  local rows = {
    { depth = 0, kind = "task" },
    { depth = 1, kind = "task" },
  }
  local recs = block.resolve({
    "  - note",
    "    - subnote",
  }, rows)
  eq(#recs, 2)
  eq(recs[1].kind, "description")
  eq(recs[1].depth, 1)
  eq(recs[1].parent.scope, "above")
  eq(recs[1].parent.index, 1)
  eq(recs[2].depth, 2)
  eq(recs[2].parent.scope, "block")
  eq(recs[2].parent.index, 1)
end

return T
