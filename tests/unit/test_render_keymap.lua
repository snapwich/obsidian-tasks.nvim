-- tests/unit/test_render_keymap.lua
-- Unit tests for render/keymap.lua (T7 rewrite).
--
-- Covers:
--   attach/detach lifecycle — CR, gf, and leader keymaps
--   CR/gf handler: uses managed.task_meta_for_row (not hash scan)
--   CR/gf: whole-line jump (cursor column irrelevant)
--   CR/gf: drift emits log.info but still jumps (extmark trusted)
--   CR/gf: non-render line falls through to smart_action
--   <leader>tt: toggle via dispatch; no drift guard bypass
--   <leader>tp: priority cycle via dispatch
--   <leader>tr: triggers rerender
--   <leader>tD: delete with confirmation
--   setup_keymaps=false: leader keymaps not installed
--   draw wiring: attach on first draw, detach on clear

local T = MiniTest.new_set()

-- ── Module handles ────────────────────────────────────────────────────────────

local keymap_mod = require("obsidian-tasks.render.keymap")
local draw_mod = require("obsidian-tasks.render.draw")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Return all buffer-local normal-mode maps for *bufnr*.
local function buf_nmaps(bufnr)
  return vim.api.nvim_buf_get_keymap(bufnr, "n")
end

--- Find a specific buffer-local normal-mode map by lhs.
--- Handles <leader> expansion: nvim_buf_get_keymap returns the expanded form.
local function find_nmap(bufnr, lhs)
  -- Expand <leader> the same way nvim does when storing keymaps.
  local leader = vim.g.mapleader or "\\"
  local expanded = lhs:gsub("<[Ll]eader>", leader)
  for _, m in ipairs(buf_nmaps(bufnr)) do
    if m.lhs == lhs or m.lhs == expanded then
      return m
    end
  end
  return nil
end

--- Install *mock* at *name* in package.loaded; return a cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Write lines to a temporary file; return its path.
local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
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

-- ── attach / detach ───────────────────────────────────────────────────────────
--
-- The plugin no longer overrides <CR> or gf — obsidian.nvim's ftplugin races
-- our handler.  <leader>tg is the explicit jump-from-anywhere keymap.

T["attach: does NOT install <CR> or gf"] = function()
  local bufnr = make_buf({ "test" })
  keymap_mod.attach(bufnr)
  eq(find_nmap(bufnr, "<CR>"), nil)
  eq(find_nmap(bufnr, "gf"), nil)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: leader keymaps installed by default"] = function()
  local bufnr = make_buf({ "test" })
  -- Ensure setup_keymaps defaults to true.
  local restore = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  keymap_mod.attach(bufnr)
  restore()
  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tt") ~= nil, true)
  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tp") ~= nil, true)
  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tg") ~= nil, true)
  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tr") ~= nil, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: leader keymaps NOT installed when setup_keymaps=false"] = function()
  local bufnr = make_buf({ "test" })
  local restore = install_mock("obsidian-tasks", { opts = { setup_keymaps = false } })
  keymap_mod.attach(bufnr)
  restore()
  -- Leader keymaps must be absent.
  eq(find_nmap(bufnr, "<leader>tt"), nil)
  eq(find_nmap(bufnr, "<leader>tp"), nil)
  eq(find_nmap(bufnr, "<leader>tg"), nil)
  eq(find_nmap(bufnr, "<leader>tr"), nil)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["detach: removes leader keymaps"] = function()
  local bufnr = make_buf({ "test" })
  local restore = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  keymap_mod.attach(bufnr)
  restore()
  keymap_mod.detach(bufnr)
  eq(find_nmap(bufnr, "<leader>tt"), nil)
  eq(find_nmap(bufnr, "<leader>tg"), nil)
  eq(find_nmap(bufnr, "<leader>tr"), nil)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["detach: no-op when no mappings exist (no error)"] = function()
  local bufnr = make_buf({ "test" })
  MiniTest.expect.no_error(function()
    keymap_mod.detach(bufnr)
  end)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: no-op for invalid bufnr (no error)"] = function()
  MiniTest.expect.no_error(function()
    keymap_mod.attach(999999)
  end)
