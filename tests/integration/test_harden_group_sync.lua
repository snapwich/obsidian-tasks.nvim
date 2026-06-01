-- tests/integration/test_harden_group_sync.lua
-- HARDENING (dimension: group_sync) — grouping / duplicates / live-sync /
-- filtering interactions that are best exercised at the render/query state level
-- (no real keypresses needed).  Mirrors test_linger.lua + test_tree_render.lua
-- stubbing conventions (swap index.tasks_in / nodes_for, restore afterward).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local render = require("obsidian-tasks.render.init")
local query_run = require("obsidian-tasks.query.run")
local query_parse = require("obsidian-tasks.query.parse")
local nodes_mod = require("obsidian-tasks.index.nodes")
local task_parse = require("obsidian-tasks.task.parse")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function make_task(line, path, line_nr)
  local t = task_parse.parse(line)
  assert(t, "expected parseable task: " .. line)
  return { task = t, path = path, line_nr = line_nr }
end

--- Install a swappable index stub.  `set_tasks({ {task,path,line}, ... })` swaps
--- the flat task view; `set_nodes(path, lines)` registers a per-file node model
--- for nodes_for (tree assembly).  Returns set_tasks, set_nodes, restore.
local function install_stub()
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
    reverse = index_mod.reverse_index,
  }
  local current = {}
  local node_models = {}

  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.reverse_index = function()
    return {}
  end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    return node_models[p] or {}
  end
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      local row = current[i]
      if not row then
        return nil
      end
      return row.task, row.path, row.line_nr
    end
  end

  local set_tasks = function(rows)
    current = rows
  end
  local set_nodes = function(path, lines)
    node_models[path] = nodes_mod.parse_lines(lines)
  end
  local restore = function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
    index_mod.reverse_index = saved.reverse
  end
  return set_tasks, set_nodes, restore
end

