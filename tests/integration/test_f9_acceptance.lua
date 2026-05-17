-- tests/integration/test_f9_acceptance.lua
-- Feature-level acceptance tests for F9: Render rework.
--
-- Each test maps directly to one acceptance criterion (AC1–AC10) from the
-- feature spec.  Passing this file is the gate condition for the feature.
--
-- AC1  Default render + fold on open
-- AC2  `i` opens fold + enters insert (foldopen+=insert mechanism)
-- AC3  :w writes source-only; reopen preserves state
-- AC4  New block detection + fold preservation
-- AC5  Deleted block cleanup
-- AC6  <leader>tt toggle + re-render
-- AC7  Typing in managed region reverts
-- AC8  No conceal anywhere in plugin source
-- AC9  F4 removed (edit.lua absent, no BufWritePre from plugin)
-- AC10 :ObsidianTask <subcmd> works on rendered rows
--
-- NOTE on async: mini.test swallows assertions after vim.wait(N, cond_fn).
-- All tests use synchronous seams (_flush_pending, direct module calls) to
-- remain deterministic without yielding to the event loop.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local managed = require("obsidian-tasks.render.managed")
local revert = require("obsidian-tasks.render.revert")
local save = require("obsidian-tasks.render.save")
local folds_mod = require("obsidian-tasks.render.folds")
local keymap_mod = require("obsidian-tasks.render.keymap")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Open bufnr in a new split window and return winid.
--- @param bufnr integer
--- @return integer  winid
local function open_in_win(bufnr)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

--- Close a window silently.
--- @param winid integer
local function close_win(winid)
  pcall(vim.api.nvim_win_close, winid, true)
end

--- Return foldclosed(lnum_1) for bufnr in its first window, or -1.
--- @param bufnr  integer
--- @param lnum_1 integer  1-indexed
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

--- Get line at 0-indexed row.
--- @param bufnr integer
--- @param row0  integer
--- @return string
local function get_line(bufnr, row0)
  return vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
end

--- Write lines to a temp file and return its path.
--- @param lines string[]
--- @return string
local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

--- Read all lines from a file.
--- @param path string
--- @return string[]
local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- Install a one-task index stub.  Returns a restore function.
--- @param task_text string|nil  defaults to "- [ ] Stub task"
--- @return function
local function install_one_task_stub(task_text)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")

  local task_obj = task_parse.parse(task_text or "- [ ] Stub task")
  assert(task_obj, "task_parse.parse returned nil — test setup error")

  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }

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
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Install a zero-task index stub.  Returns a restore function.
--- @return function
local function install_zero_task_stub()
  local index_mod = require("obsidian-tasks.index")

  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }

  index_mod.tasks_in = function(_)
    return function()
      return nil
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Swap package.loaded[name] for mock; return cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

-- ── AC1: Default render + fold on open ───────────────────────────────────────
-- Opening a dashboard .md file shows all ```tasks blocks collapsed, with
-- rendered task lines visible below each fold.

T["AC1: two blocks both folded on render"] = function()
  render.configure({ default_folded = true })
  -- Stub returns one todo task: both "not done" blocks get 1 result each.
  local restore = install_one_task_stub("- [ ] AC1 task")

  -- Two-block buffer: both use "not done" query so the todo stub task matches.
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "```tasks",
    "not done",
    "```",
  })
  local winid = open_in_win(bufnr)

  render.render_buffer(bufnr, nil)

  -- After render with 1 task each, fold covers fence lines only:
  --   block 1: fence rows 0-2 → fold lines 1..3; task row 3 (line 4) visible.
  --   block 2: fence rows 4-6 → fold lines 5..7; task row 7 (line 8) visible.
  local fc1 = fold_closed_at(bufnr, 1)
  local fc2 = fold_closed_at(bufnr, 5)
  local fc_task1 = fold_closed_at(bufnr, 4)
  local fc_task2 = fold_closed_at(bufnr, 8)

  -- Both fence folds should be closed; rendered task lines must remain visible.
  local fold1_closed = fc1 == 1
  local fold2_closed = fc2 == 5
  local task1_visible = fc_task1 == -1
  local task2_visible = fc_task2 == -1

  -- Rendered task lines are present in the buffer (visible below folds).
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local task_line_found = false
  for _, l in ipairs(all_lines) do
    if l:find("AC1 task") then
      task_line_found = true
      break
    end
  end

  render.clear_buffer(bufnr)
  restore()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(fold1_closed, true, "AC1: block 1 fence fold must be closed")
  eq(fold2_closed, true, "AC1: block 2 fence fold must be closed")
  eq(task1_visible, true, "AC1: block 1 rendered task must be visible (not folded)")
  eq(task2_visible, true, "AC1: block 2 rendered task must be visible (not folded)")
  eq(task_line_found, true, "AC1: rendered task line must be present in buffer")