end

T["attach: idempotent — calling twice does not error"] = function()
  local bufnr = make_buf({ "test" })
  MiniTest.expect.no_error(function()
    keymap_mod.attach(bufnr)
    keymap_mod.attach(bufnr)
  end)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── <leader>tg handler: render line jump via task_meta ───────────────────────
--
-- The new model trusts the extmark row.  No hash scan, no stale-jump fallback.
-- Drift emits log.info but still jumps.

--- Run the <leader>tg handler for bufnr with cursor at 1-indexed row.
--- Returns {jumped_to_file, cursor_row} where jumped_to_file is the bufname.
local function run_tg_handler(bufnr, cursor_row_1idx)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { cursor_row_1idx, 0 })

  local m = find_nmap(bufnr, "<leader>tg")
  MiniTest.expect.equality(m ~= nil, true)
  m.callback()

  local jumped_to = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  local cur_row = vim.api.nvim_win_get_cursor(0)[1]

  vim.api.nvim_win_close(winid, true)
  return jumped_to, cur_row
end

T["<leader>tg handler: render line — jumps to source_file at source_row"] = function()
  local task_text = "- [ ] Jump test task"
  local src_path = make_tmpfile({ "header", task_text, "footer" })
  -- source_row=1 (0-indexed) → jump to row 2 (1-indexed)

  local bufnr = make_buf({ "rendered line" })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function(_b, _lnum)
      return { source_file = src_path, source_row = 1, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  keymap_mod.attach(bufnr)
  restore_ot()

  local jumped_to, cur_row = run_tg_handler(bufnr, 1)

  restore_managed()
  keymap_mod.detach(bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  -- Must have jumped to the source file.
  MiniTest.expect.equality(jumped_to:find(vim.fn.fnamemodify(src_path, ":t"), 1, true) ~= nil, true)
  -- Cursor at 1-indexed row 2 (source_row=1 → row+1=2).
  eq(cur_row, 2)
end

T["<leader>tg handler: jumps regardless of cursor column (whole-line trigger)"] = function()
  local task_text = "- [ ] Any column jump"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ "rendered task line with spaces" })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  keymap_mod.attach(bufnr)
  restore_ot()

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 5 }) -- column 5, not 0

  find_nmap(bufnr, "<leader>tg").callback()

  local jumped_to = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  vim.api.nvim_win_close(winid, true)

  restore_managed()
  keymap_mod.detach(bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  MiniTest.expect.equality(jumped_to:find(vim.fn.fnamemodify(src_path, ":t"), 1, true) ~= nil, true)
end

T["<leader>tg handler: drift — still jumps but emits log.info"] = function()
  -- Source file has a different line than meta.task_text → drift detected.
  local src_path = make_tmpfile({ "- [x] Toggled by external editor" })
  local task_text = "- [ ] Original task"

  local bufnr = make_buf({ "rendered line" })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  keymap_mod.attach(bufnr)
  restore_ot()

  local jumped_to = nil
  local notify_calls = capture_notify(function()
    local winid = vim.api.nvim_open_win(bufnr, true, {
      relative = "editor",
      width = 80,
      height = 10,
      row = 0,
      col = 0,
    })
    vim.api.nvim_set_current_win(winid)
    vim.api.nvim_win_set_cursor(winid, { 1, 0 })
    find_nmap(bufnr, "<leader>tg").callback()
    jumped_to = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    vim.api.nvim_win_close(winid, true)
  end)

  restore_managed()
  keymap_mod.detach(bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  -- Must still have jumped.
  MiniTest.expect.equality(
    jumped_to ~= nil and jumped_to:find(vim.fn.fnamemodify(src_path, ":t"), 1, true) ~= nil,
    true
  )
  -- Must have emitted an INFO notice about stale position.
  local found_info = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.INFO and c.msg:find("stale", 1, true) then
      found_info = true
      break
    end
  end
  MiniTest.expect.equality(found_info, true)
end

T["<leader>tg handler: no task on row — emits info, stays put"] = function()
  local bufnr = make_buf({ "some normal text" })

  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return nil
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  keymap_mod.attach(bufnr)
  restore_ot()

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })
  local before_buf = vim.api.nvim_get_current_buf()

  local notify_calls = capture_notify(function()
    find_nmap(bufnr, "<leader>tg").callback()
  end)

  -- No jump — current buffer unchanged.
  eq(vim.api.nvim_get_current_buf(), before_buf)
  -- Emitted an INFO notice.
  local found_info = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.INFO and tostring(c.msg):find("no rendered task", 1, true) then
      found_info = true
      break
    end
  end
  eq(found_info, true)

  restore_managed()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── <leader>tt — toggle ───────────────────────────────────────────────────────