--- All distinct group_name strings present in a buffer's render state.
local function distinct_groups(bufnr)
  local state = render._buffer_state[bufnr] or {}
  local seen, out = {}, {}
  for _, blk in ipairs(state) do
    for _, m in pairs(blk.line_map or {}) do
      if m.group_name and not seen[m.group_name] then
        seen[m.group_name] = true
        out[#out + 1] = m.group_name
      end
    end
  end
  table.sort(out)
  return out
end

local function count_linger_lines(bufnr)
  local state = render._buffer_state[bufnr] or {}
  local n = 0
  for _, blk in ipairs(state) do
    for _, meta in pairs(blk.line_map or {}) do
      if meta.linger then
        n = n + 1
      end
    end
  end
  return n
end

--- Count managed rows whose src_line == line_nr (across all blocks).
local function rows_for_src_line(bufnr, line_nr)
  local state = render._buffer_state[bufnr] or {}
  local n = 0
  for _, blk in ipairs(state) do
    for _, meta in pairs(blk.line_map or {}) do
      if meta.src_line == line_nr then
        n = n + 1
      end
    end
  end
  return n
end

local function cleanup(bufnr, restore)
  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
  pcall(render.clear_buffer, bufnr)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  restore()
end

-- ── filter-out-live-exit-during-edit on a GROUPED dashboard (OPEN) ─────────────
-- A `not done` + `group by tags` dashboard.  A task is toggled Done (leaves the
-- filter).  With linger_on_filter_exit=true the row should linger dimmed through
-- the grouped re-query rather than being clobbered by the fresh group structure.

T["grouped filter-exit: a toggled-done task lingers through a grouped re-query"] = function()
  render.configure({ default_folded = false, linger_on_filter_exit = true, dim_completed_tasks = true })
  local set_tasks, _, restore = install_stub()

  set_tasks({ make_task("- [ ] grp task #alpha", "/vault/a.md", 1) })
  local bufnr = make_buf({ "```tasks", "not done", "group by tags", "```" })
  render.render_buffer(bufnr, nil)

  -- Toggle Done → record pending linger; task leaves the `not done` filter set.
  render._record_pending_linger(bufnr, "/vault/a.md", 1, nil, task_parse.parse("- [x] grp task #alpha"))
  set_tasks({})
  render.rerender_buffer(bufnr, nil)

  -- Best-guess expected: the row lingers (one promoted linger entry, one dim row)
  -- even though the grouped structure was rebuilt empty.
  eq(#(render._lingers[bufnr] or {}), 1, "the filter-exited task lingers under grouping")
  eq(count_linger_lines(bufnr), 1, "exactly one lingered row survives the grouped re-query")

  cleanup(bufnr, restore)
end

-- ── linger drops when task re-enters via a grouped re-query (OPEN) ─────────────
-- Companion to the above: un-toggling restores the task into the live grouped set
-- and the linger must drop (no stale ghost left behind by the group rebuild).

T["grouped filter-exit: re-entering the live set drops the linger (no group ghost)"] = function()
  render.configure({ default_folded = false, linger_on_filter_exit = true, dim_completed_tasks = true })
  local set_tasks, _, restore = install_stub()

  set_tasks({ make_task("- [ ] grp task #alpha", "/vault/a.md", 1) })
  local bufnr = make_buf({ "```tasks", "not done", "group by tags", "```" })
  render.render_buffer(bufnr, nil)

  render._record_pending_linger(bufnr, "/vault/a.md", 1, nil, task_parse.parse("- [x] grp task #alpha"))
  set_tasks({})
  render.rerender_buffer(bufnr, nil)
  eq(#(render._lingers[bufnr] or {}), 1, "lingered after exit")

  -- Un-toggle in source: task re-enters the `not done` grouped set.
  set_tasks({ make_task("- [ ] grp task #alpha", "/vault/a.md", 1) })
  render.rerender_buffer(bufnr, nil)
  eq(render._lingers[bufnr], nil, "linger dropped once the task re-enters the grouped live set")
  eq(count_linger_lines(bufnr), 0, "no ghost row remains")

  cleanup(bufnr, restore)
end

-- ── group-header-virt-line-sync: empty group's header vanishes on rerender ─────
-- (INTUITIVE / hardening) Two singleton tag groups; the source for one group is
-- removed; a rerender must drop that group entirely (no stale header/rows).

T["group-header sync: a group that loses its only task is removed on rerender"] = function()
  render.configure({ default_folded = false })
  local set_tasks, _, restore = install_stub()

  set_tasks({
    make_task("- [ ] a one #alpha", "/vault/a.md", 1),
    make_task("- [ ] b one #beta", "/vault/b.md", 1),
  })
  local bufnr = make_buf({ "```tasks", "group by tags", "```" })
  render.render_buffer(bufnr, nil)

  local g0 = distinct_groups(bufnr)
  eq(vim.tbl_contains(g0, "#alpha"), true, "#alpha present initially: " .. vim.inspect(g0))
  eq(vim.tbl_contains(g0, "#beta"), true, "#beta present initially: " .. vim.inspect(g0))

  -- Drop the #alpha task entirely from the index, rerender.
  set_tasks({ make_task("- [ ] b one #beta", "/vault/b.md", 1) })
  render.rerender_buffer(bufnr, nil)

  local g1 = distinct_groups(bufnr)
  eq(vim.tbl_contains(g1, "#alpha"), false, "#alpha group removed when its only task leaves: " .. vim.inspect(g1))
  eq(vim.tbl_contains(g1, "#beta"), true, "#beta group survives: " .. vim.inspect(g1))

  cleanup(bufnr, restore)
end

-- ── filter-and-group-edit-creates-new-group (INTUITIVE / hardening) ────────────
-- `not done` + `group by tags`.  The task gains a brand-new tag (still not done);
-- a rerender must surface the new group with the task in it.

T["filter+group: a new tag (still matching the filter) creates its group on rerender"] = function()
  render.configure({ default_folded = false })
  local set_tasks, _, restore = install_stub()

  set_tasks({ make_task("- [ ] solo #alpha", "/vault/a.md", 1) })
  local bufnr = make_buf({ "```tasks", "not done", "group by tags", "```" })
  render.render_buffer(bufnr, nil)
  eq(vim.tbl_contains(distinct_groups(bufnr), "#alpha"), true, "starts under #alpha")

  -- Source now carries #new too; still not done so the filter still matches.
  set_tasks({ make_task("- [ ] solo #alpha #new", "/vault/a.md", 1) })
  render.rerender_buffer(bufnr, nil)

  local g1 = distinct_groups(bufnr)
  eq(vim.tbl_contains(g1, "#new"), true, "the brand-new group appears: " .. vim.inspect(g1))
  eq(vim.tbl_contains(g1, "#alpha"), true, "the original group survives: " .. vim.inspect(g1))
  eq(rows_for_src_line(bufnr, 1), 2, "the one task now renders under BOTH tag groups")

  cleanup(bufnr, restore)
end

-- ── nested-dup-across-files: tree nesting does NOT cross files (OPEN) ───────────
-- File A has a Parent #task; File B has a "Child" #task.  Even grouped together,
-- the tree assembly is file-scoped: B's task can NOT become a descendant of A's
-- task — each renders as its own root.

T["cross-file: tree nesting is file-scoped — no cross-file parent/child linkage"] = function()
  render.configure({ default_folded = false })
  local set_tasks, set_nodes, restore = install_stub()

  -- Two SEPARATE files; B's task is indented but parses in its OWN file only.
  set_nodes("/vault/A.md", { "- [ ] Parent #task" })
  set_nodes("/vault/B.md", { "  - [ ] Child #task" })
  set_tasks({
    make_task("- [ ] Parent #task", "/vault/A.md", 1),
    make_task("  - [ ] Child #task", "/vault/B.md", 1),
  })

  local ast = query_parse.parse("show tree")
  local result = query_run.run(ast, require("obsidian-tasks.index"), nil)

  -- Both matched tasks are independent ROOTS (each its own fold_group); neither is
  -- a descendant of the other (no cross-file linkage).
  eq(result.tree_rows ~= nil, true, "tree_rows assembled")
  local parent_row, child_row
  for _, r in ipairs(result.tree_rows) do
    if r.kind == "task" and r.matched and r.src_path == "/vault/A.md" then
      parent_row = r
    elseif r.kind == "task" and r.matched and r.src_path == "/vault/B.md" then
      child_row = r
    end
  end
  eq(parent_row ~= nil, true, "Parent (file A) is a matched row")
  eq(child_row ~= nil, true, "Child (file B) is a matched row")
  -- Both are roots at depth 0 in their own induced forest — distinct fold groups.
  eq(parent_row.depth, 0, "Parent is a root (depth 0)")
  eq(child_row.depth, 0, "Child is its OWN root (depth 0), not nested under A's Parent")
  eq(parent_row.fold_group ~= child_row.fold_group, true, "separate files → separate fold groups")
  -- Footer count: both matched tasks count (two independent roots).
  eq(result.total, 2, "both file roots count toward the result total")

  restore()
end

return T
