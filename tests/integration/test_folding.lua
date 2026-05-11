-- tests/integration/test_folding.lua
-- Integration tests for the manual fold infrastructure (T4).
--
-- Covers:
--   • render/folds.lua — setup_window, apply_folds, capture_fold_state,
--     restore_fold_state.
--   • render/foldtext.lua — set_result_count / clear_buffer lifecycle and the
--     foldtext() callback reading v:foldstart from a real buffer+window.
--   • render/init.lua integration — folds applied after render_buffer().
--
-- All tests run in headless Neovim (window APIs available).

local T = MiniTest.new_set()

local folds_mod = require("obsidian-tasks.render.folds")
local foldtext_mod = require("obsidian-tasks.render.foldtext")
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

T["setup_window: sets foldtext to our Lua function"] = function()
  local bufnr = make_buf({ "line 1" })
  local winid = open_in_win(bufnr)

  folds_mod.setup_window(winid)
  local ft = vim.wo[winid].foldtext
  -- Must contain the module path so Neovim can call it.
  -- Use plain-string search (4th arg = true) to avoid Lua pattern issues:
  -- '-' and '.' in "obsidian-tasks.render.foldtext" are pattern meta-chars.
  MiniTest.expect.equality(ft:find("obsidian-tasks.render.foldtext", 1, true) ~= nil, true)

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

-- ── folds.apply_folds ─────────────────────────────────────────────────────────

T["apply_folds: creates a fold covering fence through region end"] = function()
  -- Buffer:
  --   0 "```tasks"      ← fence_first = 0
  --   1 "not done"
  --   2 "```"
  --   3 "- [ ] Task A"  ← region_end = 3
  local bufnr = make_buf({ "```tasks", "not done", "```", "- [ ] Task A" })
  local winid = open_in_win(bufnr)

  folds_mod.apply_folds(bufnr, { { fence_first = 0, region_end = 3 } })

  -- foldclosed(1) should be 1 (the fold starts at line 1, 1-indexed).
  local result
  vim.api.nvim_win_call(winid, function()
    result = vim.fn.foldclosed(1)
  end)
  -- foldclosed returns 1-indexed start of the closed fold, i.e. 1.
  eq(result, 1)

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
  folds_mod.apply_folds(bufnr, { { fence_first = 0, region_end = 1 } })
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

  folds_mod.restore_fold_state(bufnr, 0, 3, "closed")

  local fc
  vim.api.nvim_win_call(winid, function()
    fc = vim.fn.foldclosed(1)
  end)
  eq(fc, 1) -- fold starts at line 1 (1-indexed)

  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── foldtext.foldtext() callback ──────────────────────────────────────────────

T["foldtext: returns summary string for a folded block"] = function()
  -- Create a buffer with a tasks block and fold it manually, then call foldtext().
  local bufnr = make_buf({
    "```tasks", -- line 1 (1-indexed) = fence
    "not done",
    "```",
    "- [ ] Task A",
    "- [ ] Task B",
  })
  local winid = open_in_win(bufnr)

  -- Cache result count for this block (fence_first = 0).
  foldtext_mod.set_result_count(bufnr, 0, 2)

  -- Apply fold lines 1-5.
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
    vim.cmd("1,5fold")
  end)

  -- Call foldtext() with v:foldstart=1, v:foldend=5 simulated via nvim_win_call.
  local result
  vim.api.nvim_win_call(winid, function()
    -- Temporarily set v:foldstart and v:foldend so foldtext() can read them.
    vim.v.foldstart = 1
    vim.v.foldend = 5
    result = foldtext_mod.foldtext()
  end)

  eq(result, "📋 not done  (2)")

  foldtext_mod.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["foldtext: empty query → all tasks with cached count"] = function()
  local bufnr = make_buf({ "```tasks", "```", "- [ ] Task" })
  local winid = open_in_win(bufnr)

  foldtext_mod.set_result_count(bufnr, 0, 1)

  local result
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
    vim.cmd("1,3fold")
    vim.v.foldstart = 1
    vim.v.foldend = 3
    result = foldtext_mod.foldtext()
  end)

  eq(result, "📋 all tasks  (1)")

  foldtext_mod.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["foldtext: falls back to 0 count when cache is empty"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  -- Do NOT call set_result_count — count should default to 0.
  local result
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
    vim.cmd("1,3fold")
    vim.v.foldstart = 1
    vim.v.foldend = 3
    result = foldtext_mod.foldtext()
  end)

  eq(result, "📋 not done  (0)")

  foldtext_mod.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── render/init.lua integration: folds applied after render_buffer ─────────────

T["render_buffer: applies fold and caches result count"] = function()
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

  -- The result count should be cached (exactly 1 task matched).
  -- Verify indirectly: foldtext() should include the 📋 prefix and count "(1)".
  local ft_result
  vim.api.nvim_win_call(winid, function()
    vim.v.foldstart = 1
    vim.v.foldend = #lines
    ft_result = foldtext_mod.foldtext()
  end)
  -- Plain-string find: avoid Lua pattern issues with '-' and '.' meta-chars.
  MiniTest.expect.equality(ft_result:find("📋", 1, true) ~= nil, true)
  MiniTest.expect.equality(ft_result:find("(1)", 1, true) ~= nil, true)

  -- Cleanup.
  render.clear_buffer(bufnr)
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_set
  index_mod.clear_render_paths = saved_clear
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
end

return T