T["<leader>tt: no task on line — emits info, no dispatch"] = function()
  local bufnr = make_buf({ "plain text" })

  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return nil
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatch_called = false
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function()
      dispatch_called = true
    end,
  })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local notify_calls = capture_notify(function()
    find_nmap(bufnr, "<leader>tt").callback()
  end)

  eq(dispatch_called, false)
  local found_info = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.INFO then
      found_info = true
      break
    end
  end
  MiniTest.expect.equality(found_info, true)

  restore_managed()
  restore_ot()
  restore_cmd()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["<leader>tt: drift detected — refuses with warn, no dispatch"] = function()
  local task_text = "- [ ] My task"
  local src_path = make_tmpfile({ "- [x] Changed by external editor" })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatch_called = false
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function()
      dispatch_called = true
    end,
  })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local notify_calls = capture_notify(function()
    find_nmap(bufnr, "<leader>tt").callback()
  end)

  eq(dispatch_called, false)
  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("drift", 1, true) then
      found_warn = true
      break
    end
  end
  MiniTest.expect.equality(found_warn, true)

  restore_managed()
  restore_ot()
  restore_cmd()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

T["<leader>tt: no drift — calls dispatch with {toggle}"] = function()
  local task_text = "- [ ] My task"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatched_fargs = nil
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function(opts)
      dispatched_fargs = opts.fargs
    end,
  })
  -- Stub index.refresh_file and render.rerender_buffer to avoid side-effects.
  local restore_index = install_mock("obsidian-tasks.index", {
    refresh_file = function() end,
  })
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function() end,
  })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tt").callback()

  eq(dispatched_fargs ~= nil, true)
  eq(dispatched_fargs[1], "toggle")

  restore_managed()
  restore_ot()
  restore_cmd()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── <leader>tp — priority cycle ───────────────────────────────────────────────

T["<leader>tp: calls dispatch with {priority, cycle}"] = function()
  local task_text = "- [ ] Priority task"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatched_fargs = nil
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function(opts)
      dispatched_fargs = opts.fargs
    end,
  })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tp").callback()

  eq(dispatched_fargs ~= nil, true)
  eq(dispatched_fargs[1], "priority")
  eq(dispatched_fargs[2], "cycle")

  restore_managed()
  restore_ot()
  restore_cmd()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── <leader>tr — refresh ─────────────────────────────────────────────────────

T["<leader>tr: triggers rerender_buffer"] = function()
  local bufnr = make_buf({ "text" })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local rerender_called = false
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function()
      rerender_called = true
    end,
  })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tr").callback()

  MiniTest.expect.equality(rerender_called, true)

  restore_ot()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── <leader>tD — delete ───────────────────────────────────────────────────────

