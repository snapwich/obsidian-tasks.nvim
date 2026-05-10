-- tests/unit/test_render_keymap.lua
-- Unit tests for render/keymap.lua.
--
-- Tests dispatch logic (mock cursor + extmark state), attach/detach lifecycle,
-- and the draw.lua wiring (attach on first draw, detach on clear).

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
--- @param bufnr integer
--- @return table[]
local function buf_nmaps(bufnr)
  return vim.api.nvim_buf_get_keymap(bufnr, "n")
end

--- Find a specific buffer-local normal-mode map by lhs.
--- @param bufnr integer
--- @param lhs   string
--- @return table|nil
local function find_nmap(bufnr, lhs)
  for _, m in ipairs(buf_nmaps(bufnr)) do
    if m.lhs == lhs then
      return m
    end
  end
  return nil
end

--- Install *mock* at *name* in package.loaded; return a cleanup function.
--- @param name string
--- @param mock table
--- @return fun()
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Build a minimal single-task layout_lines list.
local function simple_layout(task_text, src_path, src_line)
  local hash = vim.fn.sha256(task_text):sub(1, 16)
  return {
    { kind = "label", text = "▶ tasks · 1 result" },
    {
      kind = "task",
      text = task_text,
      src_path = src_path or "/vault/note.md",
      src_line = src_line or 5,
      src_hash = hash,
    },
    { kind = "footer", text = "─ 1 result ─" },
  }
end

-- ── attach / detach ───────────────────────────────────────────────────────────

