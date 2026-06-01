-- tests/integration/test_tree_render.lua
-- Phase 4 integration: `show tree` render + native folding.
--
-- Covers:
--   • query/run.lua wiring: ast.tree routes matched groups through
--     tree.assemble(groups, index.nodes_for); ast.tree=false does NOT.
--   • render/init.lua: tree rows render as nested, indented buffer lines.
--   • render/folds.lua: one manual fold per subtree fold_group, nested below
--     the fence fold; default expanded; foldcolumn on; foldtext indicator.
--   • read-only bullet rows: edit reverts, no source write, no INSERT misfire.
--
-- Runs in headless Neovim (window + fold APIs available).

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

local function open_in_win(bufnr)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

local function close_win(winid)
  pcall(vim.api.nvim_win_close, winid, true)
end

-- A two-file-free single-file subtree:
--   1  - [ ] Root task        (matched root, depth 0)
--   2    - [ ] Child task     (depth 1)
--   3    - a description      (bullet, depth 1)
--   4                          (blank)
--   5    - [ ] Second child   (depth 1)
local SRC_PATH = "/vault/tree.md"
local SRC_LINES = {
  "- [ ] Root task",
  "  - [ ] Child task",
  "  - a description",
  "",
  "  - [ ] Second child",
}

--- Install index stubs returning the subtree above.  Returns a restore fn.
---
--- Fetches the LIVE index module via require (not the file-load reference): an
--- earlier test may have swapped package.loaded["obsidian-tasks.index"] for a
--- mock and restored a DIFFERENT table instance, so we must stub whatever
--- require returns now — the same instance query_run.run / render will use.
local function stub_index()
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local ns = nodes_mod.parse_lines(SRC_LINES)

  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  -- Prevent the lazy vault walk from clobbering the stub.
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    if p == SRC_PATH then
      return ns
    end
    return {}
  end
  -- Only the matched ROOT is in the flat task view (matched left-most task).
  index_mod.tasks_in = function(_)
    local root = task_parse.parse(SRC_LINES[1])
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return root, SRC_PATH, 1
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

--- Variant: BOTH the root (line 1) and child (line 2) are matched left-most
--- tasks.  Used to prove dedup — the child must appear ONCE (nested under the
--- root), not also standalone.  Returns a restore fn.
local function stub_index_both()
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local ns = nodes_mod.parse_lines(SRC_LINES)
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
    local root = task_parse.parse(SRC_LINES[1])
    local child = task_parse.parse(SRC_LINES[2])
    local seq = { { root, SRC_PATH, 1 }, { child, SRC_PATH, 2 } }
    local i = 0
    return function()
      i = i + 1
      local e = seq[i]
      if e then
        return e[1], e[2], e[3]
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

-- A deep subtree where ONLY a nested grandchild matches the filter:
--   1  - [ ] Grandparent        (NOT matched → DIM breadcrumb, depth 0)
--   2    - [ ] Parent           (NOT matched → DIM breadcrumb, depth 1)
--   3      - [ ] Matched leaf    (matched ROOT, true depth 2 — NOT re-rooted)
--   4        - a leaf note       (lit descendant bullet, depth 3)
local DEEP_LINES = {
  "- [ ] Grandparent",
  "  - [ ] Parent",
  "    - [ ] Matched leaf",
  "      - a leaf note",
}

--- Stub the index so the matched left-most task is the DEEP grandchild (line 3),
--- exercising the induced-forest DIM-ancestor path.  Returns a restore fn.
local function stub_index_deep()
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local ns = nodes_mod.parse_lines(DEEP_LINES)
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
    local leaf = task_parse.parse(DEEP_LINES[3])
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return leaf, SRC_PATH, 3
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

-- Forward-declared so the foldtext-indicator test above the definitions can use
-- it; the body is assigned below in the "subtree foldtext" section.
local stub_index_lines

-- ── run.lua wiring ────────────────────────────────────────────────────────────

