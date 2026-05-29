-- tests/unit/test_cmd_misc.lua
-- Tests for misc subcommands: refresh, render, new.
-- Also covers cross-context and feature-verification scenarios:
--   • Dispatcher routing for all 15 subcommands
--   • Tab-completion: all 15 subcmds returned
--   • Source-buffer integration: :ObsidianTask done mutates buffer
--   • Visual-range integration: 5 tasks all marked done
--   • Priority dataview-format input (coverage gap from ot-btn3 discovery)
--
-- Covers:
--   refresh: calls render.refresh_buffer with current bufnr
--   refresh: safe when no render active (stub no-ops without error)
--   render: calls render.render_buffer with current bufnr
--   render: safe on buffer with no tasks block (stub no-ops without error)
--   new: empty line, col 0 → inserts "- [ ] " at column 0
--   new: non-empty line, cursor at end → appends "- [ ] " after existing text
--   new: cursor mid-line → appends "- [ ] " at end of line
--   new: cursor past end of line → inserts "- [ ] " at cursor column (space-padded)
--   new: calls startinsert! after inserting
--   new: cursor positioned after marker
--   priority: dataview-format input preserved on overwrite (gap fill)
--   priority: dataview origin preserved when setting new level
--   dispatcher: all 15 subcommands route without error
--   completion: all 15 subcmds included in empty-prefix result

local T = MiniTest.new_set()

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Swap package.loaded[name] for mock; return cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Create a scratch buffer pre-populated with lines.
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Read all lines from a buffer.
local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Mock draw.is_render_line to return nil (source-buffer context).
local function mock_source_ctx()
  return install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })
end

--- Mock nvim_get_current_buf to return bufnr.
local function mock_current_buf(bufnr)
  local orig = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  return function()
    vim.api.nvim_get_current_buf = orig
  end
end

--- Mock nvim_win_get_cursor to return {row, col} (1-indexed row, 0-indexed col).
local function mock_cursor(row, col)
  local orig = vim.api.nvim_win_get_cursor
  vim.api.nvim_win_get_cursor = function()
    return { row, col }
  end
  return function()
    vim.api.nvim_win_get_cursor = orig
  end
end

--- Capture vim.notify calls during f(); return list of {msg, level}.
local function capture_notify(f)
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    calls[#calls + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(f)
  vim.notify = orig
  if not ok then
    error(err, 2)
  end
  return calls
end

--- Suppress startinsert / startinsert! calls (headless nvim has no insert mode).
--- Returns cleanup function.
local function suppress_startinsert()
  local orig = vim.cmd
  vim.cmd = function(c)
    if type(c) == "string" and c:match("startinsert") then
      return
    end
    orig(c)
  end
  return function()
    vim.cmd = orig
  end
end

--- Suppress both startinsert! and nvim_win_set_cursor (for new command tests).
--- The test window does not have the test buffer loaded, so set_cursor with
--- row > 1 fails with "Cursor position outside buffer".
--- Returns cleanup function.
local function suppress_new_side_effects()
  local orig_cmd = vim.cmd
  local orig_set_cursor = vim.api.nvim_win_set_cursor
  vim.cmd = function(c)
    if type(c) == "string" and c:match("startinsert") then
      return
    end
    orig_cmd(c)
  end
  vim.api.nvim_win_set_cursor = function() end
  return function()
    vim.cmd = orig_cmd
    vim.api.nvim_win_set_cursor = orig_set_cursor
  end
end

--- Suppress vim.cmd("edit …") and nvim_win_set_cursor; capture their args.
--- Returns { edit_path, cursor_pos }, cleanup.
local function capture_jump()
  local captured = { edit_path = nil, cursor_pos = nil }
  local orig_cmd = vim.cmd
  local orig_cursor = vim.api.nvim_win_set_cursor

  vim.cmd = function(c)
    if type(c) == "string" and c:match("^edit ") then
      captured.edit_path = c:match("^edit (.+)")
    else
      orig_cmd(c)
    end
  end
  vim.api.nvim_win_set_cursor = function(_win, pos)
    captured.cursor_pos = pos
  end

  return captured, function()
    vim.cmd = orig_cmd
    vim.api.nvim_win_set_cursor = orig_cursor
  end
end

-- ════════════════════════════════════════════════════════════════════════════
-- refresh
-- ════════════════════════════════════════════════════════════════════════════

T["refresh: calls render.refresh_buffer with current bufnr"] = function()
  local bufnr = make_buf({ "- [ ] Task" })
  local buf_cleanup = mock_current_buf(bufnr)

  -- refresh cmd now calls rerender_buffer (fold-state-preserving).
  local called_bufnr = nil
  local render_cleanup = install_mock("obsidian-tasks.render", {
    rerender_buffer = function(b)
      called_bufnr = b
    end,
  })
  -- Stub util.obsidian so workspace lookup doesn't require obsidian.nvim.
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return nil
    end,
  })

  require("obsidian-tasks.cmd.refresh").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(called_bufnr, bufnr)