end

-- ── AC2: `i` opens fold via foldopen+=insert ─────────────────────────────────
-- Pressing `i` on a folded query opens the fold and enters insert mode.
-- The mechanism: setup_window adds "insert" to the global foldopen option so
-- that Neovim's built-in fold behavior opens the fold when insert mode starts.
-- We verify: (a) fold is closed after render, (b) foldopen contains "insert",
-- (c) the fold can be opened (using zo which is the programmatic equivalent).
-- NOTE: `startinsert` via Ex command does not fire foldopen triggers in
-- headless Neovim; `i` via user input does.  We therefore test the mechanism
-- (foldopen+=insert) rather than simulating the keystroke directly.

T["AC2: fold closed after render; foldopen+=insert set; fold opens with zo"] = function()
  render.configure({ default_folded = true })
  local restore = install_one_task_stub("- [ ] AC2 task")

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  render.render_buffer(bufnr, nil)

  -- 1. Fold must be closed after render.
  local fc_before = fold_closed_at(bufnr, 1)

  -- 2. `foldopen` must include "insert" (the mechanism that makes `i` open folds).
  local fdo = vim.opt.foldopen:get()
  local has_insert = false
  for _, v in ipairs(fdo) do
    if v == "insert" then
      has_insert = true
      break
    end
  end

  -- 3. Fold must be openable (verify fold infra works; `i` relies on this).
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  vim.api.nvim_win_call(winid, function()
    pcall(vim.cmd, "1foldopen")
  end)
  local fc_after_open = fold_closed_at(bufnr, 1)

  render.clear_buffer(bufnr)
  restore()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(fc_before, 1, "AC2: fold must be closed after render (default_folded=true)")
  eq(has_insert, true, "AC2: foldopen must include 'insert' so `i` opens the fold")
  eq(fc_after_open, -1, "AC2: fold must be openable (foldopen command succeeds)")
end

-- ── AC3: :w writes source-only; reopen preserves state ───────────────────────
-- Saving the buffer writes ONLY source content (queries + prose, no rendered
-- tasks) to disk.  Reopening the file shows the same visual state.