T["<leader>tD: no task — emits info, no confirm"] = function()
  local bufnr = make_buf({ "plain text" })

  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return nil
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local confirm_called = false
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    confirm_called = true
    return 2
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local notify_calls = capture_notify(function()
    find_nmap(bufnr, "<leader>tD").callback()
  end)

  eq(confirm_called, false)
  local found_info = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.INFO then
      found_info = true
    end
  end
  MiniTest.expect.equality(found_info, true)

  vim.fn.confirm = orig_confirm
  restore_managed()
  restore_ot()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["<leader>tD: user confirms — deletes source line and rerenders"] = function()
  local task_text = "- [ ] Task to delete"
  local src_path = make_tmpfile({ "header", task_text, "footer" })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 1, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  -- Confirm returns 1 (Yes).
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 1
  end

  local rerender_called = false
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function()
      rerender_called = true
    end,
  })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tD").callback()

  -- Source buffer should no longer have the task line.
  local src_bufnr = vim.fn.bufnr(src_path, false)
  local remaining_lines
  if src_bufnr > -1 then
    remaining_lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  else
    remaining_lines = vim.fn.readfile(src_path)
  end

  MiniTest.expect.equality(rerender_called, true)
  -- Task line must be gone; header and footer remain.
  eq(#remaining_lines, 2)
  MiniTest.expect.equality(remaining_lines[1], "header")
  MiniTest.expect.equality(remaining_lines[2], "footer")

  vim.fn.confirm = orig_confirm
  restore_managed()
  restore_ot()
  restore_render()
  restore_index()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  if src_bufnr > -1 then
    vim.api.nvim_buf_delete(src_bufnr, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

T["<leader>tD: user cancels — no mutation"] = function()
  local task_text = "- [ ] Task to keep"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  -- Confirm returns 2 (No).
  local orig_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 2
  end

  local rerender_called = false
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function()
      rerender_called = true
    end,
  })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tD").callback()

  eq(rerender_called, false)
  -- Source file untouched.
  local src_lines = vim.fn.readfile(src_path)
  eq(#src_lines, 1)
  eq(src_lines[1], task_text)

  vim.fn.confirm = orig_confirm
  restore_managed()
  restore_ot()
  restore_render()
  restore_index()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── <leader>te — edit description ────────────────────────────────────────────

T["<leader>te: happy path — replaces description in source buffer"] = function()
  local task_text = "- [ ] Old description"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  -- Stub vim.ui.input to call callback synchronously with new description.
  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback("New description")
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>te").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Read mutated line from the source buffer opened by get_or_load_buf.
  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated = nil
  if src_buf ~= -1 then
    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)
    mutated = lines[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.fn.delete(src_path)

  eq(mutated ~= nil, true)
  -- New description must appear; old one must not.
  eq(mutated:find("New description", 1, true) ~= nil, true)
  eq(mutated:find("Old description", 1, true) == nil, true)
end

T["<leader>te: cancel (input=nil) — no mutation"] = function()
  local task_text = "- [ ] No change task"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local rerender_called = false
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function()
      rerender_called = true
    end,
  })

  -- Stub vim.ui.input to cancel (nil).
  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback(nil)
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>te").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)

  -- Source file must be unchanged.
  local src_lines = vim.fn.readfile(src_path)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  eq(rerender_called, false)
  eq(src_lines[1], task_text)
end

-- ── <leader>td — due date ─────────────────────────────────────────────────────

T["<leader>td: valid date → dispatches {due, date}"] = function()
  local task_text = "- [ ] Task with no due"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatched_fargs = nil
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function(opts)
      dispatched_fargs = opts.fargs
    end,
  })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  -- Stub vim.ui.input to provide a valid ISO date.
  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback("2026-12-31")
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>td").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_cmd()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  eq(dispatched_fargs ~= nil, true)
  eq(dispatched_fargs[1], "due")
  eq(dispatched_fargs[2], "2026-12-31")
end