end

T["refresh: forwards resolved workspace to refresh_buffer"] = function()
  local fake_ws = { root = "/vault", name = "test-vault" }
  local bufnr = make_buf({ "```tasks", "```" })
  local buf_cleanup = mock_current_buf(bufnr)

  -- refresh cmd now calls rerender_buffer (fold-state-preserving).
  local called_ws = "UNSET"
  local render_cleanup = install_mock("obsidian-tasks.render", {
    rerender_buffer = function(_b, ws)
      called_ws = ws
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return fake_ws
    end,
  })

  require("obsidian-tasks.cmd.refresh").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(called_ws, fake_ws)
end

T["refresh: passes nil workspace when obsidian not ready (safe fallback)"] = function()
  -- Simulates obsidian.nvim not yet set up: workspace_for_path raises.
  local bufnr = make_buf({ "- [ ] Task" })
  local buf_cleanup = mock_current_buf(bufnr)

  -- refresh cmd now calls rerender_buffer (fold-state-preserving).
  local called_ws = "UNSET"
  local render_cleanup = install_mock("obsidian-tasks.render", {
    rerender_buffer = function(_b, ws)
      called_ws = ws
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      error("obsidian not ready")
    end,
  })

  local ok, err = pcall(function()
    require("obsidian-tasks.cmd.refresh").run({}, { line1 = 1, line2 = 1 })
  end)

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Must not propagate the error.
  MiniTest.expect.equality(ok, true, "refresh must not raise on obsidian error: " .. tostring(err))
  -- Must call rerender_buffer with nil workspace (graceful degradation).
  MiniTest.expect.equality(called_ws, nil)
end

T["refresh: safe when render.refresh_buffer is a no-op (no error raised)"] = function()
  local bufnr = make_buf({ "plain text, no tasks block" })
  local buf_cleanup = mock_current_buf(bufnr)

  -- refresh cmd now calls rerender_buffer.
  local render_cleanup = install_mock("obsidian-tasks.render", {
    rerender_buffer = function() end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return nil
    end,
  })

  local ok, err = pcall(function()
    require("obsidian-tasks.cmd.refresh").run({}, { line1 = 1, line2 = 1 })
  end)

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(ok, true, "refresh should not raise: " .. tostring(err))
end

T["refresh: ignores args and range (whole-buffer operation)"] = function()
  local bufnr = make_buf({ "```tasks", "```" })
  local buf_cleanup = mock_current_buf(bufnr)

  -- refresh cmd now calls rerender_buffer.
  local call_count = 0
  local render_cleanup = install_mock("obsidian-tasks.render", {
    rerender_buffer = function()
      call_count = call_count + 1
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return nil
    end,
  })

  require("obsidian-tasks.cmd.refresh").run({ "extra" }, { line1 = 1, line2 = 99 })

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(call_count, 1)
end

-- ════════════════════════════════════════════════════════════════════════════
-- render
-- ════════════════════════════════════════════════════════════════════════════

T["render: calls render.render_buffer with current bufnr"] = function()
  local bufnr = make_buf({ "```tasks", "```" })
  local buf_cleanup = mock_current_buf(bufnr)

  local called_bufnr = nil
  local render_cleanup = install_mock("obsidian-tasks.render", {
    render_buffer = function(b)
      called_bufnr = b
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return nil
    end,
  })

  require("obsidian-tasks.cmd.render").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(called_bufnr, bufnr)
end

T["render: forwards resolved workspace to render_buffer"] = function()
  local fake_ws = { root = "/vault", name = "test-vault" }
  local bufnr = make_buf({ "```tasks", "```" })
  local buf_cleanup = mock_current_buf(bufnr)

  local called_ws = "UNSET"
  local render_cleanup = install_mock("obsidian-tasks.render", {
    render_buffer = function(_b, ws)
      called_ws = ws
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return fake_ws
    end,
  })

  require("obsidian-tasks.cmd.render").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(called_ws, fake_ws)
