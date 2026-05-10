-- tests/integration/test_cmd_toggle.lua
-- Integration tests for :ObsidianTask toggle on source-buffer tasks.
--
-- Tests that the full dispatch → resolver → status-cycle → buffer-write
-- pipeline works end-to-end without mocking the cmd module internals.
--
-- All tests use real scratch buffers (no file I/O needed for source edits).

local T = MiniTest.new_set()

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Swap package.loaded[name] for mock; return cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Create a scratch buffer pre-populated with lines.
--- Returns bufnr.
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Get all lines from a buffer.
local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Run f() with nvim_get_current_buf returning bufnr and draw.is_render_line
--- returning nil (source-buffer context).
local function in_buf(bufnr, f)
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  local draw_cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })
  local ok, err = pcall(f)
  vim.api.nvim_get_current_buf = orig_gcb
  draw_cleanup()
  if not ok then
    error(err, 2)
  end
end

-- ── Toggle: Todo → Done ───────────────────────────────────────────────────────

T["toggle source: Todo (space) cycles to Done (x)"] = function()
  local bufnr = make_buf({ "- [ ] Buy milk" })
  local toggle = require("obsidian-tasks.cmd.toggle")

  in_buf(bufnr, function()
    toggle.run({}, { line1 = 1, line2 = 1 })
  end)

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(lines[1], "- [x] Buy milk")
end

-- ── Toggle: Done → Todo ───────────────────────────────────────────────────────

T["toggle source: Done (x) cycles to Todo (space)"] = function()
  local bufnr = make_buf({ "- [x] Done task" })
  local toggle = require("obsidian-tasks.cmd.toggle")

  in_buf(bufnr, function()
    toggle.run({}, { line1 = 1, line2 = 1 })
  end)

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(lines[1], "- [ ] Done task")
end

-- ── Toggle: In Progress → Done ────────────────────────────────────────────────

T["toggle source: In Progress (/) cycles to Done (x)"] = function()
  local bufnr = make_buf({ "- [/] In progress" })
  local toggle = require("obsidian-tasks.cmd.toggle")

  in_buf(bufnr, function()
    toggle.run({}, { line1 = 1, line2 = 1 })
  end)

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(lines[1], "- [x] In progress")
end

-- ── Toggle: preserves task fields ────────────────────────────────────────────

T["toggle source: task fields are preserved after cycle"] = function()
  local bufnr = make_buf({ "- [ ] Write report 📅 2024-12-01 ⏫" })
  local toggle = require("obsidian-tasks.cmd.toggle")

  in_buf(bufnr, function()
    toggle.run({}, { line1 = 1, line2 = 1 })
  end)

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Status toggled to x; fields preserved.
  eq(lines[1]:sub(1, 6), "- [x] ")
  MiniTest.expect.equality(lines[1]:find("📅 2024%-12%-01") ~= nil, true)
  MiniTest.expect.equality(lines[1]:find("⏫") ~= nil, true)
end

-- ── Toggle: visual range (bulk) ───────────────────────────────────────────────

T["toggle source: visual range cycles all tasks in range"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "just a heading",
    "- [ ] Task B",
    "- [x] Task C",
  })
  local toggle = require("obsidian-tasks.cmd.toggle")

  -- Toggle lines 1-4 (visual range, 1-indexed).
  in_buf(bufnr, function()
    toggle.run({}, { line1 = 1, line2 = 4 })
  end)

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Task A: space → x
  eq(lines[1], "- [x] Task A")
  -- Non-task line: unchanged.
  eq(lines[2], "just a heading")
  -- Task B: space → x
  eq(lines[3], "- [x] Task B")
  -- Task C: x → space
  eq(lines[4], "- [ ] Task C")
end

-- ── Toggle: no task on cursor line emits warn ─────────────────────────────────

T["toggle source: no task on line emits warning, buffer unchanged"] = function()
  local bufnr = make_buf({ "plain paragraph" })
  local toggle = require("obsidian-tasks.cmd.toggle")

  local warned = false
  local log = require("obsidian-tasks.log")
  local orig_warn = log.warn
  log.warn = function(_msg)
    warned = true
  end

  in_buf(bufnr, function()
    toggle.run({}, { line1 = 1, line2 = 1 })
  end)

  log.warn = orig_warn

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(warned, true)
  eq(lines[1], "plain paragraph")
end

-- ── Dispatcher integration: dispatch routes to toggle ─────────────────────────

T["dispatch: 'toggle' routes to toggle.run and cycles status"] = function()
  local bufnr = make_buf({ "- [ ] Dispatched task" })
  local cmd = require("obsidian-tasks.cmd")

  in_buf(bufnr, function()
    cmd.dispatch({ fargs = { "toggle" }, line1 = 1, line2 = 1 })
  end)

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(lines[1], "- [x] Dispatched task")
end

return T
