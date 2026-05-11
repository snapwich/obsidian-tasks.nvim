-- tests/integration/test_render_lifecycle.lua
-- Integration tests for BufWritePost block lifecycle (T5):
--   • Initial render: default_folded=true → all blocks folded.
--   • rerender_buffer: existing block fold states preserved across re-render.
--   • rerender_buffer: new blocks get the default fold; existing blocks unchanged.
--   • rerender_buffer: deleted blocks cleaned up; remaining blocks unchanged.
--
-- All tests run in headless Neovim (window APIs available).
-- render.configure({default_folded=true}) is called before each test so
-- M._opts reflects the correct setting (module-level default is already true,
-- but explicit configuration is cleaner and matches the real setup() flow).

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local folds_mod = require("obsidian-tasks.render.folds")

-- ── Helpers ───────────────────────────────────────────────────────────────────

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

--- Open bufnr in a new window and return the window id.
--- @param bufnr integer
--- @return integer  winid
local function open_in_win(bufnr)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

--- Close a window.
--- @param winid integer
local function close_win(winid)
  pcall(vim.api.nvim_win_close, winid, true)
end

--- Return foldclosed(lnum_1) for bufnr in its first window, or -1.
--- @param bufnr   integer
--- @param lnum_1  integer  1-indexed line number
--- @return integer
local function fold_closed_at(bufnr, lnum_1)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return -1
  end
  local result = -1
  vim.api.nvim_win_call(wins[1], function()
    result = vim.fn.foldclosed(lnum_1)
  end)
  return result
end

--- Open the fold at lnum_1 (1-indexed) in bufnr's first window.
--- @param bufnr  integer
--- @param lnum_1 integer
local function open_fold_at(bufnr, lnum_1)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return
  end
  vim.api.nvim_win_call(wins[1], function()
    pcall(vim.cmd, lnum_1 .. "foldopen")
  end)
end

-- ── Index stub ────────────────────────────────────────────────────────────────

--- Install an index stub.  Each call to tasks_in() returns one task then nil,
--- so every rendered block gets exactly one task line.
--- Returns a restore function.
--- @return function  restore
local function install_one_task_stub()
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")

  local task_obj = task_parse.parse("- [ ] Stub task")
  assert(task_obj, "task_parse.parse returned nil — test setup error")

  local saved_tasks_in = index_mod.tasks_in
  local saved_set = index_mod.set_render_paths
  local saved_clear = index_mod.clear_render_paths

  index_mod.tasks_in = function(_)
    local returned = false
    return function()
      if not returned then
        returned = true
        return task_obj, "/vault/stub.md", 1
      end
      return nil
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  return function()
    index_mod.tasks_in = saved_tasks_in
    index_mod.set_render_paths = saved_set
    index_mod.clear_render_paths = saved_clear
  end
end

--- Install an index stub that returns zero tasks (iterator immediately returns nil).
--- @return function  restore
local function install_zero_task_stub()
  local index_mod = require("obsidian-tasks.index")
  local saved_tasks_in = index_mod.tasks_in
  local saved_set = index_mod.set_render_paths
  local saved_clear = index_mod.clear_render_paths

  index_mod.tasks_in = function(_)
    return function()
      return nil
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  return function()
    index_mod.tasks_in = saved_tasks_in
    index_mod.set_render_paths = saved_set
    index_mod.clear_render_paths = saved_clear
  end
end

-- ── T1: initial render with 3 blocks → all folds applied ─────────────────────

T["initial render: 3 blocks all folded when default_folded=true"] = function()
  render.configure({ default_folded = true })
  local restore_idx = install_one_task_stub()

  --   Line 1-3: block 1
  --   Line 4-6: block 2
  --   Line 7-9: block 3
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "```tasks",
    "not done",
    "```",
    "```tasks",
    "not done",
    "```",
  })
  local winid = open_in_win(bufnr)

  render.render_buffer(bufnr, nil)

  -- With 1 task per block and offset tracking:
  --   block 1 fence → line 1 (fold: 1..4)
  --   block 2 fence → line 5 (fold: 5..8)
  --   block 3 fence → line 9 (fold: 9..12)
  local fc1 = fold_closed_at(bufnr, 1)
  local fc2 = fold_closed_at(bufnr, 5)
  local fc3 = fold_closed_at(bufnr, 9)

  render.clear_buffer(bufnr)
  restore_idx()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(fc1, 1) -- block 1 fence is in a closed fold starting at 1
  eq(fc2, 5) -- block 2 fence is in a closed fold starting at 5
  eq(fc3, 9) -- block 3 fence is in a closed fold starting at 9
end

-- ── T2: rerender_buffer preserves fold state for all blocks ──────────────────
-- This exercises the key block_range[1] key logic.  With 1 task per block
-- (render_range is non-nil) a bug in source-fence-row computation would cause
-- block 2's fold state to be lost.