end

T["render: passes nil workspace when obsidian not ready (safe fallback)"] = function()
  -- Simulates obsidian.nvim not yet set up: workspace_for_path raises.
  local bufnr = make_buf({ "```tasks", "```" })
  local buf_cleanup = mock_current_buf(bufnr)

  local called_ws = "UNSET"
  local render_cleanup = install_mock("obsidian-tasks.render", {
    render_buffer = function(_b, ws)
      called_ws = ws
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      error("obsidian not ready")
    end,
  })

  local ok, err = pcall(function()
    require("obsidian-tasks.cmd.render").run({}, { line1 = 1, line2 = 1 })
  end)

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(ok, true, "render must not raise on obsidian error: " .. tostring(err))
  MiniTest.expect.equality(called_ws, nil)
end

T["render: safe on buffer with no tasks block (no error)"] = function()
  local bufnr = make_buf({ "# Just a heading", "- [ ] Task" })
  local buf_cleanup = mock_current_buf(bufnr)

  local render_cleanup = install_mock("obsidian-tasks.render", {
    render_buffer = function() end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return nil
    end,
  })

  local ok, err = pcall(function()
    require("obsidian-tasks.cmd.render").run({}, { line1 = 1, line2 = 1 })
  end)

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(ok, true, "render should not raise: " .. tostring(err))
end

T["render: ignores args and range (whole-buffer operation)"] = function()
  local bufnr = make_buf({ "```tasks", "```" })
  local buf_cleanup = mock_current_buf(bufnr)

  local call_count = 0
  local render_cleanup = install_mock("obsidian-tasks.render", {
    render_buffer = function()
      call_count = call_count + 1
    end,
  })
  local oa_cleanup = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function()
      return nil
    end,
  })

  require("obsidian-tasks.cmd.render").run({ "ignored" }, { line1 = 5, line2 = 10 })

  buf_cleanup()
  render_cleanup()
  oa_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(call_count, 1)
end

-- ════════════════════════════════════════════════════════════════════════════
-- goto
-- ════════════════════════════════════════════════════════════════════════════

T["goto: render line → jumps to source_file at source_row+1"] = function()
  local fake_meta = { source_file = "/vault/note.md", source_row = 4, task_text = "- [ ] Rendered" }
  local managed_cleanup = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return fake_meta
    end,
  })
  local bufnr = make_buf({ "- [ ] Rendered" })
  local buf_cleanup = mock_current_buf(bufnr)
  local captured, jump_cleanup = capture_jump()

  require("obsidian-tasks.cmd.goto").run({}, { line1 = 1, line2 = 1 })

  managed_cleanup()
  buf_cleanup()
  jump_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(captured.edit_path ~= nil, true)
  MiniTest.expect.equality(captured.edit_path:find("note%.md") ~= nil, true)
  -- source_row=4 (0-indexed) → row 5 (1-indexed).
  MiniTest.expect.equality(captured.cursor_pos[1], 5)
end

T["goto: non-render line → emits log.info, no jump"] = function()
  local managed_cleanup = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return nil
    end,
  })
  local bufnr = make_buf({ "- [ ] Source task" })
  local buf_cleanup = mock_current_buf(bufnr)
  local captured, jump_cleanup = capture_jump()

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.goto").run({}, { line1 = 1, line2 = 1 })
  end)

  managed_cleanup()
  buf_cleanup()
  jump_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(captured.edit_path, nil)
  local found_info = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.INFO and tostring(c.msg):find("no rendered task", 1, true) then
      found_info = true
    end
  end
  MiniTest.expect.equality(found_info, true)
end

T["goto: drift → emits info, still jumps"] = function()
  -- Write a real source file with content differing from meta.task_text.
  local src_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [x] Toggled externally" }, src_path)

  local managed_cleanup = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = "- [ ] Original" }
    end,
  })
  local bufnr = make_buf({ "rendered line" })
  local buf_cleanup = mock_current_buf(bufnr)
  local captured, jump_cleanup = capture_jump()

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.goto").run({}, { line1 = 1, line2 = 1 })
  end)

  managed_cleanup()
  buf_cleanup()
  jump_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  -- Must still have jumped.
  MiniTest.expect.equality(captured.edit_path ~= nil, true)
  -- Must have emitted an INFO notice about stale position.
  local found_info = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.INFO and tostring(c.msg):find("stale", 1, true) then
      found_info = true
    end
  end
  MiniTest.expect.equality(found_info, true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- new
-- ════════════════════════════════════════════════════════════════════════════

T["new: empty line, col 0 → inserts '- [ ] ' at beginning"] = function()
  local bufnr = make_buf({ "" })
  local buf_cleanup = mock_current_buf(bufnr)
  local cursor_cleanup = mock_cursor(1, 0) -- row=1, col=0
  local fx_cleanup = suppress_new_side_effects()

  require("obsidian-tasks.cmd.new").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  cursor_cleanup()
  fx_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "- [ ] ")
