-- tests/integration/test_folding.lua
-- Integration tests for the manual fold infrastructure (T4).
--
-- Covers:
--   • render/folds.lua — setup_window, apply_folds, capture_fold_state,
--     restore_fold_state.
--   • render/init.lua integration — folds applied + summary extmark attached
--     by render_buffer().
--
-- All tests run in headless Neovim (window APIs available).

local T = MiniTest.new_set()

local folds_mod = require("obsidian-tasks.render.folds")
local draw_mod = require("obsidian-tasks.render.draw")
local render = require("obsidian-tasks.render.init")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Open bufnr in a new scratch window and return the window id.
--- @param bufnr integer
--- @return integer  winid
local function open_in_win(bufnr)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

--- Close a window without triggering BufDelete.
--- @param winid integer
local function close_win(winid)
  pcall(vim.api.nvim_win_close, winid, true)
end

-- ── folds.setup_window ────────────────────────────────────────────────────────

T["setup_window: sets foldmethod to manual"] = function()
  local bufnr = make_buf({ "line 1", "line 2" })
  local winid = open_in_win(bufnr)

  folds_mod.setup_window(winid)
  eq(vim.wo[winid].foldmethod, "manual")

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["setup_window: appends insert to foldopen (global)"] = function()
  local bufnr = make_buf({ "line 1" })
  local winid = open_in_win(bufnr)

  folds_mod.setup_window(winid)
  local fdo = vim.opt.foldopen:get()
  local has_insert = false
  for _, v in ipairs(fdo) do
    if v == "insert" then
      has_insert = true
      break
    end
  end
  eq(has_insert, true)

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["setup_window: idempotent — 'insert' not duplicated in foldopen"] = function()
  local bufnr = make_buf({ "line 1" })
  local winid = open_in_win(bufnr)

  -- Call twice.
  folds_mod.setup_window(winid)
  folds_mod.setup_window(winid)

  local fdo = vim.opt.foldopen:get()
  local count = 0
  for _, v in ipairs(fdo) do
    if v == "insert" then
      count = count + 1
    end
  end
  eq(count, 1)

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["setup_window: tree → flat transition resets foldcolumn + foldtext to prior"] = function()
  local bufnr = make_buf({ "line 1", "line 2" })
  local winid = open_in_win(bufnr)

  -- Capture the window's pristine (never-tree) fold options.
  local default_fc = vim.wo[winid].foldcolumn
  local default_ft = vim.wo[winid].foldtext

  -- Render as a tree: foldcolumn advertised, custom foldtext installed.
  folds_mod.setup_window(winid, true)
  eq(vim.wo[winid].foldcolumn, "1")
  eq(vim.wo[winid].foldtext:find("obsidian%-tasks") ~= nil, true)

  -- Re-render the SAME window as flat (user removed `show tree`): the tree-only
  -- foldcolumn / foldtext must be reset so the window is indistinguishable from a
  -- never-tree flat dashboard.
  folds_mod.setup_window(winid, false)
  eq(vim.wo[winid].foldcolumn, default_fc, "foldcolumn must reset to its pre-tree default")
  eq(vim.wo[winid].foldtext, default_ft, "foldtext must reset to its pre-tree default")
  eq(vim.wo[winid].foldtext:find("obsidian%-tasks"), nil, "custom tree foldtext must not linger after a flat re-render")

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── folds.apply_folds ─────────────────────────────────────────────────────────

