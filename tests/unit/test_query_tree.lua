-- tests/unit/test_query_tree.lua
-- Unit tests for query/tree.lua — Phase 3 subtree assembly + dedup.
--
-- assemble() takes the matched left-most tasks (post filter/sort/group/limit,
-- as the QueryResult.groups produced by query/run.lua) plus a node accessor and
-- produces an ordered list of layout-ready ROWS:
--
--   { kind="task"|"bullet"|"blank", depth, src_path, src_line,
--     task=<Task>|nil, text=<string>|nil, fold_group, matched,
--     group_name, group_index }
--
-- Membership (tree ON): each matched task drags in its ENTIRE descendant
-- subtree (child tasks + non-task bullets + interspersed blanks) from the node
-- model, regardless of whether descendants match.  Ancestors are NOT shown.
-- DEDUP: a matched task with a matched ancestor is suppressed as a standalone
-- root — it appears nested under that ancestor instead (one source line ⇒ at
-- most one row).  sort/group/limit operate on the matched tasks; subtrees ride
-- along in source order.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local nodes_mod = require("obsidian-tasks.index.nodes")
local tree = require("obsidian-tasks.query.tree")

-- ── helpers ────────────────────────────────────────────────────────────────

--- Parse inline markdown into a node list (one file).
local function parse_nodes(text)
  return nodes_mod.parse_lines(vim.split(text, "\n", { plain = true }))
end

--- Build a node accessor over a { [path] = node_list } map.
local function accessor(by_path)
  return function(path)
    return by_path[path] or {}
  end
end

--- Find the task node for a 1-based source line in a node list.
local function task_at(ns, line)
  for _, n in ipairs(ns) do
    if n.line_num == line and n.kind == "task" then
      return n.task
    end
  end
  error("no task node at line " .. line)
end

--- Make a matched "item" the way run.lua's groups carry it: a Task with
--- _src_path / _src_line set.
local function matched(ns, path, line)
  local t = task_at(ns, line)
  t._src_path = path
  t._src_line = line
  return t
end

--- Wrap a flat list of matched Tasks into a single unnamed group, the shape
--- assemble() consumes (QueryResult.groups).
local function one_group(tasks)
  return { { name = "", tasks = tasks } }
end

--- Compact a row list into { kind, depth, line } triples for easy assertion.
local function shape(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = { kind = r.kind, depth = r.depth, line = r.src_line }
  end
  return out
end

--- Compact a row list into { kind, depth, line, dim } quadruples — for the
--- induced-forest cases where the dim/lit axis is what is under test.
local function shape_dim(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = { kind = r.kind, depth = r.depth, line = r.src_line, dim = r.dim or false }
  end
  return out
end

local P = "/vault/a.md"

-- ── tree OFF: flat, one row per matched task ────────────────────────────────

T["tree off: one row per matched task, no descendants, depth 0"] = function()
  local ns = parse_nodes(table.concat({
    "- [ ] root", -- 1
    "  - [ ] child", -- 2
    "  - desc", -- 3
    "- [ ] root2", -- 4
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1), matched(ns, P, 4) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = false })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 },
    { kind = "task", depth = 0, line = 4 },
  })
  -- Every flat row is a matched root.
  for _, r in ipairs(rows) do
    eq(r.matched, true)
  end
end

T["tree off: preserves matched order across groups"] = function()
  local ns = parse_nodes("- [ ] a\n- [ ] b\n- [ ] c")
  local groups = {
    { name = "G1", tasks = { matched(ns, P, 2) } },
    { name = "G2", tasks = { matched(ns, P, 1), matched(ns, P, 3) } },
  }
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = false })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 2 },
    { kind = "task", depth = 0, line = 1 },
    { kind = "task", depth = 0, line = 3 },
  })
  eq(rows[1].group_name, "G1")
  eq(rows[2].group_name, "G2")
end

-- ── tree ON: descendants pulled regardless of match ─────────────────────────

