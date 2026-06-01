-- tests/integration/test_harden_foldtext.lua
-- Hardening: foldtext counting (integration, stubbed index).
--
-- Drives REAL `show tree` renders through a stubbed index/nodes layer (mirrors
-- tests/integration/test_tree_render.lua) and asserts the EXACT subtree foldtext
-- string "{indent}▸ T child item(s) · N/M done" produced over the hidden
-- descendant rows.  Covers the foldtext exploration's integration cases:
--   • grandchild rows increment T (and M when lit)
--   • blank rows are excluded from T
--   • dim breadcrumb connector ancestors never enter a child fold's count
--   • dim_completed_tasks false → done child counts toward M/N; true → excluded
--   • staleness: counts are rebuilt every render, never linger
--   • flat → tree and tree → flat transitions install/clear foldinfo
--   • a task in multiple `group by` groups counts independently per fold
--
-- No product code is modified; new file only.

-- post_case closes every window the case opened EVEN WHEN AN ASSERTION THREW
-- before its inline teardown ran.  Without this a failing `eq` leaks the split,
-- and after a handful of cases later split-based tests hit E36 (not enough room).
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      local wins = vim.api.nvim_tabpage_list_wins(0)
      for i = 2, #wins do
        pcall(vim.api.nvim_win_close, wins[i], true)
      end
    end,
  },
})

local eq = MiniTest.expect.equality

local render = require("obsidian-tasks.render.init")
local nodes_mod = require("obsidian-tasks.index.nodes")
local task_parse = require("obsidian-tasks.task.parse")
local folds = require("obsidian-tasks.render.folds")

local SRC_PATH = "/vault/harden_foldtext.md"

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function open_in_win(bufnr)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

local function close_win(winid)
  pcall(vim.api.nvim_win_close, winid, true)
end