T["run: ast.tree=true populates tree_rows via assemble"] = function()
  local restore = stub_index()
  local ast = query_parse.parse("show tree")
  local result = query_run.run(ast, require("obsidian-tasks.index"), nil)
  -- tree_rows present and contains the whole subtree (root + 2 tasks + bullet + blank).
  eq(result.tree_rows ~= nil, true)
  local kinds = {}
  for _, r in ipairs(result.tree_rows) do
    kinds[#kinds + 1] = r.kind
  end
  -- Root, child, bullet, blank, second child = 5 rows, all one fold_group.
  eq(#result.tree_rows, 5)
  eq(result.tree_rows[1].kind, "task")
  eq(result.tree_rows[1].matched, true)
  eq(result.tree_rows[2].kind, "task")
  eq(result.tree_rows[3].kind, "bullet")
  eq(result.tree_rows[4].kind, "blank")
  eq(result.tree_rows[5].kind, "task")
  -- Single subtree → single fold_group across all rows.
  for _, r in ipairs(result.tree_rows) do
    eq(r.fold_group, 1)
  end
  restore()
end

T["run: ast.tree=false leaves tree_rows nil (flat path unchanged)"] = function()
  local restore = stub_index()
  local ast = query_parse.parse("") -- no `show tree`
  eq(ast.tree, false)
  local result = query_run.run(ast, require("obsidian-tasks.index"), nil)
  eq(result.tree_rows, nil)
  -- Flat result still yields exactly the one matched task.
  eq(result.total, 1)
  restore()
end

T["run: dedup — a matched child appears once (nested), not standalone"] = function()
  local restore = stub_index_both()
  local ast = query_parse.parse("show tree")
  local result = query_run.run(ast, require("obsidian-tasks.index"), nil)
  -- Count how many rows reference the child's source line (line 2).
  local child_rows = 0
  local root_rows = 0
  for _, r in ipairs(result.tree_rows) do
    if r.src_line == 2 and r.kind == "task" then
      child_rows = child_rows + 1
    elseif r.src_line == 1 and r.kind == "task" then
      root_rows = root_rows + 1
    end
  end
  -- One source line ⇒ at most one row within the group: the child appears once
  -- (nested under the root), NOT also as a standalone root.
  eq(child_rows, 1)
  eq(root_rows, 1)
  -- All rows share the single root subtree's fold_group (child nested in it).
  eq(result.tree_rows[1].fold_group, result.tree_rows[2].fold_group)
  restore()
end

-- ── render path ──────────────────────────────────────────────────────────────

T["render: show tree inserts nested, indented rows"] = function()
  local restore = stub_index()
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- After the fence (rows 1-3) come the rendered subtree rows.
  -- Backlink suffix is appended; assert on the prefix only.
  eq(lines[4]:sub(1, #"- [ ] Root task"), "- [ ] Root task")
  eq(lines[5]:sub(1, #"  - [ ] Child task"), "  - [ ] Child task")
  eq(lines[6]:sub(1, #"  - a description"), "  - a description")
  eq(lines[7], "") -- blank row
  eq(lines[8]:sub(1, #"  - [ ] Second child"), "  - [ ] Second child")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["render: one subtree fold created, nested below the fence fold, default expanded"] = function()
  local restore = stub_index()
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Subtree rows are at 1-indexed lines 4..8 (root=4, children 5..8).  The fold is
  -- CHILDREN-ONLY: it spans lines 5..8 and EXCLUDES the root (4), so the root stays
  -- visible + editable and its group-header virt line is never hidden.
  local fence_fc, root_foldlevel, child_start_fc, child_foldlevel
  vim.api.nvim_win_call(winid, function()
    fence_fc = vim.fn.foldclosed(1) -- fence (query) fold: closed by default_folded
    -- The root row (4) is NOT in any subtree fold.
    root_foldlevel = vim.fn.foldlevel(4)
    -- The children fold exists across rows 5..8; it is OPEN by default, so
    -- foldclosed on its first row returns -1 but foldlevel is > 0.
    child_start_fc = vim.fn.foldclosed(5)
    child_foldlevel = vim.fn.foldlevel(5)
  end)
  eq(fence_fc, 1) -- fence fold is closed
  eq(root_foldlevel, 0) -- root row is OUTSIDE the subtree fold (children-only)
  eq(child_start_fc, -1) -- children fold is OPEN (expanded) by default
  eq(child_foldlevel >= 1, true) -- but a fold DOES exist over the children rows

  -- Closing the children fold then querying foldclosed proves the fold is real.
  local closed_after
  vim.api.nvim_win_call(winid, function()
    vim.cmd("5foldclose")
    closed_after = vim.fn.foldclosed(5)
  end)
  eq(closed_after, 5) -- children fold closes at its first row (first child)

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["rerender: a closed subtree fold survives a source insert above the block"] = function()
  -- Regression (MAJOR-2): rerender_buffer used to capture subtree fold state at
  -- the STALE prior-render root row.  When source lines are inserted above the
  -- block between renders, the live rendered rows shift, so reading the fold
  -- state at the stale row mis-captured a user-CLOSED subtree as open and it
  -- re-opened.  The fence fold state must survive the same shift.
  local restore = stub_index()
  local saved_opts = render._opts
  -- Fence OPEN by default so we can independently assert it stays open while the
  -- subtree stays closed (no fence-fold default masking the subtree result).
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)
  -- Expand all folds first (default_folded=false leaves the fence open already).
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
  end)

  -- Root subtree row is 1-indexed line 4; its CHILDREN fold starts at line 5.
  -- Close the children fold.
  vim.api.nvim_win_call(winid, function()
    vim.cmd("5foldclose")
  end)
  local closed_before
  vim.api.nvim_win_call(winid, function()
    closed_before = vim.fn.foldclosed(5)
  end)
  eq(closed_before, 5) -- children fold is closed at its first row (first child)

  -- Simulate a source insert ABOVE the block: two new lines at the top of the
  -- buffer shift the fence (managed extmark tracks it live) and every rendered
  -- row down by 2.  The stored sf[1] / fence_first remain stale.
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "above 1", "above 2" })

  -- Single re-render via the fold-state-preserving path.  This must capture the
  -- closed subtree at its LIVE (shifted) row, then re-close it after render.
  render.rerender_buffer(bufnr, nil)

  local fence_open, subtree_closed
  vim.api.nvim_win_call(winid, function()
    -- Locate the fence + subtree root rows freshly (rows shifted by +2).
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local fence_row, root_row
    for i, l in ipairs(lines) do
      if l:match("^```tasks") then
        fence_row = i
      elseif fence_row and l:sub(1, #"- [ ] Root task") == "- [ ] Root task" then
        root_row = i
        break
      end
    end
    fence_open = vim.fn.foldclosed(fence_row) -- fence stays open
    -- Children fold starts at the first child (root_row + 1); probe there.
    subtree_closed = vim.fn.foldclosed(root_row + 1) -- subtree stays closed
  end)
  eq(fence_open, -1) -- fence fold remained OPEN across the rerender
  eq(subtree_closed ~= -1, true, "the user-closed subtree must remain closed after rerender")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["render: foldcolumn enabled and foldtext shows hidden-count indicator"] = function()
  -- Match the root (line 1) AND both child tasks (lines 2 + 5) so the children
  -- are LIT (independently matched) and count toward foldtext's M.  Under D2 a
  -- descendant that does NOT independently match its group is DIM and excluded
  -- from M; this test's intent is to count matched child tasks, so we match them.
  local restore = stub_index_lines(SRC_LINES, { 1, 2, 5 })
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- foldcolumn is advertised on the dashboard window (tree-only).
  eq(vim.wo[winid].foldcolumn, "1")
  -- The custom foldtext is installed (tree-only) so the indicator renders.
  eq(vim.wo[winid].foldtext:find("obsidian%-tasks") ~= nil, true)

  -- foldtext renders a subtree summary "{indent}▸ T child items · N/M done".  The fold
  -- is CHILDREN-ONLY (rows 5..8), so its first line is the first CHILD; the root
  -- (row 4) stays visible above the fold and is NOT repeated in the foldtext.
  local ft
  vim.api.nvim_win_call(winid, function()
    vim.cmd("5foldclose") -- close the children fold so v:foldstart/foldend are set
    ft = vim.fn.foldtextresult(5)
  end)
  -- The subtree summary does NOT echo the first child's text — it counts rows.
  eq(ft:find("Child task") == nil, true, "subtree foldtext must not repeat a row's text: [" .. ft .. "]")
  -- Hidden descendants of the root (rows 5..8): child(task,lit), bullet, blank,
  -- second child(task,lit).  items T = non-blank rows = 3 (blank excluded);
  -- matched tasks M = the 2 lit tasks; done N = 0 (both Todo).  The fold's first
  -- child is depth-1 indented, so the leading 2-space indent is preserved.
  eq(ft, "  ▸ 3 child items · 0/2 done", "exact subtree foldtext: [" .. ft .. "]")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── subtree foldtext: exact "T child items · N/M done" string ────────────────

--- Generic single-file stub: `lines` is the source subtree; the matched left-most
--- tasks are the (1-indexed) source lines in `matched_lines` (the first is the
--- root).  Under D2 a descendant is LIT only when it INDEPENDENTLY matches, so
--- foldtext's M (matched/lit descendant tasks) counts exactly the child lines
--- listed here — a test that wants its children to count toward "N/M done" must
--- list them.  `matched_lines` may be a single integer for the root-only case.
--- Returns a restore fn.  Mirrors stub_index but lets a test supply an arbitrary
--- subtree shape.
function stub_index_lines(lines, matched_lines)
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
local function subtree_foldtext(winid)
  local ft
  vim.api.nvim_win_call(winid, function()
    vim.cmd("5foldclose")
    ft = vim.fn.foldtextresult(5)
  end)
  return ft
end

T["foldtext: subtree with a mix of done/undone matched tasks → '3 child items · 1/2 done'"] = function()
  -- Root + 3 descendant rows: a DONE child task, a TODO child task, and a bullet.
  -- dim_completed_tasks=false keeps the done task LIT so it counts toward M (and N).
  --   items T = 3 (two tasks + one bullet, no blank), matched tasks M = 2,
  --   done N = 1 (the [x] child).
  local mix = {
    "- [ ] Root task",
    "  - [x] Done child",
    "  - [ ] Todo child",
    "  - a description",
  }
  -- Match the root (1) AND both child tasks (2 done, 3 todo) so they stay LIT and
  -- count toward M; the bullet (4) is unmatched context.  (D2.)
  local restore = stub_index_lines(mix, { 1, 2, 3 })
  local saved_opts = render._opts
  render.configure({ default_folded = true, dim_completed_tasks = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext(winid)
  eq(ft, "  ▸ 3 child items · 1/2 done", "exact mixed-subtree foldtext: [" .. ft .. "]")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["foldtext: all-bullet subtree (no matched tasks) → '2 child items' with no done clause"] = function()
  -- Root with two pure bullet descendants and no descendant tasks.  M==0, so the
  -- "· N/M done" clause is dropped entirely: just "{indent}▸ T child items".
  local bullets = {
    "- [ ] Root task",
    "  - first note",
    "  - second note",
  }
  local restore = stub_index_lines(bullets, 1)
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local ft = subtree_foldtext(winid)
  eq(ft, "  ▸ 2 child items", "all-bullet subtree drops the done clause: [" .. ft .. "]")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["foldtext: FENCE/query fold keeps the legacy 'first line  ▸ N' format"] = function()
  -- A fence fold is NOT a subtree fold: no fold_info entry exists for it, so
  -- foldtext() must fall back BYTE-FOR-BYTE to the legacy "first line  ▸ N" shape
  -- (the opening ```tasks line + a hidden-row count), unaffected by this change.
  local restore = stub_index()
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- The fence fold spans rows 1..3 and is closed by default_folded; its first
  -- line is the ```tasks line, with two hidden non-blank rows ("show tree", "```").
  local ft
  vim.api.nvim_win_call(winid, function()
    ft = vim.fn.foldtextresult(1)
  end)
  eq(ft, "```tasks  ▸ 2", "fence foldtext must keep the legacy format: [" .. ft .. "]")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── Phase 5a: editable bullet, read-only blank ───────────────────────────────

T["render: bullet rows are managed EDITABLE; blank rows stay read-only"] = function()
  local restore = stub_index()
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local managed = require("obsidian-tasks.render.managed")
  -- Dashboard rows (0-indexed): 3 root, 4 child, 5 bullet, 6 blank, 7 second child.
  -- Row 5 = "  - a description" bullet → EDITABLE (Phase 5a): NOT read-only, and
  -- carries source_indent + bullet_marker for raw write-back.
  local bullet_meta = managed.task_meta_for_row(bufnr, 5)
  eq(bullet_meta ~= nil, true)
  eq(bullet_meta.read_only, nil)
  eq(bullet_meta.tree_kind, "bullet")
  eq(bullet_meta.bullet_marker, "-")
  -- Source indent is the ORIGINAL 2-space leading whitespace (SRC_LINES[3]).
  eq(bullet_meta.source_indent, "  ")
  -- task_text is the verbatim source line (for drift detection).
  eq(bullet_meta.task_text, "  - a description")

  -- Row 6 = blank → STILL read-only.
  local blank_meta = managed.task_meta_for_row(bufnr, 6)
  eq(blank_meta ~= nil, true)
  eq(blank_meta.read_only, true)
  eq(blank_meta.tree_kind, "blank")

  -- Row 3 (0-indexed) = root task → editable (not read-only).
  local root_meta = managed.task_meta_for_row(bufnr, 3)
  eq(root_meta ~= nil, true)
  eq(root_meta.read_only, nil)

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── induced forest: DIM connector ancestors (display path) ────────────────────

T["run: a deep matched task emits DIM ancestors at true depth, then the lit subtree"] = function()
  local restore = stub_index_deep()
  local ast = query_parse.parse("show tree")
  local result = query_run.run(ast, require("obsidian-tasks.index"), nil)
  -- Rows: dim grandparent (d0), dim parent (d1), lit leaf (d2), lit bullet (d3).
  eq(#result.tree_rows, 4)
  eq(result.tree_rows[1].kind, "task")
  eq(result.tree_rows[1].depth, 0)
  eq(result.tree_rows[1].dim, true)
  eq(result.tree_rows[1].matched, false)
  eq(result.tree_rows[1].fold_group, 0) -- breadcrumb sentinel (not foldable)
  eq(result.tree_rows[2].depth, 1)
  eq(result.tree_rows[2].dim, true)
  -- The matched task is LIT at its TRUE depth 2 (NOT re-rooted to 0).
  eq(result.tree_rows[3].kind, "task")
  eq(result.tree_rows[3].depth, 2)
  eq(result.tree_rows[3].dim, nil)
  eq(result.tree_rows[3].matched, true)
  eq(result.tree_rows[3].fold_group ~= 0, true)
  eq(result.tree_rows[4].kind, "bullet")
  eq(result.tree_rows[4].depth, 3)
  eq(result.tree_rows[4].fold_group, result.tree_rows[3].fold_group)
  -- Footer count excludes DIM ancestors: only the one matched task counts.
  eq(result.total, 1)
  restore()
end

T["render: DIM ancestor rows render at true depth, editable + managed (not read-only)"] = function()
  local restore = stub_index_deep()
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Fence is rows 1-3; rendered subtree follows.  Assert on prefixes (backlink
  -- suffix is appended to task lines).
  eq(lines[4]:sub(1, #"- [ ] Grandparent"), "- [ ] Grandparent")
  eq(lines[5]:sub(1, #"  - [ ] Parent"), "  - [ ] Parent")
  eq(lines[6]:sub(1, #"    - [ ] Matched leaf"), "    - [ ] Matched leaf")
  eq(lines[7]:sub(1, #"      - a leaf note"), "      - a leaf note")

  local managed = require("obsidian-tasks.render.managed")
  -- 0-indexed: 3 grandparent (dim), 4 parent (dim), 5 leaf (lit), 6 bullet (lit).
  local gp_meta = managed.task_meta_for_row(bufnr, 3)
  eq(gp_meta ~= nil, true)
  -- Dim ancestor is managed + EDITABLE (not read_only) for later edit phases.
  eq(gp_meta.read_only, nil)
  eq(gp_meta.tree_kind, "task")
  -- Real source meta on the dim ancestor (verbatim disk line + true indent).
  eq(gp_meta.task_text:sub(1, #"- [ ] Grandparent"), "- [ ] Grandparent")
  eq(gp_meta.source_indent, "")

  local parent_meta = managed.task_meta_for_row(bufnr, 4)
  eq(parent_meta.read_only, nil)
  eq(parent_meta.source_indent, "  ")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["render: folding the lit subtree keeps the DIM ancestor breadcrumb visible"] = function()
  -- Deep fixture whose MATCHED leaf has TWO descendant rows, so the CHILDREN-ONLY
  -- subtree fold (created only for ≥2 descendants) exists and can be closed.
  local lines = {
    "- [ ] Grandparent",
    "  - [ ] Parent",
    "    - [ ] Matched leaf",
    "      - a leaf note",
    "      - another leaf note",
  }
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
    local leaf = task_parse.parse(lines[3])
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return leaf, SRC_PATH, 3
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

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- 1-indexed: 4 grandparent (dim), 5 parent (dim), 6 leaf (lit ROOT), 7 leaf
  -- note (lit), 8 another leaf note (lit).  The CHILDREN-ONLY fold spans 7..8.
  -- Closing it must NOT swallow the dim breadcrumb rows 4 / 5 (fold_group 0 →
  -- outside any fold) NOR the lit root 6 (children-only fold excludes the root).
  local gp_closed, parent_closed, root_closed, child_closed
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    vim.cmd("7foldclose")
    gp_closed = vim.fn.foldclosed(4) -- dim grandparent
    parent_closed = vim.fn.foldclosed(5) -- dim parent
    root_closed = vim.fn.foldclosed(6) -- lit root (stays visible)
    child_closed = vim.fn.foldclosed(7) -- first lit child (fold start)
  end)
  -- Dim ancestors AND the lit root are NOT inside any fold → visible.
  eq(gp_closed, -1)
  eq(parent_closed, -1)
  eq(root_closed, -1)
  -- The lit children fold IS closed at its first child row.
  eq(child_closed, 7)

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── completed dim-in-place (flat + tree) ──────────────────────────────────────

T["render: completed tasks are dimmed in place (NOT reordered) in FLAT mode"] = function()
  -- A FLAT dashboard (no `show tree`) with a Done task BEFORE a Todo in sort
  -- order must keep the Done first (dimmed in place), proving the partition sink
  -- was removed.
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  -- Emit Done (line 1) before Todo (line 2); no sort directive so insertion order
  -- is preserved by run.lua.
  index_mod.tasks_in = function(_)
    local done = task_parse.parse("- [x] done first")
    local todo = task_parse.parse("- [ ] todo second")
    local seq = { { done, SRC_PATH, 1 }, { todo, SRC_PATH, 2 } }
    local i = 0
    return function()
      i = i + 1
      local e = seq[i]
      if e then
        return e[1], e[2], e[3]
      end
    end
  end
  local restore = function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
  end

  local saved_opts = render._opts
  render.configure({ default_folded = false, dim_completed_tasks = true })

  local bufnr = make_buf({ "```tasks", "```" }) -- no `show tree` → flat path
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Fence is rows 1-2; rendered tasks follow.  Done stays FIRST (in place).
  eq(lines[3]:sub(1, #"- [x] done first"), "- [x] done first")
  eq(lines[4]:sub(1, #"- [ ] todo second"), "- [ ] todo second")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── Phase 3: lingering in `show tree` (whole subtree block lingers) ───────────

T["tree linger: a matched ROOT that leaves the filter lingers as a dimmed subtree block"] = function()
  -- The root (line 1) matches; it drags in a child task (2), a bullet (3), a
  -- blank (4), and a second child (5).  When the root leaves the filter (toggled
  -- Done), the WHOLE subtree must linger dimmed at the root's prior position —
  -- the task left the FILTER, not the FILE, so its subtree is reconstructed from
  -- index.nodes_for + tree.subtree_rows.
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
    reverse = index_mod.reverse_index,
  }
  local ns = nodes_mod.parse_lines(SRC_LINES)
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
    return (p == SRC_PATH) and ns or {}
  end
  local root_present = true
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      if i == 1 and root_present then
        return task_parse.parse(SRC_LINES[1]), SRC_PATH, 1
      end
    end
  end
  local restore = function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
    index_mod.reverse_index = saved.reverse
  end

  local saved_opts = render._opts
  render.configure({ default_folded = false, linger_on_filter_exit = true, dim_completed_tasks = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Toggle the root Done → record a pending linger; root leaves the live filter.
  render._record_pending_linger(bufnr, SRC_PATH, 1, nil, task_parse.parse("- [x] Root task"))
  root_present = false
  render.rerender_buffer(bufnr, nil)

  -- One linger entry promoted; the WHOLE subtree (5 source lines) lingers dimmed.
  eq(#(render._lingers[bufnr] or {}), 1)
  local state = render._buffer_state[bufnr]
  local linger_rows, dim_rows = 0, 0
  for _, blk in ipairs(state or {}) do
    for _, meta in pairs(blk.line_map or {}) do
      if meta.linger then
        linger_rows = linger_rows + 1
      end
      if meta.dim then
        dim_rows = dim_rows + 1
      end
    end
  end
  -- Root + child + bullet + blank + second child = 5 lingered, dimmed rows.
  eq(linger_rows, 5, "the whole subtree (5 rows) must linger as one block")
  eq(dim_rows, 5, "every lingered subtree row must be dimmed")

  -- The lingered root shows its post-toggle Done state at its prior position.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(lines[4]:sub(1, #"- [x] Root task"), "- [x] Root task")
  eq(lines[5]:sub(1, #"  - [ ] Child task"), "  - [ ] Child task")

  -- Manual refresh clears the linger.
  render.refresh_with_clear_lingers(bufnr, nil)
  eq(render._lingers[bufnr], nil)

  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["tree linger: a completed DESCENDANT inside a still-matching subtree does NOT linger"] = function()
  -- The root stays matched; a DESCENDANT (the child, line 2) is toggled Done.
  -- The child never left the FILTER (only the root matched; the child rode in by
  -- subtree-drag), so it must NOT linger — it is just dimmed in place.
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
    reverse = index_mod.reverse_index,
  }
  -- Source where the child (line 2) is Done so it dims in place under the root.
  local lines_done_child = {
    "- [ ] Root task",
    "  - [x] Child task",
    "  - a description",
    "",
    "  - [ ] Second child",
  }
  local ns = nodes_mod.parse_lines(lines_done_child)
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
    return (p == SRC_PATH) and ns or {}
  end
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return task_parse.parse(lines_done_child[1]), SRC_PATH, 1
      end
    end
  end
  local restore = function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
    index_mod.reverse_index = saved.reverse
  end

  local saved_opts = render._opts
  render.configure({ default_folded = false, linger_on_filter_exit = true, dim_completed_tasks = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Record a pending linger for the DESCENDANT child (line 2), then rerender.
  render._record_pending_linger(bufnr, SRC_PATH, 2, nil, task_parse.parse("  - [x] Child task"))
  render.rerender_buffer(bufnr, nil)

  -- No linger promoted (the descendant was matched=false in the prior render).
  eq(render._lingers[bufnr], nil, "a dragged descendant must not linger")
  -- The child still renders (dimmed in place via dim_completed), not removed.
  local state = render._buffer_state[bufnr]
  local linger_rows = 0
  local child_present = false
  for _, blk in ipairs(state or {}) do
    for _, meta in pairs(blk.line_map or {}) do
      if meta.linger then
        linger_rows = linger_rows + 1
      end
      if meta.src_line == 2 then
        child_present = true
      end
    end
  end
  eq(linger_rows, 0, "no rows lingered")
  eq(child_present, true, "the completed descendant is dimmed in place, not lingered away")

  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

T["tree linger guard: a stale subtree snapshot (line-1 node no longer the captured task) falls back to ONE dimmed root"] = function()
  -- FIX 4 stale-snapshot guard.  The linger_subtree is rebuilt by resolving
  -- ent.src_line (1) against the CURRENT node model.  Simulate a re-index where
  -- the file shifted so pos[1] now resolves to a DIFFERENT task than the captured
  -- linger.  The guard compares the resolved root's description to the captured
  -- task's; on mismatch it must NOT emit a wrong subtree block — it falls back to
  -- a single dimmed root row.
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
    reverse = index_mod.reverse_index,
  }
  -- The node model after a re-index/shift: line 1 is now a DIFFERENT task, with a
  -- (bogus) descendant.  If the guard were absent, subtree_rows would emit this
  -- wrong block under the lingered root.
  local shifted_lines = {
    "- [ ] Totally different task",
    "  - [ ] Wrong child",
  }
  local ns_shifted = nodes_mod.parse_lines(shifted_lines)
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
    return (p == SRC_PATH) and ns_shifted or {}
  end
  local root_present = true
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      -- The live root the dashboard renders first; it carries the ORIGINAL
      -- "Root task" so the captured linger reflects that task.
      if i == 1 and root_present then
        return task_parse.parse("- [ ] Root task"), SRC_PATH, 1
      end
    end
  end
  local restore = function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
    index_mod.reverse_index = saved.reverse
  end

  local saved_opts = render._opts
  render.configure({ default_folded = false, linger_on_filter_exit = true, dim_completed_tasks = true })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Capture a linger for the ORIGINAL "Root task" (description "Root task"), then
  -- let it leave the filter.  The reconstruction resolves line 1 in ns_shifted →
  -- "Totally different task" (description mismatch) → guard fires.
  render._record_pending_linger(bufnr, SRC_PATH, 1, nil, task_parse.parse("- [x] Root task"))
  root_present = false
  render.rerender_buffer(bufnr, nil)

  eq(#(render._lingers[bufnr] or {}), 1, "the root still lingers (as a single dimmed row)")
  local state = render._buffer_state[bufnr]
  local linger_rows = 0
  for _, blk in ipairs(state or {}) do
    for _, meta in pairs(blk.line_map or {}) do
      if meta.linger then
        linger_rows = linger_rows + 1
      end
    end
  end
  -- Guard fired: ONE dimmed root row, NOT the (wrong) 2-row block from ns_shifted.
  eq(linger_rows, 1, "stale snapshot must fall back to a single dimmed root, not a wrong block")
  -- And the WRONG child text must never reach the buffer.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local saw_wrong = false
  for _, l in ipairs(lines) do
    if l:find("Wrong child", 1, true) then
      saw_wrong = true
    end
  end
  eq(saw_wrong, false, "the wrong subtree descendant must NOT be emitted")

  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

return T