T["tree on: matched root drags child tasks, bullets, and interior blanks"] = function()
  local ns = parse_nodes(table.concat({
    "- [ ] root", -- 1 matched
    "  - [ ] child task", -- 2 (not matched, rides along)
    "  - desc bullet", -- 3 bullet
    "", -- 4 interior blank
    "    - deeper bullet", -- 5 grandchild bullet (parent = line 3)
    "- [ ] root2", -- 6 sibling (NOT a descendant)
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 },
    { kind = "task", depth = 1, line = 2 },
    { kind = "bullet", depth = 1, line = 3 },
    { kind = "blank", depth = nil, line = 4 },
    { kind = "bullet", depth = 2, line = 5 },
  })
  -- root2 (line 6) is a sibling, not pulled in.
  for _, r in ipairs(rows) do
    eq(r.src_line ~= 6, true)
  end
  -- Subtree rows carry the matched flag only on the root.
  eq(rows[1].matched, true)
  eq(rows[2].matched, false)
  eq(rows[3].matched, false)
end

T["tree on: descendants ride along even when they do NOT match the filter"] = function()
  -- Only the root matched the filter (e.g. `priority is high`); the child has
  -- no priority but is still pulled in as part of the subtree.
  local ns = parse_nodes("- [ ] root\n  - [ ] unmatched child\n  - [ ] another child")
  local groups = one_group({ matched(ns, P, 1) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(#rows, 3)
  eq(rows[2].src_line, 2)
  eq(rows[3].src_line, 3)
end

T["tree on: ancestors ARE shown DIM at true depth, then the lit subtree"] = function()
  -- A deep task matches; its parent/grandparent are NOT matched.  The induced
  -- forest emits them as DIM breadcrumb rows at their ABSOLUTE source depths
  -- (no re-rooting), then the lit matched task + its own descendant subtree.
  local ns = parse_nodes(table.concat({
    "- [ ] grandparent", -- 1 (NOT matched) → dim ancestor, depth 0
    "  - [ ] parent", -- 2 (NOT matched) → dim ancestor, depth 1
    "    - [ ] matched", -- 3 matched → lit root, depth 2
    "      - leaf bullet", -- 4 descendant of matched → DIM (D2: not independently matched), depth 3
  }, "\n"))
  local groups = one_group({ matched(ns, P, 3) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 }, -- dim grandparent
    { kind = "task", depth = 1, line = 2 }, -- dim parent
    { kind = "task", depth = 2, line = 3 }, -- lit matched root (true depth)
    { kind = "bullet", depth = 3, line = 4 }, -- D2: dim descendant (context)
  })
  -- The two ancestors are DIM (breadcrumb), not matched; not foldable.
  eq(rows[1].dim, true)
  eq(rows[1].matched, false)
  eq(rows[1].fold_group, 0)
  eq(rows[2].dim, true)
  eq(rows[2].fold_group, 0)
  -- The matched task is LIT (dim nil), matched, in a real fold group.
  eq(rows[3].dim, nil)
  eq(rows[3].matched, true)
  eq(rows[3].fold_group ~= 0, true)
  -- D2: the descendant bullet does NOT independently match the group, so it rides
  -- along DIM (context) — but still inside the matched root's fold group, so it
  -- collapses with the subtree.  Dim ≠ separate fold; it stays in fold_group.
  eq(rows[4].dim, true)
  eq(rows[4].matched, false)
  eq(rows[4].fold_group, rows[3].fold_group)
end

T["tree on: trailing blanks before a sibling are NOT pulled into the subtree"] = function()
  local ns = parse_nodes(table.concat({
    "- [ ] root", -- 1 matched
    "  - [ ] child", -- 2 descendant
    "", -- 3 trailing blank (between subtree and sibling)
    "- [ ] sibling", -- 4 (not matched)
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 },
    { kind = "task", depth = 1, line = 2 },
  })
end

-- ── dedup: matched child under matched parent appears only nested ───────────

T["tree on: dedup — matched child under matched parent appears only nested"] = function()
  local ns = parse_nodes(table.concat({
    "- [ ] parent", -- 1 matched
    "  - [ ] child", -- 2 ALSO matched
    "- [ ] other", -- 3 matched, no matched ancestor
  }, "\n"))
  -- All three matched the filter; child is suppressed as a standalone root.
  local groups = one_group({ matched(ns, P, 1), matched(ns, P, 2), matched(ns, P, 3) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 }, -- parent root
    { kind = "task", depth = 1, line = 2 }, -- child nested under parent
    { kind = "task", depth = 0, line = 3 }, -- other root
  })
  -- Exactly one row per source line (the dedup invariant).
  local seen = {}
  for _, r in ipairs(rows) do
    local k = r.src_path .. ":" .. tostring(r.src_line)
    eq(seen[k], nil)
    seen[k] = true
  end
  -- The child row is the same node — emitted nested, flagged not a root.
  eq(rows[2].matched, false)
end

T["tree on: deep dedup — matched grandchild suppressed under matched grandparent"] = function()
  -- grandparent (matched) / parent (NOT matched) / grandchild (matched).
  -- The grandchild has a matched ANCESTOR (grandparent), so it is suppressed
  -- as a standalone root; it appears nested under grandparent's subtree.
  local ns = parse_nodes(table.concat({
    "- [ ] grandparent", -- 1 matched
    "  - [ ] parent", -- 2 not matched (rides along)
    "    - [ ] grandchild", -- 3 matched
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1), matched(ns, P, 3) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 },
    { kind = "task", depth = 1, line = 2 },
    { kind = "task", depth = 2, line = 3 },
  })