T["attach: sets buffer-local <CR> mapping"] = function()
  local bufnr = make_buf({ "test" })
  keymap_mod.attach(bufnr)
  MiniTest.expect.equality(find_nmap(bufnr, "<CR>") ~= nil, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: sets buffer-local gf mapping"] = function()
  local bufnr = make_buf({ "test" })
  keymap_mod.attach(bufnr)
  MiniTest.expect.equality(find_nmap(bufnr, "gf") ~= nil, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: mapping has callback (not rhs string)"] = function()
  local bufnr = make_buf({ "test" })
  keymap_mod.attach(bufnr)
  local m = find_nmap(bufnr, "<CR>")
  MiniTest.expect.equality(m ~= nil, true)
  -- callback field should be a function reference; rhs should be empty
  MiniTest.expect.equality(m.callback ~= nil, true)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["detach: removes <CR> mapping"] = function()
  local bufnr = make_buf({ "test" })
  keymap_mod.attach(bufnr)
  keymap_mod.detach(bufnr)
  eq(find_nmap(bufnr, "<CR>"), nil)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["detach: removes gf mapping"] = function()
  local bufnr = make_buf({ "test" })
  keymap_mod.attach(bufnr)
  keymap_mod.detach(bufnr)
  eq(find_nmap(bufnr, "gf"), nil)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["detach: no-op when no mappings exist (no error)"] = function()
  local bufnr = make_buf({ "test" })
  MiniTest.expect.no_error(function()
    keymap_mod.detach(bufnr) -- never attached
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
    keymap_mod.attach(bufnr) -- second attach
  end)
  keymap_mod.detach(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── dispatch: render-line branch ─────────────────────────────────────────────
--
-- We mock draw.is_render_line to control what the handler sees, then invoke
-- the handler callback directly from the buffer keymap.

T["handler: render line — opens source file and positions cursor"] = function()
  -- We need an actual source file for vim.cmd('edit') to open.
  -- Use the existing fixture file (tasks_a.md exists in the vault).
  local fixture = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures/vault/tasks_a.md"
  -- Verify the fixture actually exists so the test is meaningful.
  MiniTest.expect.equality(vim.fn.filereadable(fixture) == 1, true)

  local src_line = 5 -- line 5 in tasks_a.md: "- [ ] Buy milk #task 📅 2024-01-15"
  -- Compute the correct hash so the handler takes the fast (hash-match) path.
  local fixture_lines = vim.fn.readfile(fixture)
  local correct_hash = vim.fn.sha256(fixture_lines[src_line]):sub(1, 16)

  local bufnr = make_buf({ "fake task line", "other line", "third line" })

  -- Mock draw.is_render_line: lnum 0 (cursor row 1 - 1) → render meta.
  local restore_draw = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function(_b, lnum)
      if lnum == 0 then
        return { src_path = fixture, src_line = src_line, src_hash = correct_hash }
      end
      return nil
    end,
  })

  -- Open buffer in a window and position cursor on row 1 (1-indexed → lnum 0).
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 }) -- 1-indexed row 1 → 0-indexed lnum 0

  keymap_mod.attach(bufnr)

  local m = find_nmap(bufnr, "<CR>")
  MiniTest.expect.equality(m ~= nil, true)
  -- Invoke the handler callback directly.
  m.callback()

  -- After jump, current buffer should be the fixture file.
  local cur_name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  MiniTest.expect.equality(cur_name:find(vim.fn.fnamemodify(fixture, ":t"), 1, true) ~= nil, true)

  -- Cursor should be at src_line (1-indexed row).
  local cur_pos = vim.api.nvim_win_get_cursor(0)
  eq(cur_pos[1], src_line)

  -- Cleanup.
  restore_draw()
  vim.api.nvim_win_close(winid, true)
  -- Close the fixture buffer that was opened.
  local fixture_buf = vim.fn.bufnr(fixture)
  if fixture_buf ~= -1 then
    vim.api.nvim_buf_delete(fixture_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── stale-jump fallback ───────────────────────────────────────────────────────
--
-- Tests for the content-match fallback in make_handler:
--   hash match   → jump to recorded src_line (fast path)
--   hash mismatch, task found at new position → jump to found line
--   hash mismatch, task not found → jump to recorded src_line + log.info

--- Write lines to a temporary file; return its path.
local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

--- Run the handler for bufnr with cursor at row 1 (0-indexed lnum 0).
--- Opens a window, triggers the <CR> callback, then closes the window.
--- Returns the jump target (1-indexed cursor row in the opened file).
local function run_handler_get_line(bufnr, src_path, src_line, src_hash)
  local restore_draw = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function(_b, lnum)
      if lnum == 0 then
        return { src_path = src_path, src_line = src_line, src_hash = src_hash }
      end
      return nil
    end,
  })

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  keymap_mod.attach(bufnr)
  local m = find_nmap(bufnr, "<CR>")
  m.callback()

  local jump_row = vim.api.nvim_win_get_cursor(0)[1]

  restore_draw()
  vim.api.nvim_win_close(winid, true)

  -- Close any buffer opened for the source file.
  local opened = vim.fn.bufnr(src_path)
  if opened ~= -1 then
    vim.api.nvim_buf_delete(opened, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })

  return jump_row
end

T["stale-jump: hash match → jumps to recorded src_line"] = function()
  local task_text = "- [ ] My task"
  local task_hash = vim.fn.sha256(task_text):sub(1, 16)

  -- Task is at line 3 in the source file.
  local src_path = make_tmpfile({ "# note", "", task_text, "", "other line" })
  local bufnr = make_buf({ task_text })

  local jump_row = run_handler_get_line(bufnr, src_path, 3, task_hash)

  eq(jump_row, 3)
  vim.fn.delete(src_path)
end

T["stale-jump: hash mismatch — task moved — jumps to new line"] = function()
  local task_text = "- [ ] My task"
  local task_hash = vim.fn.sha256(task_text):sub(1, 16)

  -- Task is at line 8 but recorded src_line is 3 (task shifted down by 5).
  local src_path = make_tmpfile({
    "# note",
    "",
    "- [ ] Different task",
    "",
    "padding 5",
    "padding 6",
    "padding 7",
    task_text, -- actual position: line 8
    "tail",
    "tail",
  })
  local bufnr = make_buf({ task_text })

  -- Pass src_line = 3 (stale); handler must scan and find line 8.
  local jump_row = run_handler_get_line(bufnr, src_path, 3, task_hash)

  eq(jump_row, 8)
  vim.fn.delete(src_path)
end

