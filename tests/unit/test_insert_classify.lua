-- tests/unit/test_insert_classify.lua
-- Phase 5b: pure classifier + depth/clamp/auto-attach resolution.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local classify = require("obsidian-tasks.render.insert_classify")

-- ── classify_kind ────────────────────────────────────────────────────────────

T["classify_kind: checkbox bullet → task"] = function()
  local kind = classify.classify_kind("- [ ] do it")
  eq(kind, "task")
end

T["classify_kind: '*' checkbox → task"] = function()
  local kind = classify.classify_kind("* [x] done")
  eq(kind, "task")
end

T["classify_kind: bare text → task"] = function()
  local kind, marker, body = classify.classify_kind("just some text")
  eq(kind, "task")
  eq(marker, nil)
  eq(body, "just some text")
end

T["classify_kind: '-' bullet (no checkbox) → description, marker preserved"] = function()
  local kind, marker, body = classify.classify_kind("- a note")
  eq(kind, "description")
  eq(marker, "-")
  eq(body, "a note")
end

T["classify_kind: '*' bullet → description, '*' preserved"] = function()
  local kind, marker, body = classify.classify_kind("* starred note")
  eq(kind, "description")
  eq(marker, "*")
  eq(body, "starred note")
end

T["classify_kind: '+' bullet → description, '+' preserved"] = function()
  local kind, marker = classify.classify_kind("+ plus note")
  eq(kind, "description")
  eq(marker, "+")
end

-- ── typed_depth (2-space convention) ─────────────────────────────────────────

T["typed_depth: col 0 → 0"] = function()
  eq(classify.typed_depth("- note"), 0)
end

T["typed_depth: 2 spaces → 1"] = function()
  eq(classify.typed_depth("  - note"), 1)
end

T["typed_depth: 4 spaces → 2"] = function()
  eq(classify.typed_depth("    - note"), 2)
end

-- ── resolve: TASK keeps clamped typed depth ──────────────────────────────────

T["resolve: col-0 bare task → top-level (depth 0, no parent)"] = function()
  local rows = { { depth = 0, kind = "task" } }
  local r = classify.resolve("new task", rows)
  eq(r.kind, "task")
  eq(r.depth, 0)
  eq(r.parent_index, nil)
end

T["resolve: indented child task → depth 1, parent = top task"] = function()
  local rows = { { depth = 0, kind = "task" } }
  local r = classify.resolve("  - [ ] sub", rows)
  eq(r.kind, "task")
  eq(r.depth, 1)
  eq(r.parent_index, 1)
end

-- ── resolve: col-0 DESCRIPTION is a TRUE TOP-LEVEL item (Phase 2: no promotion) ─

T["resolve: col-0 '- note' after top task → top-level description (depth 0, no parent)"] = function()
  -- Phase 2 literal depth: a col-0 description is NOT promoted under the nearest
  -- top-level task.  It becomes a true top-level bullet at depth 0.
  local rows = { { depth = 0, kind = "task" } }
  local r = classify.resolve("- note", rows)
  eq(r.kind, "description")
  eq(r.marker, "-")
  eq(r.depth, 0)
  eq(r.parent_index, nil)
  eq(r.no_anchor, nil, "no_anchor is gone — a col-0 description never reverts")
end

T["resolve: col-0 '- note' below a bullet is STILL top-level (no scan-up promotion)"] = function()
  -- rows: top task (1), a bullet child (2).  A second col-0 bullet stays at
  -- depth 0 (top-level), it does NOT scan up to attach to the task.
  local rows = {
    { depth = 0, kind = "task" },
    { depth = 1, kind = "description" },
  }
  local r = classify.resolve("- second note", rows)
  eq(r.kind, "description")
  eq(r.depth, 0)
  eq(r.parent_index, nil)
end

T["resolve: col-0 '- note' with only a nested task above → top-level (no no_anchor)"] = function()
  -- Only a nested task above (depth 1).  Phase 2: a col-0 line is top-level; it
  -- never reverts (no_anchor is gone).
  local rows = { { depth = 1, kind = "task" } }
  local r = classify.resolve("- orphan", rows)
  eq(r.kind, "description")
  eq(r.depth, 0)
  eq(r.parent_index, nil)
  eq(r.no_anchor, nil)
end

-- ── resolve: a DIM ancestor is a valid parent at its true absolute depth ──────

T["resolve: indented child under a DIM ancestor chain attaches by depth"] = function()
  -- rows_above mimics dim grandparent(0), dim parent(1), lit match(2).  A line
  -- typed at depth 2 (autoindent off the lit match) attaches as a child of the
  -- depth-1 parent? No: depth 2 → parent is the nearest row at depth 1.  A line
  -- typed at depth 3 clamps to anchor(2)+1 = 3, parent = the depth-2 lit match.
  local rows = {
    { depth = 0, kind = "task" }, -- dim grandparent
    { depth = 1, kind = "task" }, -- dim parent
    { depth = 2, kind = "task" }, -- lit match (anchor)
  }
  local sibling = classify.resolve("    - [ ] sibling", rows) -- depth 2
  eq(sibling.depth, 2)
  eq(sibling.parent_index, 2, "depth-2 line parents to the depth-1 dim parent")

  local childer = classify.resolve("      - [ ] child", rows) -- depth 3
  eq(childer.depth, 3, "clamped to anchor(2)+1")
  eq(childer.parent_index, 3, "depth-3 line parents to the depth-2 lit match")

  local toplevel = classify.resolve("- [ ] outdented", rows) -- col 0
  eq(toplevel.depth, 0)
  eq(toplevel.parent_index, nil, "a col-0 line is top-level, NOT under the dim grandparent")
end

-- ── resolve: DESCRIPTION below top level keeps literal clamped depth ──────────

T["resolve: indented '- note' below top level → literal depth 2 (no promotion)"] = function()
  -- top task (0), child task (1).  A 4-space bullet typed under the child stays
  -- at literal depth 2, parent = the child task.
  local rows = {
    { depth = 0, kind = "task" },
    { depth = 1, kind = "task" },
  }
  local r = classify.resolve("    - deep note", rows)
  eq(r.kind, "description")
  eq(r.depth, 2)
  eq(r.parent_index, 2, "parent is the depth-1 child task")
end

-- ── resolve: CLAMP (no level-skipping) ───────────────────────────────────────

T["resolve: level-skipping indent clamps to anchor_depth + 1"] = function()
  -- Anchor is a top-level task (depth 0).  A line typed at 6 spaces (depth 3)
  -- must clamp to depth 1.
  local rows = { { depth = 0, kind = "task" } }
  local r = classify.resolve("      - [ ] way too deep", rows)
  eq(r.depth, 1, "typed depth 3 clamps to anchor_depth(0) + 1")
end

return T