T["AC3: :w writes source-only content; reopen gives identical visual state"] = function()
  render.configure({ default_folded = true })
  local restore = install_one_task_stub("- [ ] AC3 task")

  -- Use a plain fence block with no prose header so the fence starts at line 1
  -- (1-indexed), keeping fold checks simple.
  local source_lines = { "```tasks", "not done", "```" }
  local bufnr = make_buf(source_lines)
  local winid = open_in_win(bufnr)

  -- render_buffer inserts the task line and registers managed regions.
  render.render_buffer(bufnr, nil)

  -- Buffer now has the query block + rendered task line.
  local rendered_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#rendered_lines > #source_lines, true)

  -- Save to a real file via on_write_cmd.
  -- render_buffer already called managed.add_block/add_region internally;
  -- no manual add_block needed here.
  local tmpfile = vim.fn.tempname() .. ".md"
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  -- Written file must contain ONLY source lines — no rendered task rows.
  local written = read_file(tmpfile)
  local has_task_in_written = false
  for _, l in ipairs(written) do
    if l:find("AC3 task") then
      has_task_in_written = true
      break
    end
  end

  -- Re-render a fresh buffer from the written file's source content.
  local bufnr2 = make_buf(written)
  local winid2 = open_in_win(bufnr2)
  render.render_buffer(bufnr2, nil)

  -- After re-render the fold at line 1 must be closed (fence starts at line 1).
  local fc_reopen = fold_closed_at(bufnr2, 1)

  -- Rendered lines of the second buffer must contain the task line again.
  local lines2 = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
  local task_found_after_reopen = false
  for _, l in ipairs(lines2) do
    if l:find("AC3 task") then
      task_found_after_reopen = true
      break
    end
  end

  -- Cleanup.
  render.clear_buffer(bufnr)
  render.clear_buffer(bufnr2)
  restore()
  close_win(winid)
  close_win(winid2)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.api.nvim_buf_delete(bufnr2, { force = true })
  vim.fn.delete(tmpfile)

  eq(has_task_in_written, false, "AC3: written file must not contain rendered task rows")
  eq(#written, #source_lines, "AC3: written file must have same line count as source")
  eq(fc_reopen, 1, "AC3: fold must be closed after reopening and re-rendering")
  eq(task_found_after_reopen, true, "AC3: task must appear in re-rendered buffer")
end

-- ── AC4: New block detection + fold preservation ─────────────────────────────
-- Typing a new ```tasks block and saving renders results beneath it and folds
-- the new block.  Other folds retain their open/closed state.

T["AC4: new block at end rendered + folded; existing open fold preserved"] = function()
  render.configure({ default_folded = true })
  local restore = install_one_task_stub("- [ ] AC4 task")

  -- Single-block buffer.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  -- Initial render: 1 block, fold at lines 1..4.
  render.render_buffer(bufnr, nil)

  -- Open block 1's fold so we can verify it stays open after rerender.
  vim.api.nvim_win_call(winid, function()
    pcall(vim.cmd, "1foldopen")
  end)
  local pre_fc1 = fold_closed_at(bufnr, 1) -- should be -1 (open)

  -- Append a new source block after the existing rendered content.
  -- Buffer is currently: fence(0-2), task(3).
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "```tasks", "done", "```" })

  -- Re-render (simulates BufWritePost after :w).
  render.rerender_buffer(bufnr, nil)

  -- After rerender with 1 task each:
  --   block 1 fold at line 1 (was open → stays open)
  --   block 2 fold at line 5 (new → default folded)
  local post_fc1 = fold_closed_at(bufnr, 1)
  local post_fc2 = fold_closed_at(bufnr, 5)

  render.clear_buffer(bufnr)
  restore()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(pre_fc1, -1, "AC4: precondition — block 1 fold was opened before rerender")
  eq(post_fc1, -1, "AC4: block 1 open fold must be preserved after rerender")
  eq(post_fc2, 5, "AC4: new block 2 must be rendered and folded by default")
end

-- ── AC5: Deleted block cleanup ────────────────────────────────────────────────
-- Deleting a ```tasks block and saving removes its rendered region cleanly;
-- the other block is unchanged.

T["AC5: deleted block region removed; surviving block unchanged"] = function()
  render.configure({ default_folded = true })
  local restore = install_zero_task_stub()

  -- Two-block buffer (zero tasks → no task lines, only folds).
  local bufnr = make_buf({
    "```tasks", -- block 1: rows 0-2
    "not done",
    "```",
    "```tasks", -- block 2: rows 3-5
    "done",
    "```",
  })
  local winid = open_in_win(bufnr)

  -- Initial render: both folds closed.
  render.render_buffer(bufnr, nil)
  local fc1_initial = fold_closed_at(bufnr, 1)
  local fc2_initial = fold_closed_at(bufnr, 4)

  -- Delete block 1 (rows 0-2, 0-indexed).
  vim.api.nvim_buf_set_lines(bufnr, 0, 3, false, {})

  -- Re-render: block 1's state must be cleaned up; block 2 must survive.
  local ok = pcall(render.rerender_buffer, bufnr, nil)

  -- Surviving block 2 is now at source pos 1; with 0 tasks it keeps its 3 lines.
  local post_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local post_fc = fold_closed_at(bufnr, 1) -- block 2 now at line 1

  render.clear_buffer(bufnr)
  restore()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(fc1_initial, 1, "AC5: precondition — block 1 was folded")
  eq(fc2_initial, 4, "AC5: precondition — block 2 was folded")
  eq(ok, true, "AC5: rerender_buffer must not error after block deletion")
  eq(#post_lines, 3, "AC5: only block 2's 3 source lines must remain")
  eq(post_fc, 1, "AC5: surviving block must be folded at line 1")
end

-- ── AC6: <leader>tt toggle + re-render ───────────────────────────────────────
-- `<leader>tt` on a rendered task line toggles its checkbox in the source file
-- and the dashboard re-renders to reflect it.

T["AC6: <leader>tt toggles source checkbox via managed meta"] = function()
  local task_text = "- [ ] AC6 toggle task"
  local src_path = make_tmpfile({ task_text })

  local dash_bufnr = make_buf({ task_text })

  -- Register managed task meta for row 0.
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text,
  })

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render_mod = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return dash_bufnr
  end

  keymap_mod.attach(dash_bufnr)

  local winid = vim.api.nvim_open_win(dash_bufnr, true, {
    relative = "editor",
    width = 80,
    height = 5,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  -- Find and invoke <leader>tt.
  local leader = vim.g.mapleader or "\\"
  local lhs_expanded = ("<leader>tt"):gsub("<[Ll]eader>", leader)
  local m = nil
  for _, km in ipairs(vim.api.nvim_buf_get_keymap(dash_bufnr, "n")) do
    if km.lhs == "<leader>tt" or km.lhs == lhs_expanded then
      m = km
      break
    end
  end
  eq(m ~= nil, true, "AC6: <leader>tt keymap must be registered")
  if m then
    m.callback()
  end

  vim.api.nvim_win_close(winid, true)
  restore_ot()
  restore_index()
  restore_render_mod()
  vim.api.nvim_get_current_buf = orig_gcb
  keymap_mod.detach(dash_bufnr)
  managed.clear_buffer(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })

  -- Verify source file was mutated: checkbox must now be `x`.
  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated_line
  if src_buf ~= -1 then
    mutated_line = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  else
    mutated_line = read_file(src_path)[1]
  end
  vim.fn.delete(src_path)

  eq(mutated_line ~= nil, true, "AC6: source line must not be nil after toggle")
  eq(mutated_line:sub(1, 5), "- [x]", "AC6: source checkbox must be toggled to [x]")
end

-- ── AC7: Typing in managed region reverts ────────────────────────────────────
-- Direct typing on a rendered task line is reverted on next render.
-- Verified synchronously via revert._flush_pending (see mini.test async caveat).

T["AC7: direct edit on rendered task line reverts to canonical text"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] AC7 task")

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  render.render_buffer(bufnr, nil)

  -- Rendered buffer: fence(0-2), task(3).
  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  MiniTest.expect.equality(canonical ~= nil and canonical:find("AC7 task") ~= nil, true)

  -- Capture pre-corruption line count for post-revert comparison.
  local pre_corrupt_count = vim.api.nvim_buf_line_count(bufnr)

  -- Corrupt the task line (replace, not add — same line count).
  vim.api.nvim_buf_set_lines(bufnr, task_row, task_row + 1, false, { "CORRUPTED_AC7" })
  eq(get_line(bufnr, task_row), "CORRUPTED_AC7")
  eq(revert._debug_state(bufnr).scheduled, true)

  -- Flush the pending revert synchronously.
  revert._flush_pending(bufnr)

  -- 1. Line at task_row must be back to canonical.
  local final = get_line(bufnr, task_row)
  MiniTest.expect.equality(final ~= nil and final:find("AC7 task") ~= nil, true)
  eq(revert._debug_state(bufnr).scheduled, false)

  -- 2. CORRUPTED_AC7 must be absent from every line of the buffer.
  local all_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local corrupted_found = false
  for _, l in ipairs(all_lines) do
    if l == "CORRUPTED_AC7" then
      corrupted_found = true
      break
    end
  end
  eq(corrupted_found, false, "AC7: CORRUPTED_AC7 must be absent from buffer after revert")

  -- 3. Line count must match pre-corruption state (revert must not leave orphan lines).
  eq(#all_lines, pre_corrupt_count, "AC7: line count must match pre-corruption state after revert")

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── AC8: Render pipeline does not use Neovim conceal mechanisms ───────────────
-- F9 replaced the conceal-based rendering (F4) with real buffer text.
-- Verified at runtime: render_buffer must not change conceallevel and must not
-- attach any extmark with a conceal_lines field.

T["AC8: render does not set conceallevel or apply conceal_lines extmarks"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] AC8 task")

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = open_in_win(bufnr)

  local before_cl = vim.api.nvim_win_get_option(winid, "conceallevel")

  render.render_buffer(bufnr, nil)

  -- conceallevel must be unchanged (render never touches it).
  local after_cl = vim.api.nvim_win_get_option(winid, "conceallevel")
  eq(after_cl, before_cl, "AC8: render must not change conceallevel")

  -- No extmark in any plugin namespace should have a conceal_lines field.
  local NS = require("obsidian-tasks.util.extmark").NS
  local managed_ns = managed.namespace()
  local has_conceal = false
  for _, ns in ipairs({ NS, managed_ns }) do
    local ems = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
    for _, em in ipairs(ems) do
      if em[4] and em[4].conceal_lines ~= nil then
        has_conceal = true
      end
    end
  end

  render.clear_buffer(bufnr)
  restore()
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(has_conceal, false, "AC8: no extmark must have a conceal_lines field")
end

-- ── AC9: F4 removed ──────────────────────────────────────────────────────────
-- render/edit.lua does not exist.
-- No BufWritePre autocmd is registered by the plugin (plugin uses BufWriteCmd).

T["AC9: render/edit.lua does not exist"] = function()
  -- Locate the plugin's lua directory.
  local plugin_dir = nil
  for _, path in ipairs(vim.api.nvim_list_runtime_paths()) do
    local candidate = path .. "/lua/obsidian-tasks/render/edit.lua"
    if vim.fn.filereadable(candidate) == 1 then
      plugin_dir = candidate
      break
    end
  end
  -- Also check relative to the current working directory (worktree context).
  local cwd_candidate = vim.fn.getcwd() .. "/lua/obsidian-tasks/render/edit.lua"
  local exists_in_cwd = vim.fn.filereadable(cwd_candidate) == 1

  eq(plugin_dir, nil, "AC9: render/edit.lua must not exist in any runtimepath")
  eq(exists_in_cwd, false, "AC9: render/edit.lua must not exist in cwd")
end

T["AC9: no BufWritePre autocmd registered by obsidian-tasks"] = function()
  -- Check that no autocmd group owned by this plugin uses BufWritePre.
  -- The plugin uses BufWriteCmd (registered per-buffer by save.attach).
  local groups = vim.api.nvim_get_autocmds({ event = "BufWritePre" })
  local plugin_bwp = false
  for _, ac in ipairs(groups) do
    -- Plugin autocmds will have a group name or callback from our modules.
    if ac.group_name and ac.group_name:find("obsidian.tasks", 1, true) then
      plugin_bwp = true
    end
    if ac.group_name and ac.group_name:find("ObsidianTasks", 1, true) then
      plugin_bwp = true
    end
  end

  eq(plugin_bwp, false, "AC9: plugin must not register BufWritePre autocmds (uses BufWriteCmd)")
end

T["AC9: User:ObsidianNoteWritePre autocmd not present (F4 removed)"] = function()
  -- F4's diff+patch+strip ran on User:ObsidianNoteWritePre.
  -- After removal, no autocmd handler for this event should reference the
  -- old render/edit module.
  local acs = vim.api.nvim_get_autocmds({ event = "User", pattern = "ObsidianNoteWritePre" })
  -- Any remaining handler (from obsidian.nvim itself) must not come from render/edit.
  local edit_handler_found = false
  for _, ac in ipairs(acs) do
    -- Our removed handler had no group; any callback source check here.
    -- Heuristic: if a BufWritePre-equivalent edit module is referenced, fail.
    if ac.desc and ac.desc:find("render/edit", 1, true) then
      edit_handler_found = true
    end
  end
  eq(edit_handler_found, false, "AC9: no render/edit handler on ObsidianNoteWritePre")
end

-- ── AC10: :ObsidianTask <subcmd> works on rendered rows ──────────────────────
-- :ObsidianTask done on a rendered task row marks it done in source.
-- :ObsidianTask priority on a rendered row sets priority on source.

T["AC10: :ObsidianTask done on rendered row mutates source"] = function()
  local task_text = "- [ ] AC10 done task"
  local src_path = make_tmpfile({ task_text })

  local dash_bufnr = make_buf({ task_text })
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text,
  })

  -- Stub render so dispatch_and_refresh doesn't try to call obsidian.nvim.
  local restore_render_mod = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return dash_bufnr
  end

  -- Create a window with cursor on row 1 (rendered task).
  local winid = vim.api.nvim_open_win(dash_bufnr, true, {
    relative = "editor",
    width = 80,
    height = 5,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  -- Dispatch :ObsidianTask done via the cmd resolver.
  local cmd = require("obsidian-tasks.cmd")
  cmd.dispatch({ fargs = { "done" }, line1 = 1, line2 = 1 })

  vim.api.nvim_win_close(winid, true)
  restore_render_mod()
  restore_index()
  vim.api.nvim_get_current_buf = orig_gcb
  managed.clear_buffer(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })

  -- Source must now have [x] checkbox.
  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated
  if src_buf ~= -1 then
    mutated = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  else
    mutated = read_file(src_path)[1]
  end
  vim.fn.delete(src_path)

  eq(mutated ~= nil, true, "AC10: source line must not be nil")
  eq(mutated:sub(1, 5), "- [x]", "AC10: :done must set [x] checkbox in source")
end

T["AC10: :ObsidianTask priority cycle on rendered row sets priority in source"] = function()
  local task_text = "- [ ] AC10 priority task"
  local src_path = make_tmpfile({ task_text })

  local dash_bufnr = make_buf({ task_text })
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text,
  })

  local restore_render_mod = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return dash_bufnr
  end

  local winid = vim.api.nvim_open_win(dash_bufnr, true, {
    relative = "editor",
    width = 80,
    height = 5,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local cmd = require("obsidian-tasks.cmd")
  cmd.dispatch({ fargs = { "priority", "cycle" }, line1 = 1, line2 = 1 })

  vim.api.nvim_win_close(winid, true)
  restore_render_mod()
  restore_index()
  vim.api.nvim_get_current_buf = orig_gcb
  managed.clear_buffer(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })

  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated
  if src_buf ~= -1 then
    mutated = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  else
    mutated = read_file(src_path)[1]
  end
  vim.fn.delete(src_path)

  local fields = require("obsidian-tasks.task.fields")
  eq(mutated ~= nil, true, "AC10: source line must not be nil")
  -- none → highest: task must now contain 🔺 priority.
  MiniTest.expect.equality(
    mutated:find(fields.priority_levels.highest, 1, true) ~= nil,
    true,
    "AC10: priority cycle must add highest priority to source"
  )
end

return T