end

T["tree on: a matched child whose parent is NOT matched is a LIT root under a DIM parent"] = function()
  -- parent NOT matched; only the child matched → child has no matched ancestor,
  -- so it is a LIT root.  Its parent is shown as a DIM breadcrumb at depth 0; the
  -- child renders LIT at its true depth 1 (NOT re-rooted to depth 0).
  local ns = parse_nodes("- [ ] parent\n  - [ ] child")
  local groups = one_group({ matched(ns, P, 2) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 }, -- dim parent breadcrumb
    { kind = "task", depth = 1, line = 2 }, -- lit child at TRUE depth 1
  })
  eq(rows[1].dim, true)
  eq(rows[1].matched, false)
  eq(rows[2].dim, nil)
  eq(rows[2].matched, true)
end

T["tree on: PER-GROUP dedup — cross-group ancestor/descendant split both appear"] = function()
  -- `group by tags` + `show tree`: parent tagged #x lands ONLY in group #x; the
  -- matched child tagged #y lands ONLY in group #y.  Dedup is PER-GROUP, so the
  -- child's matched ancestor (parent) is NOT in the child's group → the child is
  -- NOT suppressed.  It must emit as a ROOT in #y (never silently dropped).
  local ns = parse_nodes(table.concat({
    "- [ ] parent #x", -- 1 matched, in group #x only
    "  - [ ] child #y", -- 2 matched, in group #y only
  }, "\n"))
  local groups = {
    { name = "#x", tasks = { matched(ns, P, 1) } },
    { name = "#y", tasks = { matched(ns, P, 2) } },
  }
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    -- group #x: parent is the lit root, child rides along nested (lit).
    { kind = "task", depth = 0, line = 1 },
    { kind = "task", depth = 1, line = 2 },
    -- group #y: child emitted as its OWN lit root at TRUE depth 1, under its DIM
    -- parent breadcrumb (NOT re-rooted to depth 0).
    { kind = "task", depth = 0, line = 1 }, -- dim parent breadcrumb
    { kind = "task", depth = 1, line = 2 }, -- lit child at true depth
  })
  -- #x: parent is the matched root, child rides along (not the matched root).
  eq(rows[1].group_name, "#x")
  eq(rows[1].matched, true)
  eq(rows[1].dim, nil)
  eq(rows[2].group_name, "#x")
  eq(rows[2].matched, false)
  -- #y: the parent breadcrumb is DIM; the child IS present as a lit matched root.
  eq(rows[3].group_name, "#y")
  eq(rows[3].dim, true)
  eq(rows[3].matched, false)
  eq(rows[4].group_name, "#y")
  eq(rows[4].matched, true)
  eq(rows[4].dim, nil)
  -- The matched child never disappears: it appears LIT in group #y.
  local child_lit_in_y = false
  for _, r in ipairs(rows) do
    if r.group_name == "#y" and r.src_line == 2 and r.matched then
      child_lit_in_y = true
    end
  end
  eq(child_lit_in_y, true)
