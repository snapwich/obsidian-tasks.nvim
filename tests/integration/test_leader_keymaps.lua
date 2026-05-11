-- tests/integration/test_leader_keymaps.lua
-- Integration tests for the T7 leader keymaps and cmd resolver.
--
-- Tests the full pipeline from managed.add_task → task_meta_for_row →
-- cmd.resolve_task_at → subcommand mutation → source file write.
--
-- These tests use real managed state (no mocking of managed module) to verify
-- that the extmark-based resolver, drift detection, and keymap handlers work
-- end-to-end.  obsidian.nvim and the index are stubbed where needed.

local T = MiniTest.new_set()

local managed = require("obsidian-tasks.render.managed")
local cmd = require("obsidian-tasks.cmd")
local keymap_mod = require("obsidian-tasks.render.keymap")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

--- Install *mock* at *name* in package.loaded; return a cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Write lines to a temporary file; return its path.
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

--- Find a buffer-local normal-mode map by lhs (handles <leader> expansion).
--- @param bufnr integer
--- @param lhs   string
--- @return table|nil
local function find_nmap(bufnr, lhs)
  local leader = vim.g.mapleader or "\\"
  local expanded = lhs:gsub("<[Ll]eader>", leader)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs or m.lhs == expanded then
      return m
    end
  end
  return nil
end

--- Capture vim.notify calls during f(); return list of {msg, level}.
--- @param f fun()
--- @return table[]
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

-- ── resolve_task_at: render mode ──────────────────────────────────────────────

T["resolve_task_at: render row with task_meta → kind='render', source bufnr/lnum"] = function()
  local task_text = "- [ ] Integration task"
  local src_path = make_tmpfile({ task_text })

  -- Dashboard buffer with a rendered task line.
  local dash_bufnr = make_buf({ task_text })

  -- Register managed task meta for row 0.
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0, -- 0-indexed
    task_text = task_text,
  })

  local resolved = cmd.resolve_task_at(dash_bufnr, 0)

  -- Cleanup
  managed.clear_buffer(dash_bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(src_path)

  eq(resolved ~= nil, true)
  eq(resolved.kind, "render")
  eq(resolved.lnum, 0)
  eq(resolved.task ~= nil, true)
  eq(resolved.src_path, src_path)
end

T["resolve_task_at: drift detected → returns nil, emits warn"] = function()
  local task_text = "- [ ] Original task"
  -- Source file has been externally edited.
  local src_path = make_tmpfile({ "- [x] Done by external editor" })

  local dash_bufnr = make_buf({ task_text })
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text, -- meta still says original
  })

  local resolved = nil
  local notify_calls = capture_notify(function()
    resolved = cmd.resolve_task_at(dash_bufnr, 0)
  end)

  -- Cleanup
  managed.clear_buffer(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(src_path)

  -- Resolver must refuse on drift.
  eq(resolved, nil)
  -- Must have emitted a warning about drift.
  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("drift", 1, true) then
      found_warn = true
      break
    end
  end
  eq(found_warn, true)
end

T["resolve_task_at: no task_meta on row → falls back to source mode"] = function()
  -- No managed state registered: resolver should parse the raw buffer line.
  local bufnr = make_buf({ "- [ ] Source task" })

  local resolved = cmd.resolve_task_at(bufnr, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(resolved ~= nil, true)
  eq(resolved.kind, "source")
  eq(resolved.bufnr, bufnr)
  eq(resolved.lnum, 0)
end

-- ── Leader keymap: toggle via managed meta ────────────────────────────────────

T["<leader>tt: toggle writes to source file and mutates it in place"] = function()
  local task_text = "- [ ] Leader toggle task"
  local src_path = make_tmpfile({ task_text })

  local dash_bufnr = make_buf({ task_text })
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text,
  })

  -- Stub obsidian-tasks and index/render to avoid side effects.
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })
  -- Stub nvim_get_current_buf so cmd subcommand reads the dash_bufnr.
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return dash_bufnr
  end

  keymap_mod.attach(dash_bufnr)

  -- Open a window and position cursor on row 1.
  local winid = vim.api.nvim_open_win(dash_bufnr, true, {
    relative = "editor",
    width = 80,
    height = 5,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  -- Trigger <leader>tt.
  local m = find_nmap(dash_bufnr, "<leader>tt")
  eq(m ~= nil, true, "<leader>tt keymap must be registered")
  m.callback()

  vim.api.nvim_win_close(winid, true)

  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_get_current_buf = orig_gcb
  keymap_mod.detach(dash_bufnr)
  managed.clear_buffer(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })

  -- The source file (opened as a buffer by resolver) should have been mutated.
  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated_line = nil
  if src_buf ~= -1 then
    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)
    mutated_line = lines[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  else
    -- Resolver may have loaded and released the buffer; read from file.
    local lines = read_file(src_path)
    mutated_line = lines[1]
  end
  vim.fn.delete(src_path)

  -- Status must have cycled: Todo (space) → Done (x).
  eq(mutated_line ~= nil, true, "mutated_line must not be nil")
  eq(mutated_line:sub(1, 5), "- [x]")
end

-- ── Leader keymap: drift guard on mutation ────────────────────────────────────

T["<leader>tt: drift detected — refuses mutation, emits warn"] = function()
  local task_text = "- [ ] Draft task"
  -- Source file has a different line — simulate external edit.
  local src_path = make_tmpfile({ "- [x] Done by someone else" })

  local dash_bufnr = make_buf({ task_text })
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text, -- meta still has old text
  })

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
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

  local notify_calls = capture_notify(function()
    local m = find_nmap(dash_bufnr, "<leader>tt")
    if m then
      m.callback()
    end
  end)

  vim.api.nvim_win_close(winid, true)

  restore_ot()
  vim.api.nvim_get_current_buf = orig_gcb
  keymap_mod.detach(dash_bufnr)
  managed.clear_buffer(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(src_path)

  -- A WARN notification about drift must have been emitted.
  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("drift", 1, true) then
      found_warn = true
      break
    end
  end
  eq(found_warn, true)
end

-- ── Leader keymap: priority cycle ────────────────────────────────────────────

T["<leader>tp: cycles priority on source task via managed meta"] = function()
  local task_text = "- [ ] Priority task"
  local src_path = make_tmpfile({ task_text })

  local dash_bufnr = make_buf({ task_text })
  managed.add_task(dash_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text,
  })

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })
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

  local m = find_nmap(dash_bufnr, "<leader>tp")
  eq(m ~= nil, true, "<leader>tp must be registered")
  m.callback()

  vim.api.nvim_win_close(winid, true)

  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_get_current_buf = orig_gcb
  keymap_mod.detach(dash_bufnr)
  managed.clear_buffer(dash_bufnr)

  -- Read the mutated line from the source buffer.
  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated_line = nil
  if src_buf ~= -1 then
    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)
    mutated_line = lines[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(src_path)

  -- none → highest: task should now have 🔺 priority.
  local fields = require("obsidian-tasks.task.fields")
  eq(mutated_line ~= nil, true, "source line must have been mutated")
  eq(mutated_line:find(fields.priority_levels.highest, 1, true) ~= nil, true)
end

-- ── Leader keymap: refresh ────────────────────────────────────────────────────

T["<leader>tr: calls rerender_buffer for the dashboard buffer"] = function()
  local dash_bufnr = make_buf({ "text" })

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local rerender_called_with = nil
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function(b)
      rerender_called_with = b
    end,
  })

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

  local m = find_nmap(dash_bufnr, "<leader>tr")
  eq(m ~= nil, true, "<leader>tr must be registered")
  m.callback()

  vim.api.nvim_win_close(winid, true)

  restore_ot()
  restore_render()
  keymap_mod.detach(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })

  eq(rerender_called_with, dash_bufnr)