end

T["new: cursor at end of non-empty line → appends '- [ ] '"] = function()
  local line = "Some text"
  local bufnr = make_buf({ line })
  local buf_cleanup = mock_current_buf(bufnr)
  -- col = #line means cursor is at end
  local cursor_cleanup = mock_cursor(1, #line)
  local fx_cleanup = suppress_new_side_effects()

  require("obsidian-tasks.cmd.new").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  cursor_cleanup()
  fx_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "Some text- [ ] ")
end

T["new: cursor mid-line → appends '- [ ] ' at end"] = function()
  local line = "Some text here"
  local bufnr = make_buf({ line })
  local buf_cleanup = mock_current_buf(bufnr)
  -- col = 4 (mid-line)
  local cursor_cleanup = mock_cursor(1, 4)
  local fx_cleanup = suppress_new_side_effects()

  require("obsidian-tasks.cmd.new").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  cursor_cleanup()
  fx_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Mid-line: inserted at end of the existing text.
  MiniTest.expect.equality(lines[1], "Some text here- [ ] ")
end

T["new: cursor past end of line → space-pads and inserts at cursor column"] = function()
  local line = "abc"
  local bufnr = make_buf({ line })
  local buf_cleanup = mock_current_buf(bufnr)
  -- col = 6 (past end of 3-char line)
  local cursor_cleanup = mock_cursor(1, 6)
  local fx_cleanup = suppress_new_side_effects()

  require("obsidian-tasks.cmd.new").run({}, { line1 = 1, line2 = 1 })

  buf_cleanup()
  cursor_cleanup()
  fx_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- "abc" + "   " (3 spaces to reach col 6) + "- [ ] "
  MiniTest.expect.equality(lines[1], "abc   - [ ] ")
end

T["new: calls startinsert! (enters insert mode)"] = function()
  local bufnr = make_buf({ "" })
  local buf_cleanup = mock_current_buf(bufnr)
  local cursor_cleanup = mock_cursor(1, 0)

  local startinsert_called = false
  local orig_cmd = vim.cmd
  vim.cmd = function(c)
    if type(c) == "string" and c:match("startinsert") then
      startinsert_called = true
      return
    end
    orig_cmd(c)
  end

  require("obsidian-tasks.cmd.new").run({}, { line1 = 1, line2 = 1 })

  vim.cmd = orig_cmd
  buf_cleanup()
  cursor_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(startinsert_called, true)
end

T["new: positions cursor after the marker"] = function()
  local bufnr = make_buf({ "" })
  local buf_cleanup = mock_current_buf(bufnr)
  local cursor_cleanup = mock_cursor(1, 0)

  local set_cursor_called = false
  local set_cursor_pos = nil
  local orig_set_cursor = vim.api.nvim_win_set_cursor
  vim.api.nvim_win_set_cursor = function(_win, pos)
    set_cursor_called = true
    set_cursor_pos = pos
  end

  local si_cleanup = suppress_startinsert()

  require("obsidian-tasks.cmd.new").run({}, { line1 = 1, line2 = 1 })

  vim.api.nvim_win_set_cursor = orig_set_cursor
  si_cleanup()
  buf_cleanup()
  cursor_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(set_cursor_called, true)
  -- Cursor should be at col = 0 + #"- [ ] " = 6
  MiniTest.expect.equality(set_cursor_pos ~= nil, true)
  MiniTest.expect.equality(set_cursor_pos[2], 6)
end

T["new: works on line 2 of multi-line buffer"] = function()
  local bufnr = make_buf({ "first line", "" })
  local buf_cleanup = mock_current_buf(bufnr)
  local cursor_cleanup = mock_cursor(2, 0) -- row=2, col=0
  -- suppress_new_side_effects prevents nvim_win_set_cursor failing because
  -- the test window's buffer only has 1 line (test bufnr is not the window buf).
  local fx_cleanup = suppress_new_side_effects()

  require("obsidian-tasks.cmd.new").run({}, { line1 = 2, line2 = 2 })

  buf_cleanup()
  cursor_cleanup()
  fx_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "first line") -- unchanged
  MiniTest.expect.equality(lines[2], "- [ ] ")