T["stale-jump: no match — falls back to recorded src_line and emits log.info"] = function()
  -- Source file has no line matching the hash.
  local src_path = make_tmpfile({ "# note", "", "line 3", "", "line 5" })
  local bufnr = make_buf({ "- [ ] Ghost task" })

  -- Capture vim.notify calls (log.info uses vim.notify).
  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level, ...)
    notify_calls[#notify_calls + 1] = { msg = msg, level = level }
    return orig_notify(msg, level, ...)
  end

  -- Use a hash that does not match any line in the temp file.
  local ghost_hash = "0000000000000000"
  -- Verify no line in the file accidentally matches.
  local file_lines = vim.fn.readfile(src_path)
  for _, l in ipairs(file_lines) do
    MiniTest.expect.equality(vim.fn.sha256(l):sub(1, 16) ~= ghost_hash, true)
  end

  local jump_row = run_handler_get_line(bufnr, src_path, 3, ghost_hash)

  -- Restore notify.
  vim.notify = orig_notify

  -- Must fall back to recorded src_line.
  eq(jump_row, 3)

  -- Must have emitted at least one INFO-level notify containing "recorded line".
  local found_info = false
  for _, call in ipairs(notify_calls) do
    if call.level == vim.log.levels.INFO and call.msg:find("recorded line", 1, true) then
      found_info = true
      break
    end
  end
  MiniTest.expect.equality(found_info, true)

  vim.fn.delete(src_path)
end

-- ── dispatch: fall-through branch ────────────────────────────────────────────

T["handler: non-render line — calls smart_action and feeds keys"] = function()
  local bufnr = make_buf({ "some normal text" })

  -- Mock draw.is_render_line: always returns nil (non-render line).
  local restore_draw = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function(_b, _lnum)
      return nil
    end,
  })

  -- Mock obsidian.actions.smart_action to return a test keystring.
  local smart_action_called = false
  local restore_obsidian = install_mock("obsidian.actions", {
    smart_action = function()
      smart_action_called = true
      return "j" -- a simple motion
    end,
  })

  -- Capture feedkeys calls.
  local feedkeys_calls = {}
  local orig_feedkeys = vim.api.nvim_feedkeys
  vim.api.nvim_feedkeys = function(keys, mode, escape)
    feedkeys_calls[#feedkeys_calls + 1] = { keys = keys, mode = mode, escape = escape }
  end

  -- Open buffer in a window.
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  keymap_mod.attach(bufnr)
  local m = find_nmap(bufnr, "<CR>")
  MiniTest.expect.equality(m ~= nil, true)
  m.callback()

  -- smart_action must have been called.
  MiniTest.expect.equality(smart_action_called, true)
  -- feedkeys must have been called with the result.
  MiniTest.expect.equality(#feedkeys_calls >= 1, true)

  -- Cleanup.
  vim.api.nvim_feedkeys = orig_feedkeys
  restore_draw()
  restore_obsidian()
  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["handler: non-render line — no feedkeys when smart_action returns nil"] = function()
  local bufnr = make_buf({ "text" })

  local restore_draw = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function(_, _)
      return nil
    end,
  })
  local restore_obsidian = install_mock("obsidian.actions", {
    smart_action = function()
      return nil -- no action
    end,
  })

  local feedkeys_calls = {}
  local orig_feedkeys = vim.api.nvim_feedkeys
  vim.api.nvim_feedkeys = function(keys, mode, escape)
    feedkeys_calls[#feedkeys_calls + 1] = { keys = keys, mode = mode, escape = escape }
  end

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  keymap_mod.attach(bufnr)
  local m = find_nmap(bufnr, "<CR>")
  m.callback()

  eq(#feedkeys_calls, 0)

  vim.api.nvim_feedkeys = orig_feedkeys
  restore_draw()
  restore_obsidian()
  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["handler: non-render line — no error when obsidian.actions not available"] = function()
  local bufnr = make_buf({ "text" })

  local restore_draw = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function(_, _)
      return nil
    end,
  })
  -- Make obsidian.actions unavailable.
  local orig = package.loaded["obsidian.actions"]
  package.loaded["obsidian.actions"] = nil

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  keymap_mod.attach(bufnr)
  local m = find_nmap(bufnr, "<CR>")

  MiniTest.expect.no_error(function()
    m.callback()
  end)

  package.loaded["obsidian.actions"] = orig
  restore_draw()
  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── gf mapping uses same dispatch logic ──────────────────────────────────────

