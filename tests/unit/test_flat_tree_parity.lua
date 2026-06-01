-- tests/unit/test_flat_tree_parity.lua
-- Parametrized FLAT-vs-TREE regression harness (Phase 3 Deliverable 3).
--
-- Each core-behavior case from the shared SPEC table is asserted in BOTH render
-- modes:
--   • FLAT  — query_result.groups, layout takes the flat path.
--   • TREE  — query_result.tree_rows, layout takes the consolidated tree path.
--
-- The two paths now converge on ONE shared emit engine (emit_group_body +
-- emit_linger + the unified header/ghost-group loop in render/layout.lua), so a
-- future divergence — a feature added to the flat path but forgotten in the tree
-- path (the exact failure mode of the earlier regressions: lingering, ghost
-- groups, group-attr, completed-dim) — makes the matching TREE assertion fail in
-- CI.  Every assertion is written against the mode-agnostic rendered records.
--
-- The behaviors guarded here (audited from emit_group_body + M.layout):
--   (a) lingering: a completed task lingers dimmed at its prior position, then
--       clears on refresh — BOTH modes (tree asserts the subtree block lingers).
--   (b) ghost groups.
--   (c) group-attr / P9 injection on insert (asserted in the dedicated real-mode
--       suites; here we assert the structural precondition the gate reads:
--       matched + group_name are threaded identically in both modes).
--   (d) completed dim-in-place with NO reorder.
--   (e) result count / footer total.
--   (f) group headers (named always; unnamed only in a multi-group context).
--   (g) hide flags pass-through.

local T = MiniTest.new_set()

local layout_mod = require("obsidian-tasks.render.layout")
local parse_task = require("obsidian-tasks.task.parse")

local eq = MiniTest.expect.equality

-- ── builders ─────────────────────────────────────────────────────────────────