T["<leader>td: invalid date → log.error, no dispatch"] = function()
  local task_text = "- [ ] Task for invalid date"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatch_called = false
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function()
      dispatch_called = true
    end,
  })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  -- Stub vim.ui.input to provide a non-parseable date.
  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback("not-a-date")
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local notify_calls = capture_notify(function()
    find_nmap(bufnr, "<leader>td").callback()
  end)

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_cmd()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  eq(dispatch_called, false)
  local found_error = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("invalid date", 1, true) then
      found_error = true
      break
    end
  end
  eq(found_error, true)
end

T["<leader>td: cancel (input=nil) — no dispatch"] = function()
  local task_text = "- [ ] Task for cancel date"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })

  local dispatch_called = false
  local restore_cmd = install_mock("obsidian-tasks.cmd", {
    dispatch = function()
      dispatch_called = true
    end,
  })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback(nil) -- user cancels
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>td").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_cmd()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  eq(dispatch_called, false)
end

-- ── <leader>tT — edit tags ────────────────────────────────────────────────────

T["<leader>tT: auto-prefixes # and updates source buffer"] = function()
  -- Input "foo, #bar" → tags become {"#foo", "#bar"}.
  local task_text = "- [ ] Tag task"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback("foo, #bar")
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tT").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated = nil
  if src_buf ~= -1 then
    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)
    mutated = lines[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.fn.delete(src_path)

  eq(mutated ~= nil, true)
  -- Both tags must appear with # prefix.
  eq(mutated:find("#foo", 1, true) ~= nil, true)
  eq(mutated:find("#bar", 1, true) ~= nil, true)
end

T["<leader>tT: cancel (input=nil) — no mutation"] = function()
  local task_text = "- [ ] Task for cancel tags #existing"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })

  local rerender_called = false
  local restore_render = install_mock("obsidian-tasks.render", {
    rerender_buffer = function()
      rerender_called = true
    end,
  })

  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback(nil)
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tT").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)

  local src_lines = vim.fn.readfile(src_path)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  eq(rerender_called, false)
  eq(src_lines[1], task_text)
end