end

-- ════════════════════════════════════════════════════════════════════════════
-- Priority dataview-format (gap fill from ot-btn3 feature note)
-- ════════════════════════════════════════════════════════════════════════════

T["priority: dataview-format input: level preserved as dataview on overwrite"] = function()
  -- A task with priority encoded as [priority:: high] (dataview origin).
  local line = "- [ ] My task [priority:: high]"
  local bufnr = make_buf({ line })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "medium" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Serialization should preserve the dataview origin.
  MiniTest.expect.equality(lines[1]:find("%[priority::%s*medium%]") ~= nil, true)
  -- Old level must be gone.
  MiniTest.expect.equality(lines[1]:find("%[priority::%s*high%]") == nil, true)
end

T["priority: dataview-format input: 'none' removes dataview priority field"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local line = "- [ ] My task [priority:: low]"
  local bufnr = make_buf({ line })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "none" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- No dataview priority token.
  MiniTest.expect.equality(lines[1]:find("%[priority::") == nil, true)
  -- No emoji priority either.
  for _, emoji in pairs(fields.priority_levels) do
    MiniTest.expect.equality(lines[1]:find(emoji, 1, true) == nil, true)
  end
end

T["priority: dataview-format: new priority field defaults to emoji when _origin absent"] = function()
  -- Plain task with no existing priority.
  local fields = require("obsidian-tasks.task.fields")
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "high" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Default origin is emoji when not specified.
  MiniTest.expect.equality(lines[1]:find(fields.priority_levels.high, 1, true) ~= nil, true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Cross-context: source-buffer integration (feature verification)
-- ════════════════════════════════════════════════════════════════════════════

T["source-buffer integration: done mutates single source task correctly"] = function()
  -- Simulate a source-buffer note with a task (no render context).
  local bufnr = make_buf({ "- [ ] Write report" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  -- Freeze os.date for determinism.
  local orig_date = os.date
  os.date = function(_fmt)
    return "2024-06-01"
  end

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 1 })

  os.date = orig_date
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Status x + done stamp.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
  MiniTest.expect.equality(lines[1]:find("2024%-06%-01") ~= nil, true)
end

T["source-buffer integration: cancel mutates single source task correctly"] = function()
  local bufnr = make_buf({ "- [ ] Fix bug" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_date = os.date
  os.date = function()
    return "2024-06-02"
  end

  require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 1 })

  os.date = orig_date
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [-]")
  MiniTest.expect.equality(lines[1]:find("2024%-06%-02") ~= nil, true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Cross-context: visual-range bulk integration (feature verification)
-- ════════════════════════════════════════════════════════════════════════════

T["visual-range integration: done on 5 tasks → all marked done with stamps"] = function()
  local task_lines = {
    "- [ ] Task one",
    "- [ ] Task two",
    "- [ ] Task three",
    "- [ ] Task four",
    "- [ ] Task five",
  }
  local bufnr = make_buf(task_lines)
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_date = os.date
  os.date = function()
    return "2024-07-04"
  end

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 5 })

  os.date = orig_date
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#lines, 5)
  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:sub(1, 5), "- [x]", "line " .. i .. " not done")
    MiniTest.expect.equality(line:find("2024%-07%-04") ~= nil, true, "line " .. i .. " missing stamp")
  end
end

T["visual-range integration: cancel on 5 tasks → all marked cancelled"] = function()
  local task_lines = {
    "- [ ] Task A",
    "- [ ] Task B",
    "- [ ] Task C",
    "- [ ] Task D",
    "- [ ] Task E",
  }
  local bufnr = make_buf(task_lines)
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_date = os.date
  os.date = function()
    return "2024-07-05"
  end

  require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 5 })

  os.date = orig_date
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#lines, 5)
  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:sub(1, 5), "- [-]", "line " .. i .. " not cancelled")
    MiniTest.expect.equality(line:find("2024%-07%-05") ~= nil, true, "line " .. i .. " missing stamp")
  end
end

T["visual-range integration: done skips non-task lines"] = function()
  local bufnr = make_buf({
    "- [ ] Task one",
    "## heading",
    "plain text",
    "- [ ] Task two",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_date = os.date
  os.date = function()
    return "2024-07-06"
  end

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 4 })

  os.date = orig_date
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
  MiniTest.expect.equality(lines[2], "## heading")
  MiniTest.expect.equality(lines[3], "plain text")
  MiniTest.expect.equality(lines[4]:sub(1, 5), "- [x]")