end

-- ── fold groups ─────────────────────────────────────────────────────────────

T["tree on: each emitted subtree shares one fold_group id; roots differ"] = function()
  local ns = parse_nodes(table.concat({
    "- [ ] r1", -- 1
    "  - [ ] c1", -- 2
    "- [ ] r2", -- 3
    "  - bullet", -- 4
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1), matched(ns, P, 3) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  -- rows: r1, c1, r2, bullet
  eq(rows[1].fold_group, rows[2].fold_group)
  eq(rows[3].fold_group, rows[4].fold_group)
  eq(rows[1].fold_group ~= rows[3].fold_group, true)
end

-- ── ordering / group / limit ride-along ─────────────────────────────────────

T["tree on: matched roots emitted in the order run.lua sorted them"] = function()
  -- assemble must NOT re-sort; it consumes the order the caller (sort/group)
  -- already established.  Here the caller put line 3 before line 1.
  local ns = parse_nodes("- [ ] a\n  - desc-a\n- [ ] b\n  - desc-b")
  local groups = one_group({ matched(ns, P, 3), matched(ns, P, 1) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 3 },
    { kind = "bullet", depth = 1, line = 4 },
    { kind = "task", depth = 0, line = 1 },
    { kind = "bullet", depth = 1, line = 2 },
  })
end

T["tree on: descendants within a subtree stay in SOURCE order"] = function()
  local ns = parse_nodes(table.concat({
    "- [ ] root", -- 1
    "  - [ ] z later", -- 2
    "  - [ ] a earlier", -- 3
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  -- Source order (2 then 3), NOT alphabetical.
  eq(rows[2].src_line, 2)
  eq(rows[3].src_line, 3)
end

T["tree on: group headers carried via group_name on each row"] = function()
  local ns = parse_nodes("- [ ] a\n  - bullet-a\n- [ ] b")
  local groups = {
    { name = "GroupA", tasks = { matched(ns, P, 1) } },
    { name = "GroupB", tasks = { matched(ns, P, 3) } },
  }
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  -- root a + its bullet ride in GroupA; root b in GroupB.
  eq(rows[1].group_name, "GroupA")
  eq(rows[2].group_name, "GroupA") -- bullet inherits the root's group
  eq(rows[3].group_name, "GroupB")
end

T["tree on: group duplication preserved — a matched task in two groups emits in BOTH"] = function()
  -- Mirrors run.lua's group-by-tags duplication: the SAME matched task (line 1)
  -- appears under two group names; its subtree rides along in each.  Dedup is
  -- about ANCESTRY suppression, not group de-duplication, so this is expected.
  local ns = parse_nodes("- [ ] dual #x #y\n  - note")
  local dual = matched(ns, P, 1)
  local groups = {
    { name = "#x", tasks = { dual } },
    { name = "#y", tasks = { dual } },
  }
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 },
    { kind = "bullet", depth = 1, line = 2 },
    { kind = "task", depth = 0, line = 1 },
    { kind = "bullet", depth = 1, line = 2 },
  })
  eq(rows[1].group_name, "#x")
  eq(rows[3].group_name, "#y")
end

-- ── multi-file ──────────────────────────────────────────────────────────────

T["tree on: subtrees resolve against each task's own file"] = function()
  local nsA = parse_nodes("- [ ] a-root\n  - a-bullet")
  local nsB = parse_nodes("- [ ] b-root\n  - [ ] b-child")
  local PA, PB = "/vault/a.md", "/vault/b.md"
  local groups = one_group({ matched(nsA, PA, 1), matched(nsB, PB, 1) })
  local rows = tree.assemble(groups, accessor({ [PA] = nsA, [PB] = nsB }), { tree = true })
  eq(rows[1].src_path, PA)
  eq(rows[2].src_path, PA)
  eq(rows[2].kind, "bullet")
  eq(rows[3].src_path, PB)
  eq(rows[4].src_path, PB)
  eq(rows[4].kind, "task")
end

-- ── dedup is per-file (same line number in different files is distinct) ──────

T["tree on: dedup keys on (path,line) — same line in two files is independent"] = function()
  local nsA = parse_nodes("- [ ] a1\n  - [ ] a2")
  local nsB = parse_nodes("- [ ] b1\n  - [ ] b2")
  local PA, PB = "/vault/a.md", "/vault/b.md"
  -- In file A both lines matched (child suppressed); in file B only the root.
  local groups = one_group({
    matched(nsA, PA, 1),
    matched(nsA, PA, 2),
    matched(nsB, PB, 1),
  })
  local rows = tree.assemble(groups, accessor({ [PA] = nsA, [PB] = nsB }), { tree = true })
  -- A: root a1 + nested a2 (a2 standalone suppressed).  B: root b1 + ride a2.
  eq(shape(rows), {
    { kind = "task", depth = 0, line = 1 }, -- a1
    { kind = "task", depth = 1, line = 2 }, -- a2 nested
    { kind = "task", depth = 0, line = 1 }, -- b1
    { kind = "task", depth = 1, line = 2 }, -- b2 ride-along
  })
  eq(rows[1].src_path, PA)
  eq(rows[3].src_path, PB)
end

-- ── induced forest: connector ancestors ─────────────────────────────────────

T["tree on: a matched descendant rides LIT in its root's drag; the unmatched middle is DIM"] = function()
  -- grandparent (matched) / parent (NOT matched) / grandchild (matched).
  -- The grandchild's matched ancestor (grandparent) lives in the SAME group, so
  -- the grandchild is suppressed as a standalone root → it appears nested inside
  -- the grandparent's drag.  D2: a descendant is LIT only when it INDEPENDENTLY
  -- matches the group — the grandchild matches (LIT), but the unmatched middle
  -- `parent` is context (DIM) even though it rides inside the lit subtree.
  local ns = parse_nodes(table.concat({
    "- [ ] grandparent", -- 1 matched → lit root
    "  - [ ] parent", -- 2 not matched → DIM (rides along, context)
    "    - [ ] grandchild", -- 3 matched → suppressed, lit nested
  }, "\n"))
  local groups = one_group({ matched(ns, P, 1), matched(ns, P, 3) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape_dim(rows), {
    { kind = "task", depth = 0, line = 1, dim = false }, -- lit matched root
    { kind = "task", depth = 1, line = 2, dim = true }, -- D2: unmatched middle is dim
    { kind = "task", depth = 2, line = 3, dim = false }, -- lit matched grandchild
  })
  eq(rows[1].matched, true)
  eq(rows[3].matched, false) -- grandchild rides in the drag, not a root flag
  -- All three share the grandparent's fold group (one lit subtree); the dim
  -- middle is NOT a sentinel-0 breadcrumb (it is a drag descendant, foldable).
  eq(rows[2].fold_group, rows[1].fold_group)
  eq(rows[3].fold_group, rows[1].fold_group)
end

T["tree on: two matched children under one parent → parent appears ONCE (merged), both lit nested"] = function()
  -- parent NOT matched; both children matched.  Each child is a LIT root (no
  -- matched ancestor).  The shared parent is emitted ONCE as a DIM breadcrumb
  -- (merged), with both children nested lit under it at their true depth 1.
  local ns = parse_nodes(table.concat({
    "- [ ] parent", -- 1 NOT matched → dim breadcrumb (shared)
    "  - [ ] child a", -- 2 matched → lit root
    "  - [ ] child b", -- 3 matched → lit root
  }, "\n"))
  local groups = one_group({ matched(ns, P, 2), matched(ns, P, 3) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  -- Structure-first: parent (dim) emitted just before child a, NOT re-emitted
  -- before child b (merged).  child a's drag includes child b (its descendant)?
  -- No — they are siblings, so child a's drag is just child a.
  eq(shape_dim(rows), {
    { kind = "task", depth = 0, line = 1, dim = true }, -- merged dim parent
    { kind = "task", depth = 1, line = 2, dim = false }, -- lit child a
    { kind = "task", depth = 1, line = 3, dim = false }, -- lit child b
  })
  -- The parent line appears exactly once.
  local parent_count = 0
  for _, r in ipairs(rows) do
    if r.src_line == 1 then
      parent_count = parent_count + 1
    end
  end
  eq(parent_count, 1)
  -- The two children have distinct fold groups (each its own lit subtree); the
  -- dim parent is not foldable (sentinel 0).
  eq(rows[1].fold_group, 0)
  eq(rows[2].fold_group ~= rows[3].fold_group, true)
  eq(rows[2].fold_group ~= 0, true)
end

T["tree on: a BULLET ancestor is dimmed (a checkbox nested under a - bullet)"] = function()
  -- A non-task bullet is the parent of a matched checkbox.  The connector-ancestor
  -- walk must dim the BULLET too (ancestors may be task OR bullet).
  local ns = parse_nodes(table.concat({
    "- a plain bullet", -- 1 bullet, NOT a task → dim ancestor
    "  - [ ] matched", -- 2 matched task → lit root at true depth 1
  }, "\n"))
  local groups = one_group({ matched(ns, P, 2) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape_dim(rows), {
    { kind = "bullet", depth = 0, line = 1, dim = true }, -- dim bullet breadcrumb
    { kind = "task", depth = 1, line = 2, dim = false }, -- lit matched task
  })
  eq(rows[1].kind, "bullet")
  eq(rows[1].dim, true)
  eq(rows[1].matched, false)
  eq(rows[1].fold_group, 0)
  -- Bullet round-trip metadata still threaded on the dim ancestor row.
  eq(rows[1].bullet_marker, "-")
  eq(rows[1].bullet_source_text, "- a plain bullet")
end

T["tree on: structure-first ordering is deterministic (ancestor before first matched descendant)"] = function()
  -- Two matched descendants under a shared grandparent chain, in caller order
  -- [deep-first-match, sibling].  The grandparent + parent breadcrumb are emitted
  -- (dim) just before the FIRST matched descendant; the second matched descendant
  -- nests under the already-emitted breadcrumb in place (no re-emit).
  local ns = parse_nodes(table.concat({
    "- [ ] gp", -- 1 NOT matched → dim
    "  - [ ] p", -- 2 NOT matched → dim
    "    - [ ] m1", -- 3 matched → lit root (true depth 2)
    "    - [ ] m2", -- 4 matched → lit root (true depth 2)
  }, "\n"))
  -- Caller order: m1 then m2 (run.lua already sorted them).
  local groups = one_group({ matched(ns, P, 3), matched(ns, P, 4) })
  local rows = tree.assemble(groups, accessor({ [P] = ns }), { tree = true })
  eq(shape_dim(rows), {
    { kind = "task", depth = 0, line = 1, dim = true }, -- dim gp (once)
    { kind = "task", depth = 1, line = 2, dim = true }, -- dim p (once)
    { kind = "task", depth = 2, line = 3, dim = false }, -- lit m1
    { kind = "task", depth = 2, line = 4, dim = false }, -- lit m2 nested in place
  })
  -- Each ancestor appears exactly once (merged across both matched descendants).
  local gp, p = 0, 0
  for _, r in ipairs(rows) do
    if r.src_line == 1 then
      gp = gp + 1
    elseif r.src_line == 2 then
      p = p + 1
    end
  end
  eq(gp, 1)
  eq(p, 1)
  -- m1 and m2 are independent lit subtrees.
  eq(rows[3].fold_group ~= rows[4].fold_group, true)
end

return T