T["gf mapping: non-render line falls through to smart_action"] = function()
  local bufnr = make_buf({ "text" })

  local restore_draw = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function(_, _)
      return nil
    end,
  })
  local smart_action_called = false
  local restore_obsidian = install_mock("obsidian.actions", {
    smart_action = function()
      smart_action_called = true
      return nil
    end,
  })

  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  keymap_mod.attach(bufnr)
  local m = find_nmap(bufnr, "gf")
  MiniTest.expect.equality(m ~= nil, true)
  m.callback()

  MiniTest.expect.equality(smart_action_called, true)

  restore_draw()
  restore_obsidian()
  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── draw.lua wiring ───────────────────────────────────────────────────────────
-- Verify that draw.draw attaches keymap on first draw and draw.clear detaches.

T["draw wiring: draw attaches keymap on first draw for buffer"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "label", text = "▶ tasks · 1 result" },
    { kind = "task", text = "- [ ] T", src_path = "/v/n.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }

  draw_mod.draw(bufnr, { 0, 2 }, layout)

  -- After first draw, CR and gf must be mapped.
  MiniTest.expect.equality(find_nmap(bufnr, "<CR>") ~= nil, true)
  MiniTest.expect.equality(find_nmap(bufnr, "gf") ~= nil, true)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["draw wiring: draw does NOT re-attach on second draw of same buffer"] = function()
  -- The keymap is already in place after the first block draw; a second call to
  -- draw (different block) must not error or double-install the mapping.
  local bufnr = make_buf({ "```tasks", "not done", "```", "", "```tasks", "done", "```" })
  local hash_a = vim.fn.sha256("- [ ] A"):sub(1, 16)
  local hash_b = vim.fn.sha256("- [x] B"):sub(1, 16)
  local layout_a = {
    { kind = "label", text = "▶ tasks · 1 result" },
    { kind = "task", text = "- [ ] A", src_path = "/v/a.md", src_line = 1, src_hash = hash_a },
    { kind = "footer", text = "─ 1 result ─" },
  }
  local layout_b = {
    { kind = "label", text = "▶ tasks · 1 result" },
    { kind = "task", text = "- [x] B", src_path = "/v/b.md", src_line = 2, src_hash = hash_b },
    { kind = "footer", text = "─ 1 result ─" },
  }

  MiniTest.expect.no_error(function()
    draw_mod.draw(bufnr, { 0, 2 }, layout_a)
    -- second block — is_first_for_buf is false, no re-attach attempted
    draw_mod.draw(bufnr, { 5, 7 }, layout_b)
  end)

  -- Mappings still present (not removed by second draw).
  MiniTest.expect.equality(find_nmap(bufnr, "<CR>") ~= nil, true)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["draw wiring: clear detaches keymap"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "label", text = "▶ tasks · 1 result" },
    { kind = "task", text = "- [ ] T", src_path = "/v/n.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }

  draw_mod.draw(bufnr, { 0, 2 }, layout)
  draw_mod.clear(bufnr)

  -- After clear, CR and gf must be removed.
  eq(find_nmap(bufnr, "<CR>"), nil)
  eq(find_nmap(bufnr, "gf"), nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["draw wiring: re-draw after clear re-attaches keymap"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "label", text = "▶ tasks · 1 result" },
    { kind = "task", text = "- [ ] T", src_path = "/v/n.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }

  draw_mod.draw(bufnr, { 0, 2 }, layout)
  draw_mod.clear(bufnr)
  -- Re-draw: _state[bufnr] is nil → is_first_for_buf = true → re-attach.
  draw_mod.draw(bufnr, { 0, 2 }, layout)

  MiniTest.expect.equality(find_nmap(bufnr, "<CR>") ~= nil, true)
  MiniTest.expect.equality(find_nmap(bufnr, "gf") ~= nil, true)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