end

-- ════════════════════════════════════════════════════════════════════════════
-- Dispatcher: all 15 subcommands route correctly (feature verification)
-- ════════════════════════════════════════════════════════════════════════════

T["dispatcher: all 18 subcommands route without 'unknown' error"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local subcmds = {
    "toggle",
    "done",
    "cancel",
    "inProgress",
    "onHold",
    "due",
    "scheduled",
    "start",
    "priority",
    "recurrence",
    "tags",
    "postpone",
    "id",
    "refresh",
    "render",
    "new",
    "goto",
    "quickfix",
  }

  for _, name in ipairs(subcmds) do
    local key = "obsidian-tasks.cmd." .. name
    local orig = package.loaded[key]
    package.loaded[key] = { run = function() end }

    local notify_calls = capture_notify(function()
      cmd.dispatch({ fargs = { name }, line1 = 1, line2 = 1 })
    end)

    package.loaded[key] = orig

    for _, c in ipairs(notify_calls) do
      if c.level == vim.log.levels.ERROR and c.msg:find("unknown") then
        error("unexpected 'unknown' error for subcmd: " .. name)
      end
    end
  end
end

T["dispatcher: render subcmd calls render.run"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local called = false
  local key = "obsidian-tasks.cmd.render"
  local orig = package.loaded[key]
  package.loaded[key] = {
    run = function()
      called = true
    end,
  }

  cmd.dispatch({ fargs = { "render" }, line1 = 1, line2 = 1 })

  package.loaded[key] = orig

  MiniTest.expect.equality(called, true)
end

T["dispatcher: refresh subcmd calls refresh.run"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local called = false
  local key = "obsidian-tasks.cmd.refresh"
  local orig = package.loaded[key]
  package.loaded[key] = {
    run = function()
      called = true
    end,
  }

  cmd.dispatch({ fargs = { "refresh" }, line1 = 1, line2 = 1 })

  package.loaded[key] = orig

  MiniTest.expect.equality(called, true)
end

T["dispatcher: new subcmd calls new.run"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local called = false
  local key = "obsidian-tasks.cmd.new"
  local orig = package.loaded[key]
  package.loaded[key] = {
    run = function()
      called = true
    end,
  }

  cmd.dispatch({ fargs = { "new" }, line1 = 1, line2 = 1 })

  package.loaded[key] = orig

  MiniTest.expect.equality(called, true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- Tab completion: all 16 subcmds returned (feature verification)
-- ════════════════════════════════════════════════════════════════════════════

T["completion: all 18 subcommands present in empty-prefix result"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("", "ObsidianTask ", 13)

  local expected = {
    "toggle",
    "done",
    "cancel",
    "inProgress",
    "onHold",
    "due",
    "scheduled",
    "start",
    "priority",
    "recurrence",
    "tags",
    "postpone",
    "id",
    "refresh",
    "render",
    "new",
    "goto",
    "quickfix",
  }

  MiniTest.expect.equality(#result, #expected)

  local result_set = {}
  for _, v in ipairs(result) do
    result_set[v] = true
  end
  for _, name in ipairs(expected) do
    MiniTest.expect.equality(result_set[name] == true, true, "missing subcmd: " .. name)
  end
end

T["completion: 'refresh', 'render', 'new', 'goto' all appear"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("", "ObsidianTask ", 13)
  local result_set = {}
  for _, v in ipairs(result) do
    result_set[v] = true
  end
  MiniTest.expect.equality(result_set["refresh"], true)
  MiniTest.expect.equality(result_set["render"], true)
  MiniTest.expect.equality(result_set["new"], true)
  MiniTest.expect.equality(result_set["goto"], true)
end

T["completion: prefix 're' returns {refresh, render, recurrence}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("re", "ObsidianTask re", 15)
  local result_set = {}
  for _, v in ipairs(result) do
    result_set[v] = true
  end
  MiniTest.expect.equality(result_set["refresh"], true)
  MiniTest.expect.equality(result_set["render"], true)
  MiniTest.expect.equality(result_set["recurrence"], true)
  -- Others must not be present.
  MiniTest.expect.equality(result_set["done"], nil)
end

T["completion: prefix 'n' returns {new}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("n", "ObsidianTask n", 14)
  MiniTest.expect.equality(#result, 1)
  MiniTest.expect.equality(result[1], "new")
end

return T