T["rerender_buffer: opened block-2 fold stays open after re-render"] = function()
  render.configure({ default_folded = true })
  local restore_idx = install_one_task_stub()

  --   Line 1-3: block 1  (source pos 1)
  --   Line 4-6: block 2  (source pos 4)
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "```tasks",
    "not done",
    "```",
  })
  local winid = open_in_win(bufnr)

  -- Initial render: both blocks closed.
  render.render_buffer(bufnr, nil)

  -- After rendering with 1 task each:
  --   block 1 fold at lines 1..4, block 2 fold at lines 5..8.
  -- Open block 2's fold (line 5).
  open_fold_at(bufnr, 5)

  -- Verify precondition: block 2 fold is now open.
  local pre_fc1 = fold_closed_at(bufnr, 1)
  local pre_fc2 = fold_closed_at(bufnr, 5)

  -- Re-render.
  render.rerender_buffer(bufnr, nil)

  -- After re-render block 2's positions may shift; re-read from new state.
  -- block 1 fence → still line 1 in cleared buffer + 1 task → line 1 rendered
  -- block 2 fence → source pos 4, 1 prior task → fence_first=4 → line 5
  local post_fc1 = fold_closed_at(bufnr, 1)
  local post_fc2 = fold_closed_at(bufnr, 5)

  render.clear_buffer(bufnr)
  restore_idx()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Preconditions: block 1 closed, block 2 open before re-render.
  eq(pre_fc1, 1)
  eq(pre_fc2, -1) -- opened

  -- Postconditions: block 1 stays closed, block 2 stays open.
  eq(post_fc1, 1) -- block 1 closed
  eq(post_fc2, -1) -- block 2 still open (fold preserved)
end

-- ── T3: new block added to source → folds correctly after rerender ────────────
-- Existing block's open fold is preserved; new block at end gets default fold.

T["rerender_buffer: new block at end gets default fold, existing fold state preserved"] = function()
  render.configure({ default_folded = true })
  local restore_idx = install_one_task_stub()

  -- Single-block buffer.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  -- Initial render: 1 block, 1 task inserted → fold at lines 1..4.
  render.render_buffer(bufnr, nil)

  -- Open block 1's fold.
  open_fold_at(bufnr, 1)
  local pre_fc1 = fold_closed_at(bufnr, 1)

  -- Add a new source block to the buffer AFTER the rendered task line.
  -- Buffer currently (0-indexed): ```tasks(0), not done(1), ```(2), - [ ] Task(3).
  -- Append 3 more lines (new source block) starting at row 4.
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "```tasks", "not done", "```" })

  -- Re-render.
  render.rerender_buffer(bufnr, nil)

  -- After rerender:
  --   Source (cleared): lines 1..3 (block 1), 4..6 (new block 2).
  --   1 task per block → block 1 fence at line 1 (fold 1..4), block 2 at line 5 (fold 5..8).
  local post_fc1 = fold_closed_at(bufnr, 1) -- block 1: was open
  local post_fc2 = fold_closed_at(bufnr, 5) -- block 2: new → closed by default

  render.clear_buffer(bufnr)
  restore_idx()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(pre_fc1, -1) -- block 1 was opened before re-render
  eq(post_fc1, -1) -- block 1 stays open after re-render
  eq(post_fc2, 5) -- new block 2 gets default fold (closed)
end

-- ── T4: deleted block cleaned up; remaining block unchanged ──────────────────
-- Use 0-task rendering so no task lines are inserted (simpler buffer state).
-- After deleting block 1's source lines and calling rerender_buffer, block 2
-- (now at source position 1) should render with a fold and no errors.

T["rerender_buffer: deleted block cleaned up, remaining block renders correctly"] = function()
  render.configure({ default_folded = true })
  local restore_idx = install_zero_task_stub()

  -- Two-block buffer (no task lines rendered since 0 tasks).
  local bufnr = make_buf({
    "```tasks", -- block 1: source lines 1-3
    "not done",
    "```",
    "```tasks", -- block 2: source lines 4-6
    "not done",
    "```",
  })
  local winid = open_in_win(bufnr)

  -- Initial render (0 tasks → no lines inserted, only folds).
  render.render_buffer(bufnr, nil)

  -- Verify both blocks are folded.
  local fc1_initial = fold_closed_at(bufnr, 1)
  local fc2_initial = fold_closed_at(bufnr, 4)

  -- Simulate user deleting block 1: remove its 3 source lines (rows 0-2, 0-indexed).
  vim.api.nvim_buf_set_lines(bufnr, 0, 3, false, {})

  -- Buffer now has only the old block 2 (lines 1-3 in 1-indexed).
  local lines_after_del = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Re-render: should clear orphaned state and render the surviving block.
  local ok = pcall(render.rerender_buffer, bufnr, nil)

  local post_fc1 = fold_closed_at(bufnr, 1) -- surviving block (at line 1 now)
  local post_line_count = #vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  render.clear_buffer(bufnr)
  restore_idx()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Both blocks were folded on initial render.
  eq(fc1_initial, 1)
  eq(fc2_initial, 4)

  -- After deletion buffer had 3 lines (only old block 2 remaining).
  eq(#lines_after_del, 3)

  -- rerender_buffer must not error.
  eq(ok, true)

  -- Surviving block now at line 1, rendered with a fold.
  eq(post_fc1, 1)

  -- No extra lines inserted (0 tasks in stub).
  eq(post_line_count, 3)
end

return T