end

-- ── setup_keymaps = false ─────────────────────────────────────────────────────

T["setup_keymaps=false: no buffer-local keymaps are installed"] = function()
  local dash_bufnr = make_buf({ "text" })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = false } })

  keymap_mod.attach(dash_bufnr)

  restore_ot()

  -- Plugin no longer installs <CR>/gf (obsidian.nvim ftplugin races our handler).
  eq(find_nmap(dash_bufnr, "<CR>"), nil)
  eq(find_nmap(dash_bufnr, "gf"), nil)
  -- Leader keymaps must be absent when setup_keymaps = false.
  eq(find_nmap(dash_bufnr, "<leader>tt"), nil)
  eq(find_nmap(dash_bufnr, "<leader>tp"), nil)
  eq(find_nmap(dash_bufnr, "<leader>tg"), nil)
  eq(find_nmap(dash_bufnr, "<leader>tr"), nil)
  eq(find_nmap(dash_bufnr, "<leader>tD"), nil)

  keymap_mod.detach(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
end

-- ── next_priority cycle ───────────────────────────────────────────────────────

T["priority cycle: nil → highest → high → medium → low → lowest → nil"] = function()
  local next_priority = require("obsidian-tasks.cmd.priority")._next_priority
  eq(next_priority(nil), "highest")
  eq(next_priority("highest"), "high")
  eq(next_priority("high"), "medium")
  eq(next_priority("medium"), "low")
  eq(next_priority("low"), "lowest")
  eq(next_priority("lowest"), nil)
end

T["priority cycle: unknown level treated as none → highest"] = function()
  local next_priority = require("obsidian-tasks.cmd.priority")._next_priority
  eq(next_priority("bogus"), "highest")
  eq(next_priority("urgent"), "highest")
end

return T