--- Single-file subtree stub.  `lines` is the source; the matched left-most tasks
--- are the (1-indexed) source lines in `matched_lines` (the first is the root).
--- Under D2 a descendant is LIT (and so counts toward foldtext's M) only when it
--- INDEPENDENTLY matches its group — so a test that wants its child tasks counted
--- must list them here, not just the root.  `matched_lines` may be a single
--- integer for the root-only case.  Returns a restore fn.  Mirrors
--- stub_index_lines in test_tree_render.lua.
local function stub_index_lines(lines, matched_lines)
  if type(matched_lines) == "number" then
    matched_lines = { matched_lines }
  end
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local ns = nodes_mod.parse_lines(lines)
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    return (p == SRC_PATH) and ns or {}
  end
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      local ln = matched_lines[i]
      if ln then
        return task_parse.parse(lines[ln]), SRC_PATH, ln
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
  end
end

--- Close the first subtree child fold and return its foldtextresult.  The root
--- sits at dashboard row 4 (after the 3-row fence), so the first child is row 5.
--- Matches test_tree_render.lua's subtree_foldtext helper.
local function subtree_foldtext_at(winid, first_child_row)
  first_child_row = first_child_row or 5
  local ft
  vim.api.nvim_win_call(winid, function()
    vim.cmd(first_child_row .. "foldclose")
    ft = vim.fn.foldtextresult(first_child_row)
  end)
  return ft
end

local function teardown(bufnr, winid, saved_opts, restore)
  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── grandchild-T-count: 3 levels deep, all lit ───────────────────────────────

T["grandchild rows increment T and (lit) M"] = function()
  -- root → child → grandchild, all tasks, all matched/lit.  The CHILDREN-ONLY
  -- fold of the root hides child + grandchild (2 rows).  Both are lit tasks:
  --   T (items) = 2, M (tasks_total) = 2, N (tasks_done) = 0.
  local lines = {
    "- [ ] Root task",
    "  - [ ] Child task",
    "    - [ ] Grandchild task",
  }
  -- D2: child + grandchild must independently match to stay LIT and count in M.
  local restore = stub_index_lines(lines, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext_at(winid, 5)
  eq(ft, "  ▸ 2 child items · 0/2 done", "grandchild contributes to T and M: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── blank-row-not-counted-in-T ────────────────────────────────────────────────

T["blank descendant rows are excluded from T"] = function()
  -- root with: task, bullet, blank, task descendants.  T counts non-blank rows
  -- only → 3 (2 tasks + 1 bullet), NOT 4.  M = 2 lit tasks, N = 0.
  local lines = {
    "- [ ] Root task",
    "  - [ ] Child task",
    "  - a description",
    "",
    "  - [ ] Second child",
  }
  -- D2: the two child tasks (2, 5) must independently match to stay LIT.  The
  -- bullet (3) and blank (4) are never matched (context).
  local restore = stub_index_lines(lines, { 1, 2, 5 })
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext_at(winid, 5)
  eq(ft, "  ▸ 3 child items · 0/2 done", "blank row must not increment T: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── connector-sentinel-rows-counted-in-T ──────────────────────────────────────

T["dim ancestor breadcrumbs are NOT counted in the matched subtree fold"] = function()
  -- A DEEP matched leaf with 2 lit descendants.  Dim breadcrumb ancestors
  -- (grandparent, parent) are fold_group==0 and sit ABOVE the matched root, so
  -- the children-only fold of the matched leaf must count ONLY its 2 lit
  -- descendants — never the connector/breadcrumb rows.
  --   T = 2 (two lit leaf notes), M = 0 (both bullets, not tasks), N = 0.
  local lines = {
    "- [ ] Grandparent",
    "  - [ ] Parent",
    "    - [ ] Matched leaf",
    "      - a leaf note",
    "      - another leaf note",
  }
  local restore = stub_index_lines(lines, 3)
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Dashboard rows 1-3 fence; 4 grandparent (dim), 5 parent (dim), 6 matched
  -- leaf (lit ROOT), 7/8 lit leaf notes.  The children-only fold starts at 7.
  local ft
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    vim.cmd("7foldclose")
    ft = vim.fn.foldtextresult(7)
  end)
  -- Two bullet descendants, no descendant tasks → M==0 drops the done clause and
  -- the breadcrumbs (rows 4/5) are NOT folded in, so T==2 not 4.
  eq(ft, "      ▸ 2 child items", "breadcrumbs excluded; only lit descendants counted: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── dim-context-tasks-excluded-from-M (open) ──────────────────────────────────

T["a lit grandchild counts toward the matched leaf fold, not the dim parent"] = function()
  -- OPEN: the matched leaf is at depth 2 with dim breadcrumb ancestors above it.
  -- A lit grandchild TASK below the matched leaf must count toward the matched
  -- leaf's fold M (it is lit, tree_kind=='task', not dim) — NOT silently dropped
  -- because of an ancestor's dimness.  The dim breadcrumbs are fold_group==0 and
  -- never form a fold of their own.
  --   matched-leaf fold hides: child-of-leaf (lit task) + grandchild (lit task).
  --   T = 2, M = 2, N = 0.
  local lines = {
    "- [ ] Grandparent",
    "  - [ ] Parent",
    "    - [ ] Matched leaf",
    "      - [ ] Leaf child",
    "        - [ ] Leaf grandchild",
  }
  -- D2: the matched leaf (3) is the root; its descendant tasks (4, 5) must
  -- independently match to count toward M.
  local restore = stub_index_lines(lines, { 3, 4, 5 })
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    vim.cmd("7foldclose")
    ft = vim.fn.foldtextresult(7)
  end)
  eq(ft, "      ▸ 2 child items · 0/2 done", "lit descendants of matched leaf count toward M: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── dim-completed-tasks-false-done-task-lit ───────────────────────────────────

T["dim_completed=false: a done child stays lit and counts toward M and N"] = function()
  -- root → done child + todo child + bullet.  dim_completed_tasks=false keeps the
  -- [x] child LIT (meta.dim nil), so it counts toward M and (being done) N.
  --   T = 3 (2 tasks + 1 bullet), M = 2, N = 1.
  local lines = {
    "- [ ] Root task",
    "  - [x] Done child",
    "  - [ ] Todo child",
    "  - a description",
  }
  -- D2: both child tasks (2 done, 3 todo) must independently match; the bullet
  -- (4) is context.  dim_completed=false keeps the [x] child LIT → M=2, N=1.
  local restore = stub_index_lines(lines, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true, dim_completed_tasks = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext_at(winid, 5)
  eq(ft, "  ▸ 3 child items · 1/2 done", "lit done child counts toward M and N: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── dim-completed-tasks-true-done-task-dimmed ─────────────────────────────────

T["dim_completed=true: a done child is dimmed and excluded from M and N"] = function()
  -- Same subtree, dim_completed_tasks=true → the [x] child renders DIMMED
  -- (meta.dim true), so it is excluded from M entirely (and therefore N).
  --   T = 3 (still counts the dimmed task as a non-blank row), M = 1 (only the
  --   todo child), N = 0.
  local lines = {
    "- [ ] Root task",
    "  - [x] Done child",
    "  - [ ] Todo child",
    "  - a description",
  }
  -- D2: both child tasks (2 done, 3 todo) independently match.  dim_completed=true
  -- then DIMS the [x] done child, excluding it from M → M=1 (todo only), N=0.
  local restore = stub_index_lines(lines, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true, dim_completed_tasks = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext_at(winid, 5)
  -- The dimmed done task still counts as an item (T) but not a matched task (M).
  eq(ft, "  ▸ 3 child items · 0/1 done", "dimmed done child excluded from M/N: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── ON_HOLD / IN_PROGRESS descendants do not count toward N ────────────────────

T["ON_HOLD [h] and IN_PROGRESS [/] descendants count toward M but not N"] = function()
  -- root → on-hold child + in-progress child.  Both are lit pending tasks: M=2,
  -- but neither is Done/Cancelled so N=0.
  local lines = {
    "- [ ] Root task",
    "  - [h] On hold child",
    "  - [/] In progress child",
  }
  -- D2: both child tasks (2, 3) must independently match to count toward M.
  local restore = stub_index_lines(lines, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext_at(winid, 5)
  eq(ft, "  ▸ 2 child items · 0/2 done", "[h]/[/] count toward M, not N: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── CANCELLED [-] descendant counts toward N (done) ───────────────────────────

T["CANCELLED [-] descendant counts toward N"] = function()
  -- root → cancelled child + todo child.  dim_completed=false keeps the [-]
  -- child lit; CANCELLED is a terminal/done type so N includes it.
  --   M = 2, N = 1.
  local lines = {
    "- [ ] Root task",
    "  - [-] Cancelled child",
    "  - [ ] Todo child",
  }
  -- D2: both child tasks (2, 3) must independently match to count toward M.
  local restore = stub_index_lines(lines, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true, dim_completed_tasks = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext_at(winid, 5)
  eq(ft, "  ▸ 2 child items · 1/2 done", "cancelled child counts toward N: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── staleness-across-consecutive-rerenders ────────────────────────────────────

T["counts are rebuilt every render (no stale foldinfo lingers)"] = function()
  -- Render A: root + done child + todo child (dim_completed=false) → "1/2 done".
  -- Mutate the source so the previously-done child becomes TODO, render B →
  -- "0/2 done".  The foldinfo must reflect render B's counts, never render A's.
  local lines_a = {
    "- [ ] Root task",
    "  - [x] Done child",
    "  - [ ] Todo child",
  }
  -- D2: both child tasks (2, 3) independently match so they stay LIT in M.
  local restore = stub_index_lines(lines_a, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true, dim_completed_tasks = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft_a = subtree_foldtext_at(winid, 5)
  eq(ft_a, "  ▸ 2 child items · 1/2 done", "render A: [" .. ft_a .. "]")

  -- Swap the stub so the child is now TODO, then re-render the same buffer.
  restore()
  local lines_b = {
    "- [ ] Root task",
    "  - [ ] Was done child",
    "  - [ ] Todo child",
  }
  restore = stub_index_lines(lines_b, { 1, 2, 3 })
  render.render_buffer(bufnr, nil)

  local ft_b = subtree_foldtext_at(winid, 5)
  eq(ft_b, "  ▸ 2 child items · 0/2 done", "render B must not show stale 1/2: [" .. ft_b .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── flat-to-tree-transition-foldinfo-replaced ─────────────────────────────────

T["flat → tree transition installs fresh foldinfo"] = function()
  -- First render FLAT (no show tree) → no subtree foldinfo for this buffer.
  -- Then render TREE → foldinfo is installed with the subtree counts.
  local lines = {
    "- [ ] Root task",
    "  - [ ] Child task",
    "  - [ ] Second child",
  }
  -- D2: both child tasks (2, 3) independently match so they count toward M.
  local restore = stub_index_lines(lines, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  -- FLAT first.
  local bufnr = make_buf({ "```tasks", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)
  eq(folds._foldinfo[bufnr], nil, "flat render must leave no subtree foldinfo")

  -- Now switch the same buffer to a TREE block and re-render.  clear_buffer
  -- detaches the edit-through on_lines listener the flat render attached; without
  -- it the raw nvim_buf_set_lines swap below fires the MUTATE/DELETE edit pipeline
  -- on a stub (file-less) buffer and corrupts it.  This isolates the render
  -- transition we actually mean to test (flat foldinfo absent → tree present).
  render.clear_buffer(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "show tree", "```" })
  render.render_buffer(bufnr, nil)
  eq(folds._foldinfo[bufnr] ~= nil, true, "tree render must install subtree foldinfo")
  local ft = subtree_foldtext_at(winid, 5)
  eq(ft, "  ▸ 2 child items · 0/2 done", "fresh tree counts after flat→tree: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── tree-to-flat-transition-foldinfo-cleared ──────────────────────────────────

T["tree → flat transition clears the buffer's foldinfo"] = function()
  -- TREE first (foldinfo present), then FLAT re-render must clear it so the
  -- fence falls back to the legacy foldtext (no stale subtree counts linger).
  local lines = {
    "- [ ] Root task",
    "  - [ ] Child task",
    "  - [ ] Second child",
  }
  local restore = stub_index_lines(lines, 1)
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)
  eq(folds._foldinfo[bufnr] ~= nil, true, "tree render installs foldinfo")

  -- Switch the block to FLAT (drop `show tree`) and re-render.  clear_buffer
  -- first to detach the edit listener (see flat→tree note) so the raw line swap
  -- does not fire the edit pipeline on this stub buffer.
  render.clear_buffer(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "```" })
  render.render_buffer(bufnr, nil)
  eq(folds._foldinfo[bufnr], nil, "flat re-render must clear stale subtree foldinfo")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── tree-to-flat-transition-fence-foldtext-unchanged ──────────────────────────

T["fence/query fold keeps the legacy 'first line ▸ N' format under a tree block"] = function()
  -- A tree render creates a fence fold + subtree folds.  The fence fold is NOT a
  -- subtree (no foldinfo entry for its foldstart), so its foldtext stays the
  -- legacy "first line  ▸ N" (here the ```tasks line + 2 hidden non-blank rows).
  local lines = {
    "- [ ] Root task",
    "  - [ ] Child task",
    "  - [ ] Second child",
  }
  local restore = stub_index_lines(lines, 1)
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft
  vim.api.nvim_win_call(winid, function()
    ft = vim.fn.foldtextresult(1)
  end)
  eq(ft, "```tasks  ▸ 2", "fence foldtext must keep legacy format: [" .. ft .. "]")

  teardown(bufnr, winid, saved_opts, restore)
end

-- ── multi-group-task-same-row-multiple-folds (open) ───────────────────────────

T["a task in two groups counts independently in each group's fold"] = function()
  -- OPEN: `group by tags` over one source root carrying #alpha and #beta renders
  -- the root (and its subtree) under BOTH groups.  Each group's subtree gets a
  -- distinct fold_group, so the SAME task contributes to each fold independently
  -- (counted once per fold, not double-counted within one fold).
  --
  -- Each group renders: root (#alpha #beta), child, second child.  D2: a
  -- descendant is LIT in a group only when it INDEPENDENTLY matches that group, so
  -- the children carry #alpha #beta too and are yielded by tasks_in — that places
  -- them in BOTH the #alpha and #beta matched sets, keeping them lit under each
  -- group's root drag.  Each group's children-only fold then hides 2 lit task rows
  -- → "2 child items · 0/2 done" for EACH group's fold (counted once per fold).
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local src = {
    "- [ ] Root task #alpha #beta",
    "  - [ ] Child task #alpha #beta",
    "  - [ ] Second child #alpha #beta",
  }
  local ns = nodes_mod.parse_lines(src)
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    return (p == SRC_PATH) and ns or {}
  end
  index_mod.tasks_in = function(_)
    -- Yield all three rows so each lands in BOTH tag groups; the children are
    -- suppressed as standalone roots (matched ancestor in-group) and ride lit in
    -- the root's drag, but their (path,line) is in the group's matched set → lit.
    local emit = { { task_parse.parse(src[1]), 1 }, { task_parse.parse(src[2]), 2 }, { task_parse.parse(src[3]), 3 } }
    local i = 0
    return function()
      i = i + 1
      if emit[i] then
        return emit[i][1], SRC_PATH, emit[i][2]
      end
    end
  end
  local restore = function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
  end

  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "group by tags", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Locate every subtree child-fold start (a row whose foldstart matches a
  -- foldinfo entry) and read each fold's foldtext.  There must be TWO subtree
  -- folds (one per group), each summarising the SAME 2 lit descendant tasks.
  local info = folds._foldinfo[bufnr] or {}
  local fold_starts = {}
  for fs in pairs(info) do
    fold_starts[#fold_starts + 1] = fs
  end
  table.sort(fold_starts)
  eq(#fold_starts, 2, "the multi-group task must yield two independent subtree folds")

  local texts = {}
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    for _, fs in ipairs(fold_starts) do
      vim.cmd(fs .. "foldclose")
      texts[#texts + 1] = vim.fn.foldtextresult(fs)
    end
  end)
  for _, ft in ipairs(texts) do
    eq(ft, "  ▸ 2 child items · 0/2 done", "each group fold counts the subtree independently: [" .. ft .. "]")
  end

  teardown(bufnr, winid, saved_opts, restore)
end

return T