T["apply_folds: folds fence lines only, leaves rendered tasks visible"] = function()
  -- Buffer:
  --   0 "```tasks"      ← fence_first = 0
  --   1 "not done"
  --   2 "```"           ← fence_last  = 2
  --   3 "- [ ] Task A"  ← rendered task, must stay visible
  local bufnr = make_buf({ "```tasks", "not done", "```", "- [ ] Task A" })
  local winid = open_in_win(bufnr)

  folds_mod.apply_folds(bufnr, { { fence_first = 0, fence_last = 2 } })

  local fence_fc, task_fc
  vim.api.nvim_win_call(winid, function()
    fence_fc = vim.fn.foldclosed(1) -- opening fence
    task_fc = vim.fn.foldclosed(4) -- rendered task
  end)
  -- Fence is in a closed fold starting at line 1.
  eq(fence_fc, 1)
  -- Rendered task line is NOT in any closed fold (AC1).
  eq(task_fc, -1)

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["apply_folds: children-only fold keeps a group-header virt line on the root visible"] = function()
  -- Regression: group headers are rendered as virt_lines_above on the group's
  -- FIRST task row.  When that row was the first line of a CLOSED subtree fold,
  -- Neovim hid the header (it does not draw virt_lines_above of a fold's first
  -- line), so the header vanished and the collapsed subtree slid under the
  -- previous group.  Children-only folds keep the root (and its header) OUTSIDE
  -- the fold.
  --   0 "```tasks"   ← fence_first
  --   1 "show tree"
  --   2 "```"        ← fence_last
  --   3 "- [ ] root" ← group's first task / subtree root  (header above it)
  --   4 "  - child 1"
  --   5 "  - child 2"
  local bufnr = make_buf({ "```tasks", "show tree", "```", "- [ ] root", "  - child 1", "  - child 2" })
  local hns = vim.api.nvim_create_namespace("ot_test_group_header")
  vim.api.nvim_buf_set_extmark(bufnr, hns, 3, 0, {
    virt_lines = { { { "## My Group", "Title" } } },
    virt_lines_above = true,
  })
  local winid = open_in_win(bufnr)

  -- subtree { root=3, last=5 } → children-only fold over rows 4..5 (1-indexed 5..6).
  folds_mod.apply_folds(bufnr, { { fence_first = 0, fence_last = 2, subtree_folds = { { 3, 5 } } } }, false)

  local root_fc, child_fc, header_visible
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR") -- expand everything first
    vim.cmd("5foldclose") -- close the children fold (first child, 1-indexed 5)
    root_fc = vim.fn.foldclosed(4) -- root row (1-indexed 4)
    child_fc = vim.fn.foldclosed(5) -- first child row
    -- Scan the rendered screen for the header text — proves it is actually drawn.
    vim.o.lines = 20
    vim.o.columns = 60
    vim.cmd("redraw")
    header_visible = false
    for row = 1, 12 do
      local s = ""
      for col = 1, 56 do
        s = s .. (vim.fn.screenstring(row, col) or "")
      end
      if s:find("## My Group", 1, true) then
        header_visible = true
        break
      end
    end
  end)
  eq(root_fc, -1, "root row (with the group header) must stay OUTSIDE the closed fold")
  eq(child_fc, 5, "the children fold must be closed at its first child row")
  eq(header_visible, true, "the group header virt line must remain visible when the subtree is folded")

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["apply_folds: no-op when block_list is empty"] = function()
  local bufnr = make_buf({ "line 1", "line 2" })
  local winid = open_in_win(bufnr)
  -- Should not error.
  folds_mod.apply_folds(bufnr, {})
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["apply_folds: no-op when no windows show the buffer"] = function()
  local bufnr = make_buf({ "line 1", "line 2" })
  -- Do NOT open in a window — should not error.
  folds_mod.apply_folds(bufnr, { { fence_first = 0, fence_last = 1 } })
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── folds.capture_fold_state / restore_fold_state ─────────────────────────────

T["capture_fold_state: returns 'open' when line is not folded"] = function()
  local bufnr = make_buf({ "line 1", "line 2", "line 3" })
  local winid = open_in_win(bufnr)
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
  end)

  local state = folds_mod.capture_fold_state(bufnr, 0)
  eq(state, "open")

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["capture_fold_state: returns 'closed' when fold exists at fence row"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```", "- [ ] Task A" })
  local winid = open_in_win(bufnr)

  -- Create a fold so foldclosed returns the fold start.
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
    vim.cmd("1,4fold")
  end)

  local state = folds_mod.capture_fold_state(bufnr, 0) -- fence_lnum=0 (0-indexed)
  eq(state, "closed")

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["capture_fold_state: returns 'open' when no windows show buffer"] = function()
  local bufnr = make_buf({ "line 1" })
  local state = folds_mod.capture_fold_state(bufnr, 0)
  eq(state, "open")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["restore_fold_state: does nothing when state is 'open'"] = function()
  local bufnr = make_buf({ "line 1", "line 2", "line 3" })
  local winid = open_in_win(bufnr)
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
  end)

  -- Should not error or create a fold.
  folds_mod.restore_fold_state(bufnr, 0, 2, "open")

  local fc
  vim.api.nvim_win_call(winid, function()
    fc = vim.fn.foldclosed(1)
  end)
  eq(fc, -1) -- -1 means line is not in a closed fold

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["restore_fold_state: re-applies fold when state is 'closed'"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```", "- [ ] Task A" })
  local winid = open_in_win(bufnr)
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
  end)

  -- fence_first=0, fence_last=2 — rendered task at row 3 must stay visible.
  folds_mod.restore_fold_state(bufnr, 0, 2, "closed")

  local fence_fc, task_fc
  vim.api.nvim_win_call(winid, function()
    fence_fc = vim.fn.foldclosed(1) -- opening fence
    task_fc = vim.fn.foldclosed(4) -- rendered task
  end)
  eq(fence_fc, 1) -- fold starts at line 1 (1-indexed)
  eq(task_fc, -1) -- rendered task line is not folded

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── render/init.lua integration: folds applied after render_buffer ─────────────