T["<leader>tT: empty input — clears all tags from task"] = function()
  -- Tags that appear AFTER a field marker are "trailing" and live in task.tags
  -- only (not in task.description).  Setting task.tags = {} then serializing
  -- removes them cleanly.  Tags embedded in the description text are NOT
  -- affected by task.tags, so we must use a trailing tag for this test.
  local task_text = "- [ ] My task \xf0\x9f\x93\x85 2024-01-01 #old"
  local src_path = make_tmpfile({ task_text })

  local bufnr = make_buf({ task_text })
  local restore_managed = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  local restore_index = install_mock("obsidian-tasks.index", { refresh_file = function() end })
  local restore_render = install_mock("obsidian-tasks.render", { rerender_buffer = function() end })

  local orig_input = vim.ui.input
  vim.ui.input = function(_opts, callback)
    callback("") -- user clears input
  end

  keymap_mod.attach(bufnr)

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  find_nmap(bufnr, "<leader>tT").callback()

  vim.ui.input = orig_input
  restore_managed()
  restore_ot()
  restore_index()
  restore_render()
  vim.api.nvim_win_close(winid, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local src_buf = vim.fn.bufnr(src_path, false)
  local mutated = nil
  if src_buf ~= -1 then
    local lines = vim.api.nvim_buf_get_lines(src_buf, 0, 1, false)
    mutated = lines[1]
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.fn.delete(src_path)

  eq(mutated ~= nil, true)
  -- The trailing tag must be absent after clearing.
  eq(mutated:find("#old", 1, true) == nil, true)
  -- The date field must still be present (only tags were cleared).
  eq(mutated:find("2024-01-01", 1, true) ~= nil, true)
end

-- ── draw.lua wiring ───────────────────────────────────────────────────────────

T["draw wiring: draw attaches keymap on first draw for buffer"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] T", src_path = "/v/n.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  draw_mod.draw(bufnr, { 0, 2 }, layout)
  restore_ot()

  -- <leader>tg is the jump keymap (CR/gf are NOT installed by this plugin).
  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tg") ~= nil, true)
  eq(find_nmap(bufnr, "<CR>"), nil)
  eq(find_nmap(bufnr, "gf"), nil)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["draw wiring: clear detaches keymap"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] T", src_path = "/v/n.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  draw_mod.draw(bufnr, { 0, 2 }, layout)
  draw_mod.clear(bufnr)
  restore_ot()

  eq(find_nmap(bufnr, "<leader>tg"), nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["draw wiring: re-draw after clear re-attaches keymap"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] T", src_path = "/v/n.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  draw_mod.draw(bufnr, { 0, 2 }, layout)
  draw_mod.clear(bufnr)
  draw_mod.draw(bufnr, { 0, 2 }, layout)
  restore_ot()

  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tg") ~= nil, true)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["draw wiring: second draw of same buffer does not error"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```", "", "```tasks", "done", "```" })
  local hash_a = vim.fn.sha256("- [ ] A"):sub(1, 16)
  local hash_b = vim.fn.sha256("- [x] B"):sub(1, 16)
  local layout_a = {
    { kind = "task", text = "- [ ] A", src_path = "/v/a.md", src_line = 1, src_hash = hash_a },
    { kind = "footer", text = "─ 1 result ─" },
  }
  local layout_b = {
    { kind = "task", text = "- [x] B", src_path = "/v/b.md", src_line = 2, src_hash = hash_b },
    { kind = "footer", text = "─ 1 result ─" },
  }

  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  MiniTest.expect.no_error(function()
    draw_mod.draw(bufnr, { 0, 2 }, layout_a)
    draw_mod.draw(bufnr, { 5, 7 }, layout_b)
  end)
  restore_ot()

  MiniTest.expect.equality(find_nmap(bufnr, "<leader>tg") ~= nil, true)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── End-to-end: draw → task_meta → <leader>tg jump ──────────────────────────

T["E2E: draw populates task_meta; <leader>tg jumps to correct source row"] = function()
  -- Build a real layout, draw it, then invoke <leader>tg and verify the jump.
  local layout_mod = require("obsidian-tasks.render.layout")
  local parse_task = require("obsidian-tasks.task.parse")

  local task_text = "- [ ] E2E jump test 📅 2024-06-01"
  local src_path = make_tmpfile({ "# Source", task_text, "footer" })
  local src_line = 2 -- 1-indexed

  local task = parse_task.parse(task_text)
  MiniTest.expect.equality(task ~= nil, true)
  task._src_path = src_path
  task._src_line = src_line

  local query_result = {
    groups = { { name = "", tasks = { task } } },
    total = 1,
    hide_flags = {},
    header_summary = "",
    errors = {},
  }
  local layout_lines = layout_mod.layout(query_result)

  -- Draw into a render buffer.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local restore_ot = install_mock("obsidian-tasks", { opts = { setup_keymaps = true } })
  draw_mod.draw(bufnr, { 0, 2 }, layout_lines)
  restore_ot()

  -- The task line is inserted at row 3 (0-indexed), row 4 (1-indexed).
  local task_render_row_1idx = 4

  -- Open a window, set cursor on the rendered task row, fire <leader>tg.
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { task_render_row_1idx, 0 })

  local m = find_nmap(bufnr, "<leader>tg")
  MiniTest.expect.equality(m ~= nil, true)
  m.callback()

  -- The cursor must be at the source row (src_line = 2 → row 2).
  local jump_row = vim.api.nvim_win_get_cursor(0)[1]
  eq(jump_row, src_line)

  -- Cleanup.
  vim.api.nvim_win_close(winid, true)
  local opened = vim.fn.bufnr(src_path)
  if opened ~= -1 then
    vim.api.nvim_buf_delete(opened, { force = true })
  end
  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

return T