local function pt(line, path, src_line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  t._src_path = path
  t._src_line = src_line
  return t
end

--- Build a FLAT query_result from a list of group specs.
--- group spec: { name = string, tasks = { {line, src_line}, … } }
local function flat_result(groups_spec, total, hide)
  local groups = {}
  for _, gs in ipairs(groups_spec) do
    local tasks = {}
    for _, ts in ipairs(gs.tasks) do
      tasks[#tasks + 1] = pt(ts.line, ts.path or "/v/a.md", ts.src_line)
    end
    groups[#groups + 1] = { name = gs.name, tasks = tasks }
  end
  return {
    groups = groups,
    total = total,
    hide_flags = hide or { backlinks = true },
    header_summary = "",
    errors = {},
  }
end

--- Build a TREE query_result from the SAME group specs, one matched root per
--- task (each task is a depth-0 lit root in its own fold_group).  groups stays
--- populated (run.lua fills it in tree mode too — ghost detection reads it).
local function tree_result(groups_spec, total, hide)
  local res = flat_result(groups_spec, total, hide)
  local tree_rows = {}
  local fold_group = 0
  for _, gs in ipairs(groups_spec) do
    local gi = 0
    for _, ts in ipairs(gs.tasks) do
      fold_group = fold_group + 1
      local t = pt(ts.line, ts.path or "/v/a.md", ts.src_line)
      tree_rows[#tree_rows + 1] = {
        kind = "task",
        depth = 0,
        src_path = ts.path or "/v/a.md",
        src_line = ts.src_line,
        task = t,
        matched = true,
        fold_group = fold_group,
        group_name = gs.name,
        group_index = gi,
        parent_line = nil,
      }
      gi = gi + 1
    end
  end
  res.tree_rows = tree_rows
  return res
end

--- For a TREE linger, build the reconstructed linger_subtree (a single lit root
--- row, the degenerate single-task subtree) the way render/init.lua would.
local function tree_linger_subtree(ts, group_name, group_index)
  local t = pt(ts.line, ts.path or "/v/a.md", ts.src_line)
  return {
    {
      kind = "task",
      depth = 0,
      src_path = ts.path or "/v/a.md",
      src_line = ts.src_line,
      task = t,
      matched = true,
      fold_group = 1,
      group_name = group_name,
      group_index = group_index,
      parent_line = nil,
    },
  }
end

local function task_records(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    if l.kind == "task" then
      out[#out + 1] = l
    end
  end
  return out
end

local function headers(rendered)
  local out = {}
  for _, l in ipairs(rendered) do
    if l.kind == "group_header" then
      out[#out + 1] = l.text
    end
  end
  return out
end

local function footer(rendered)
  return rendered[#rendered]
end

-- run a builder under BOTH modes and call the assert fn with the rendered lines
local function both_modes(build, opts, assert_fn)
  local flat = layout_mod.layout(build("flat"), opts)
  assert_fn("flat", flat)
  local tree = layout_mod.layout(build("tree"), opts)
  assert_fn("tree", tree)
end

-- ── (d) + (e) completed dim-in-place, no reorder; footer total ───────────────

T["parity: completed task dimmed in place (no reorder), footer total"] = function()
  local spec = {
    {
      name = "",
      tasks = { { line = "- [x] done first", src_line = 1 }, { line = "- [ ] todo second", src_line = 2 } },
    },
  }
  local function build(mode)
    return (mode == "flat") and flat_result(spec, 2) or tree_result(spec, 2)
  end
  both_modes(build, { dim_completed = true }, function(mode, rendered)
    local tasks = task_records(rendered)
    eq(#tasks, 2, mode .. ": two task rows")
    -- Done stays FIRST (in place), dimmed.  Todo second, not dimmed.
    eq(tasks[1].text:sub(1, #"- [x] done first"), "- [x] done first", mode .. ": done stays first")
    eq(tasks[1].dim, true, mode .. ": done row dimmed")
    eq(tasks[2].dim, nil, mode .. ": todo row not dimmed")
    -- Footer total reflects the live count (2), identical in both modes.
    eq(footer(rendered).kind, "footer")
    eq(footer(rendered).text:find("2 results", 1, true) ~= nil, true, mode .. ": footer shows 2 results")
  end)
end

-- ── (f) group headers: named always; unnamed only when multi-group ───────────

T["parity: single unnamed group emits NO header"] = function()
  local spec = { { name = "", tasks = { { line = "- [ ] a", src_line = 1 } } } }
  local function build(mode)
    return (mode == "flat") and flat_result(spec, 1) or tree_result(spec, 1)
  end
  both_modes(build, {}, function(mode, rendered)
    eq(#headers(rendered), 0, mode .. ": no header for a single unnamed group")
  end)
end

T["parity: named groups always emit a header"] = function()
  local spec = {
    { name = "#alpha", tasks = { { line = "- [ ] a", src_line = 1 } } },
    { name = "#beta", tasks = { { line = "- [ ] b", src_line = 2 } } },
  }
  local function build(mode)
    return (mode == "flat") and flat_result(spec, 2) or tree_result(spec, 2)
  end
  both_modes(build, {}, function(mode, rendered)
    local h = headers(rendered)
    eq(h[1], "## #alpha", mode .. ": first header")
    eq(h[2], "## #beta", mode .. ": second header")
  end)
end

T["parity: unnamed group in a multi-group context gets a (no group) header"] = function()
  -- One named group + one unnamed group → multi-group → unnamed gets a header.
  local spec = {
    { name = "", tasks = { { line = "- [ ] a", src_line = 1 } } },
    { name = "#beta", tasks = { { line = "- [ ] b", src_line = 2 } } },
  }
  local function build(mode)
    return (mode == "flat") and flat_result(spec, 2) or tree_result(spec, 2)
  end
  both_modes(build, {}, function(mode, rendered)
    local h = headers(rendered)
    local saw_nogroup = false
    for _, t in ipairs(h) do
      if t == "## (no group)" then
        saw_nogroup = true
      end
    end
    eq(saw_nogroup, true, mode .. ": unnamed group gets (no group) header in multi-group context")
  end)
end

-- ── (g) hide flags pass-through ──────────────────────────────────────────────

T["parity: hide task_count omits the footer count in both modes"] = function()
  local spec = { { name = "", tasks = { { line = "- [ ] a", src_line = 1 } } } }
  local function build(mode)
    local r = (mode == "flat") and flat_result(spec, 1) or tree_result(spec, 1)
    r.hide_flags = { backlinks = true, task_count = true }
    return r
  end
  both_modes(build, {}, function(mode, rendered)
    eq(footer(rendered).text:find("result", 1, true) == nil, true, mode .. ": task count hidden from footer")
  end)
end

T["parity: hide backlinks suppresses the wikilink suffix in both modes"] = function()
  local spec = { { name = "", tasks = { { line = "- [ ] a", path = "/v/note.md", src_line = 1 } } } }
  local function build(mode)
    local r = (mode == "flat") and flat_result(spec, 1) or tree_result(spec, 1)
    r.hide_flags = { backlinks = true }
    return r
  end
  both_modes(build, {}, function(mode, rendered)
    local tasks = task_records(rendered)
    eq(tasks[1].text:find("[[", 1, true) == nil, true, mode .. ": no wikilink suffix when backlinks hidden")
  end)
end

-- ── (c) group-attr precondition: matched + group_name threaded identically ───
-- The P9 injection gate (render/edit.lua) reads `matched` + `group_name` from the
-- managed-row meta.  Assert both modes thread them onto the rendered records the
-- same way so the gate cannot silently diverge.

T["parity: group_name is carried onto task records in both modes"] = function()
  local spec = { { name = "g1", tasks = { { line = "- [ ] a", src_line = 1 } } } }
  local function build(mode)
    return (mode == "flat") and flat_result(spec, 1) or tree_result(spec, 1)
  end
  both_modes(build, {}, function(mode, rendered)
    local tasks = task_records(rendered)
    eq(tasks[1].group_name, "g1", mode .. ": group_name threaded")
  end)
end

-- ── (a) lingering: a completed task lingers dimmed at prior position ──────────

T["parity: a completed task lingers dimmed at its prior position"] = function()
  -- Live group has one task (live a at index 0); a completed task lingers at
  -- prior_index 1 (it was the second row before it left the filter).
  local live = { { name = "", tasks = { { line = "- [ ] live a", src_line = 1 } } } }
  local linger_ts = { line = "- [x] done b", src_line = 2 }

  local function build_flat()
    local r = flat_result(live, 1)
    return r
  end
  local function build_tree()
    local r = tree_result(live, 1)
    return r
  end

  local function linger_opts(mode)
    local ent = {
      task = pt(linger_ts.line, "/v/a.md", linger_ts.src_line),
      src_path = "/v/a.md",
      src_line = linger_ts.src_line,
      prior_group_name = "",
      prior_index_within_group = 1,
    }
    if mode == "tree" then
      ent.linger_subtree = tree_linger_subtree(linger_ts, "", 1)
    end
    return { lingers = { ent }, group_by = {} }
  end

  -- FLAT
  local flat = layout_mod.layout(build_flat(), linger_opts("flat"))
  do
    local tasks = task_records(flat)
    eq(#tasks, 2, "flat: live + linger")
    eq(tasks[1].linger, nil, "flat: live first")
    eq(tasks[2].linger, true, "flat: linger second")
    eq(tasks[2].dim, true, "flat: linger dimmed")
    eq(tasks[2].src_line, 2, "flat: linger at prior position")
  end

  -- TREE: the linger renders as a subtree block (here a single lit root row),
  -- dimmed, at its prior position.
  local tree = layout_mod.layout(build_tree(), linger_opts("tree"))
  do
    local tasks = task_records(tree)
    eq(#tasks, 2, "tree: live + linger subtree block")
    eq(tasks[1].linger, nil, "tree: live first")
    eq(tasks[2].linger, true, "tree: linger second")
    eq(tasks[2].dim, true, "tree: linger dimmed")
    eq(tasks[2].src_line, 2, "tree: linger at prior position")
  end
end

T["parity: a linger that BUMPS a live unit updates the bumped unit's group_index"] = function()
  -- Audit finding: the tree-path unit emit must stamp the post-splice group_index
  -- (like the flat path passes output_idx into build_live_line), so a later
  -- toggle of a bumped root recovers the SAME prior_index_within_group in both
  -- modes.  A linger at prior_index 0 bumps the live unit to index 1.
  local live = { { name = "", tasks = { { line = "- [ ] live a", src_line = 1 } } } }
  local linger_ts = { line = "- [x] done b", src_line = 2 }

  local function linger_opts(mode)
    local ent = {
      task = pt(linger_ts.line, "/v/a.md", linger_ts.src_line),
      src_path = "/v/a.md",
      src_line = linger_ts.src_line,
      prior_group_name = "",
      prior_index_within_group = 0, -- linger holds slot 0; live a bumps to slot 1
    }
    if mode == "tree" then
      ent.linger_subtree = tree_linger_subtree(linger_ts, "", 0)
    end
    return { lingers = { ent }, group_by = {} }
  end

  for _, mode in ipairs({ "flat", "tree" }) do
    local result = (mode == "flat") and flat_result(live, 1) or tree_result(live, 1)
    local rendered = layout_mod.layout(result, linger_opts(mode))
    local tasks = task_records(rendered)
    eq(#tasks, 2, mode .. ": linger + bumped live")
    eq(tasks[1].linger, true, mode .. ": linger at slot 0")
    eq(tasks[1].group_index, 0, mode .. ": linger group_index 0")
    -- The live unit was bumped from its original slot 0 to slot 1.
    eq(tasks[2].src_line, 1, mode .. ": live a is second")
    eq(tasks[2].group_index, 1, mode .. ": bumped live unit carries the post-splice group_index")
  end
end

T["parity: linger cleared (no linger opts) renders only live rows"] = function()
  -- Simulates the post-refresh state: with no linger entries, only live rows
  -- render — identical in both modes.
  local spec = { { name = "", tasks = { { line = "- [ ] live a", src_line = 1 } } } }
  local function build(mode)
    return (mode == "flat") and flat_result(spec, 1) or tree_result(spec, 1)
  end
  both_modes(build, {}, function(mode, rendered)
    local tasks = task_records(rendered)
    eq(#tasks, 1, mode .. ": only the live row after linger clears")
    eq(tasks[1].linger, nil, mode .. ": no linger flag")
  end)
end

-- ── (b) ghost groups: a group holding only lingers still renders ─────────────

T["parity: ghost group renders header + linger when its live group is empty"] = function()
  -- No live members in group "ghostgrp"; one task lingers there.
  local linger_ts = { line = "- [x] done c", src_line = 5 }

  local function build_flat()
    return flat_result({}, 0)
  end
  local function build_tree()
    -- tree mode with no live roots → empty tree_rows; ghost detection reads the
    -- (empty) live groups, so the ghost group still surfaces from lingers_by_group.
    local r = tree_result({}, 0)
    r.tree_rows = {}
    return r
  end

  local function ghost_opts(mode)
    local ent = {
      task = pt(linger_ts.line, "/v/a.md", linger_ts.src_line),
      src_path = "/v/a.md",
      src_line = linger_ts.src_line,
      prior_group_name = "ghostgrp",
      prior_index_within_group = 0,
    }
    if mode == "tree" then
      ent.linger_subtree = tree_linger_subtree(linger_ts, "ghostgrp", 0)
    end
    return { lingers = { ent }, group_by = {} }
  end

  for _, mode in ipairs({ "flat", "tree" }) do
    local build = (mode == "flat") and build_flat or build_tree
    local rendered = layout_mod.layout(build(), ghost_opts(mode))
    local saw_ghost_header = false
    local saw_ghost_linger = false
    for i, l in ipairs(rendered) do
      if l.kind == "group_header" and l.text == "## ghostgrp" then
        saw_ghost_header = true
        for j = i + 1, #rendered do
          if rendered[j].kind == "task" then
            eq(rendered[j].linger, true, mode .. ": ghost linger row")
            saw_ghost_linger = true
            break
          end
        end
      end
    end
    eq(saw_ghost_header, true, mode .. ": ghost group header present")
    eq(saw_ghost_linger, true, mode .. ": ghost group linger present")
  end
end

-- ── FIX 1: tree linger-subtree dedup covers DESCENDANT rows, not just the root ─
-- A TREE linger emits a whole subtree block {root, …descendants}.  If a descendant
-- later RE-MATCHES (its matched ancestor left the filter) it becomes its OWN live
-- unit with its own (path,line) key.  The linger dedup key set must include EVERY
-- subtree row, not just the root — otherwise the descendant renders TWICE (once
-- dimmed inside the lingered block, once live), corrupting locate/drift.

T["fix1: a re-matching linger-subtree descendant renders EXACTLY once (as the dim linger copy)"] = function()
  -- Root A is line 1, descendant B is line 2.  A was toggled Done and lingers as a
  -- block {A,B}.  On this render B is no longer suppressed (its matched ancestor
  -- left the filter), so B appears as its OWN live root unit (src_line 2).  B must
  -- render exactly once: the dimmed linger copy, never a second live row.
  local A = { line = "- [x] Root A", src_line = 1 }
  local B = { line = "  - [ ] Child B", src_line = 2 }

  -- TREE result whose live root is B (line 2) — the re-matched descendant.
  local res = {
    groups = { { name = "", tasks = { pt(B.line, "/v/a.md", B.src_line) } } },
    total = 1,
    hide_flags = { backlinks = true },
    header_summary = "",
    errors = {},
    tree_rows = {
      {
        kind = "task",
        depth = 0,
        src_path = "/v/a.md",
        src_line = B.src_line,
        task = pt(B.line, "/v/a.md", B.src_line),
        matched = true,
        fold_group = 1,
        group_name = "",
        group_index = 0,
        parent_line = nil,
      },
    },
  }

  -- The lingered block: root A (line 1) + descendant B (line 2).
  local linger_subtree = {
    {
      kind = "task",
      depth = 0,
      src_path = "/v/a.md",
      src_line = A.src_line,
      task = pt(A.line, "/v/a.md", A.src_line),
      matched = true,
      fold_group = 1,
      group_name = "",
      group_index = 0,
      parent_line = nil,
    },
    {
      kind = "task",
      depth = 1,
      src_path = "/v/a.md",
      src_line = B.src_line,
      task = pt(B.line, "/v/a.md", B.src_line),
      matched = false,
      fold_group = 1,
      group_name = "",
      group_index = 0,
      parent_line = A.src_line,
    },
  }
  local ent = {
    task = pt(A.line, "/v/a.md", A.src_line),
    src_path = "/v/a.md",
    src_line = A.src_line,
    prior_group_name = "",
    prior_index_within_group = 0,
    linger_subtree = linger_subtree,
  }

  local rendered = layout_mod.layout(res, { lingers = { ent }, group_by = {} })
  local tasks = task_records(rendered)

  -- Count rows whose source line is B (line 2).
  local b_rows = {}
  for _, t in ipairs(tasks) do
    if t.src_line == 2 then
      b_rows[#b_rows + 1] = t
    end
  end
  eq(#b_rows, 1, "descendant B (line 2) must render EXACTLY once")
  -- And the single B row is the dimmed linger copy, NOT a live row.
  eq(b_rows[1].linger, true, "the one B row is the dim+linger copy")
  eq(b_rows[1].dim, true, "the one B row is dimmed")
end

-- ── FIX 2: linger under a PRESENT-but-EMPTY named group surfaces as a ghost ───
-- A group name can be present in query_result.groups yet produce ZERO tree_rows
-- (named group with no matching tasks).  Tree-mode ghost detection must derive
-- from the names that actually rendered live bodies (ordered_live_groups), not
-- from query_result.groups — otherwise a linger bucketed under that empty name is
-- neither spliced nor ghosted and silently vanishes.

T["fix2: tree linger under a present-but-empty NAMED group renders as a ghost group"] = function()
  local linger_ts = { line = "- [x] done in empty grp", src_line = 7 }

  -- query_result.groups CONTAINS the name "emptygrp" (present), but tree_rows is
  -- empty (no matching tasks produced a live body for it).
  local res = {
    groups = { { name = "emptygrp", tasks = {} } },
    total = 0,
    hide_flags = { backlinks = true },
    header_summary = "",
    errors = {},
    tree_rows = {},
  }

  local ent = {
    task = pt(linger_ts.line, "/v/a.md", linger_ts.src_line),
    src_path = "/v/a.md",
    src_line = linger_ts.src_line,
    prior_group_name = "emptygrp",
    prior_index_within_group = 0,
    linger_subtree = tree_linger_subtree(linger_ts, "emptygrp", 0),
  }

  local rendered = layout_mod.layout(res, { lingers = { ent }, group_by = {} })
  local saw_header, saw_linger = false, false
  for i, l in ipairs(rendered) do
    if l.kind == "group_header" and l.text == "## emptygrp" then
      saw_header = true
      for j = i + 1, #rendered do
        if rendered[j].kind == "task" then
          eq(rendered[j].linger, true, "tree: present-but-empty group linger row")
          saw_linger = true
          break
        end
      end
    end
  end
  eq(saw_header, true, "tree: present-but-empty named group still gets a ghost header")
  eq(saw_linger, true, "tree: the linger under the present-but-empty group still renders")
end

return T