T["render_buffer: applies fold after rendering tasks block"] = function()
  -- Ensure default_folded is true for this test regardless of what earlier test
  -- files set.  test_f9_acceptance.lua runs first (alphabetically) and calls
  -- render.configure({ default_folded = false }), leaving the module state dirty.
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  -- Use a minimal stub index with one task.
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved_tasks_in = index_mod.tasks_in

  -- Parse a real task line so the object has the full structure that
  -- filter.lua and serialize.lua expect (fields, _origin, indent, marker, …).
  local task_obj = task_parse.parse("- [ ] Buy milk")
  assert(task_obj, "task_parse.parse returned nil — test setup error")

  -- Return the task exactly once, then nil (proper iterator contract).
  index_mod.tasks_in = function(_)
    local returned = false
    return function()
      if not returned then
        returned = true
        return task_obj, "/vault/tasks.md", 1
      end
      return nil
    end
  end

  -- Stub set_render_paths / clear_render_paths to be no-ops.
  local saved_set = index_mod.set_render_paths
  local saved_clear = index_mod.clear_render_paths
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  -- render_buffer: should draw and apply fold.
  render.render_buffer(bufnr, nil)

  -- After rendering, the buffer should have an extra task line inserted.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#lines > 3, true)

  -- The fold should have been applied; check via foldclosed on line 1 (fence).
  local fc
  vim.api.nvim_win_call(winid, function()
    fc = vim.fn.foldclosed(1)
  end)
  -- fc == 1 means line 1 is in a closed fold starting at 1.
  eq(fc, 1)

  -- Cleanup.
  render.clear_buffer(bufnr)
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_set
  index_mod.clear_render_paths = saved_clear
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
end

T["render_buffer: a flat (non-tree) dashboard leaves foldcolumn/foldtext untouched"] = function()
  -- A flat dashboard still folds its fence when default_folded=true, so
  -- apply_folds → setup_window runs.  It must NOT advertise the fold gutter or
  -- swap in the custom foldtext (those are tree-only): the window keeps its
  -- prior foldcolumn / foldtext so the flat render stays byte-identical.
  local saved_opts = render._opts
  render.configure({ default_folded = true })

  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
  }
  local task_obj = task_parse.parse("- [ ] Buy milk")
  assert(task_obj, "task_parse.parse returned nil — test setup error")
  index_mod.tasks_in = function(_)
    local returned = false
    return function()
      if not returned then
        returned = true
        return task_obj, "/vault/tasks.md", 1
      end
      return nil
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  -- Capture the window's prior fold-display options (Neovim defaults).
  local prior_fc = vim.wo[winid].foldcolumn
  local prior_ft = vim.wo[winid].foldtext

  render.render_buffer(bufnr, nil)

  -- The fence fold was applied (proves apply_folds ran)…
  local fc
  vim.api.nvim_win_call(winid, function()
    fc = vim.fn.foldclosed(1)
  end)
  eq(fc, 1)

  -- …yet foldcolumn / foldtext are unchanged (tree-only window options).
  eq(vim.wo[winid].foldcolumn, prior_fc)
  eq(vim.wo[winid].foldtext, prior_ft)
  -- Specifically, the custom foldtext was NOT installed.
  eq(vim.wo[winid].foldtext:find("obsidian%-tasks") == nil, true)

  render.clear_buffer(bufnr)
  index_mod.tasks_in = saved.tasks_in
  index_mod.set_render_paths = saved.set
  index_mod.clear_render_paths = saved.clear
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
end

return T
