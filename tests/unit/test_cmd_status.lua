-- tests/unit/test_cmd_status.lua
-- Tests for status commands: toggle, done, cancel, inProgress, onHold.
--
-- Covers:
--   • Stamp logic for done/cancel (mocked os.date)
--   • Idempotency for done/cancel
--   • Source-buffer mutation for all five commands
--   • Visual-range bulk: all 5 tasks marked done with stamp
--   • Render-line path: mutates buffer in-place (F4 diff detects and patches source on :w)
--   • No-task range: warns without error

local T = MiniTest.new_set()

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Swap package.loaded[name]; return cleanup fn.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Create a scratch buffer pre-populated with lines; returns bufnr.
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Read lines from a buffer.
local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

--- Mock draw.is_render_line to return nil (source buffer context).
local function mock_source_ctx()
  return install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })
end

--- Mock draw.is_render_line to always return fake render info.
local function mock_render_ctx()
  return install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return { src_path = "/vault/note.md", src_line = 1, src_hash = "h1", source_text_hash = "s1" }
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

--- Mock os.date to return a fixed string.
local function mock_os_date(fixed_date)
  local orig = os.date
  os.date = function(_fmt)
    return fixed_date
  end
  return function()
    os.date = orig
  end
end

--- Capture vim.notify calls during f(); returns list of {msg, level}.
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

--- Run a command module against a single-line buffer; return the resulting line.
--- @param mod_name string  e.g. "obsidian-tasks.cmd.done"
--- @param line     string  task source line
--- @param range    table?  { line1, line2 } defaults to { 1, 1 }
--- @param extra_setup function?  called before mod.run (use for os.date mock etc.)
--- @return string, function  resulting_line, cleanup_fn (call to restore mocks)
local function run_cmd_on_line(mod_name, line, range, pre_fn)
  range = range or { line1 = 1, line2 = 1 }
  local bufnr = make_buf({ line })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  if pre_fn then
    pre_fn()
  end

  local mod = require(mod_name)
  mod.run({}, range)

  draw_cleanup()
  buf_cleanup()

  local result = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return result[1]
end

-- ── toggle: source buffer ─────────────────────────────────────────────────────

T["toggle: Todo (space) -> Done (x)"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.toggle", "- [ ] My task")
  MiniTest.expect.equality(result, "- [x] My task")
end

T["toggle: Done (x) -> Todo (space)"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.toggle", "- [x] My task")
  MiniTest.expect.equality(result, "- [ ] My task")
end

T["toggle: In Progress (/) -> Done (x)"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.toggle", "- [/] My task")
  MiniTest.expect.equality(result, "- [x] My task")
end

T["toggle: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.toggle").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("toggle") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["toggle: render line mutates buffer in-place (F4 writes back to source on :w)"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.toggle").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must be mutated: Todo → Done (default cycle).
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
end

-- ── done: stamp logic ─────────────────────────────────────────────────────────

T["done: sets status to x and stamps done date"] = function()
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.done", "- [ ] My task")
  date_restore()
  MiniTest.expect.equality(result, "- [x] My task ✅ 2024-01-15")
end

T["done: already-done task — preserves existing stamp (idempotent)"] = function()
  -- Task already has done field and status x.
  local line = "- [x] My task \xe2\x9c\x85 2023-06-01" -- ✅ is \xe2\x9c\x85
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.done", line)
  date_restore()
  -- Status still x, original date preserved (no re-stamp).
  MiniTest.expect.equality(result ~= nil, true)
  MiniTest.expect.equality(result:find("2024%-01%-15") == nil, true)
  MiniTest.expect.equality(result:find("2023%-06%-01") ~= nil, true)
  MiniTest.expect.equality(result:sub(1, 5), "- [x]")
end

T["done: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("done") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["done: render line mutates buffer in-place (F4 writes back to source on :w)"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must be mutated: status set to 'x' and done stamp appended.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
  MiniTest.expect.equality(lines[1]:find("\xe2\x9c\x85") ~= nil, true) -- ✅
end

T["done: uses opts.done_date_format from plugin opts"] = function()
  -- Override plugin opts with a custom format.
  local ot_restore = install_mock("obsidian-tasks", {
    opts = { done_date_format = "%d/%m/%Y" },
  })
  local date_restore = mock_os_date("15/01/2024")
  local result = run_cmd_on_line("obsidian-tasks.cmd.done", "- [ ] My task")
  date_restore()
  ot_restore()
  MiniTest.expect.equality(result, "- [x] My task \xe2\x9c\x85 15/01/2024")
end

-- ── done: visual range — 5 tasks all marked done ──────────────────────────────

T["done: visual range — 5 tasks all marked done with stamp"] = function()
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
  local date_restore = mock_os_date("2024-01-15")

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 5 })

  date_restore()
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#lines, 5)
  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:sub(1, 5), "- [x]", "line " .. i .. " should be done")
    MiniTest.expect.equality(line:find("2024%-01%-15") ~= nil, true, "line " .. i .. " missing stamp")
  end
end

T["done: visual range skips non-task lines silently"] = function()
  local bufnr = make_buf({
    "- [ ] Task one",
    "not a task",
    "## heading",
    "- [ ] Task two",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)
  local date_restore = mock_os_date("2024-01-15")

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 4 })

  date_restore()
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Lines 1 and 4 are tasks, lines 2 and 3 unchanged.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
  MiniTest.expect.equality(lines[2], "not a task")
  MiniTest.expect.equality(lines[3], "## heading")
  MiniTest.expect.equality(lines[4]:sub(1, 5), "- [x]")
end

-- ── cancel: stamp logic ───────────────────────────────────────────────────────

T["cancel: sets status to '-' and stamps cancelled date"] = function()
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.cancel", "- [ ] My task")
  date_restore()
  MiniTest.expect.equality(result, "- [-] My task \xe2\x9d\x8c 2024-01-15")
end

T["cancel: already-cancelled task — preserves existing stamp (idempotent)"] = function()
  -- ❌ is \xe2\x9d\x8c
  local line = "- [-] My task \xe2\x9d\x8c 2023-06-01"
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.cancel", line)
  date_restore()
  MiniTest.expect.equality(result ~= nil, true)
  MiniTest.expect.equality(result:find("2024%-01%-15") == nil, true)
  MiniTest.expect.equality(result:find("2023%-06%-01") ~= nil, true)
  MiniTest.expect.equality(result:sub(1, 5), "- [-]")
end

T["cancel: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("cancel") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["cancel: render line mutates buffer in-place (F4 writes back to source on :w)"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must be mutated: status set to '-' and cancelled stamp appended.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [-]")
  MiniTest.expect.equality(lines[1]:find("\xe2\x9d\x8c") ~= nil, true) -- ❌
end

T["cancel: uses opts.done_date_format from plugin opts"] = function()
  local ot_restore = install_mock("obsidian-tasks", {
    opts = { done_date_format = "%d/%m/%Y" },
  })
  local date_restore = mock_os_date("15/01/2024")
  local result = run_cmd_on_line("obsidian-tasks.cmd.cancel", "- [ ] My task")
  date_restore()
  ot_restore()
  MiniTest.expect.equality(result, "- [-] My task \xe2\x9d\x8c 15/01/2024")
end

-- ── cancel: visual range ──────────────────────────────────────────────────────

T["cancel: visual range — 5 tasks all marked cancelled with stamp"] = function()
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
  local date_restore = mock_os_date("2024-01-15")

  require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 5 })

  date_restore()
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#lines, 5)
  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:sub(1, 5), "- [-]", "line " .. i .. " should be cancelled")
    MiniTest.expect.equality(line:find("2024%-01%-15") ~= nil, true, "line " .. i .. " missing stamp")
  end
end

-- ── inProgress ────────────────────────────────────────────────────────────────

T["inProgress: sets status to '/'"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.inProgress", "- [ ] My task")
  MiniTest.expect.equality(result, "- [/] My task")
end

T["inProgress: does not add any date stamp"] = function()
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.inProgress", "- [ ] My task")
  date_restore()
  MiniTest.expect.equality(result:find("2024") == nil, true)
end

T["inProgress: works on already-in-progress task (idempotent)"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.inProgress", "- [/] Already in progress")
  MiniTest.expect.equality(result, "- [/] Already in progress")
end

T["inProgress: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.inProgress").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("inProgress") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["inProgress: render line mutates buffer in-place (F4 writes back to source on :w)"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.inProgress").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must be mutated: status set to '/'.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [/]")
end

T["inProgress: visual range — all tasks set to in-progress"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [x] Task B",
    "- [-] Task C",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.inProgress").run({}, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:sub(1, 5), "- [/]", "line " .. i .. " should be in-progress")
  end
end

-- ── onHold ────────────────────────────────────────────────────────────────────

T["onHold: sets status to 'h'"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.onHold", "- [ ] My task")
  MiniTest.expect.equality(result, "- [h] My task")
end

T["onHold: does not add any date stamp"] = function()
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.onHold", "- [ ] My task")
  date_restore()
  MiniTest.expect.equality(result:find("2024") == nil, true)
end

T["onHold: works on already-on-hold task (idempotent)"] = function()
  local result = run_cmd_on_line("obsidian-tasks.cmd.onHold", "- [h] Already on hold")
  MiniTest.expect.equality(result, "- [h] Already on hold")
end

T["onHold: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local notify_calls = capture_notify(function()
    require("obsidian-tasks.cmd.onHold").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("onHold") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["onHold: render line mutates buffer in-place (F4 writes back to source on :w)"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.onHold").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must be mutated: status set to 'h'.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [h]")
end

T["onHold: visual range — all tasks set to on-hold"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [x] Task B",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.onHold").run({}, { line1 = 1, line2 = 2 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:sub(1, 5), "- [h]", "line " .. i .. " should be on-hold")
  end
end

-- ── Cross-command: done then cancel (idempotency edge case) ───────────────────

T["done then cancel: done stamp preserved after cancel re-stamps cancelled"] = function()
  -- A task that's been done, then someone runs :cancel on it.
  -- The done field should be preserved; cancelled field should be added.
  local line = "- [x] My task \xe2\x9c\x85 2023-06-01"
  local bufnr = make_buf({ line })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)
  local date_restore = mock_os_date("2024-01-15")

  require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 1 })

  date_restore()
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Status should be '-' (cancelled).
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [-]")
  -- Original done date still present.
  MiniTest.expect.equality(lines[1]:find("2023%-06%-01") ~= nil, true)
  -- Cancelled stamp added.
  MiniTest.expect.equality(lines[1]:find("2024%-01%-15") ~= nil, true)
end

-- ── Preserve existing fields on status change ─────────────────────────────────

T["done: preserves existing fields (due date, description)"] = function()
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.done", "- [ ] My task \xf0\x9f\x93\x85 2024-03-01")
  date_restore()
  -- Due date preserved, done stamp added, status x.
  MiniTest.expect.equality(result:sub(1, 5), "- [x]")
  MiniTest.expect.equality(result:find("2024%-03%-01") ~= nil, true)
  MiniTest.expect.equality(result:find("2024%-01%-15") ~= nil, true)
end

T["cancel: preserves existing fields (due date, description)"] = function()
  local date_restore = mock_os_date("2024-01-15")
  local result = run_cmd_on_line("obsidian-tasks.cmd.cancel", "- [ ] My task \xf0\x9f\x93\x85 2024-03-01")
  date_restore()
  MiniTest.expect.equality(result:sub(1, 5), "- [-]")
  MiniTest.expect.equality(result:find("2024%-03%-01") ~= nil, true)
  MiniTest.expect.equality(result:find("2024%-01%-15") ~= nil, true)
end

-- ── Render-line wikilink regression: wikilink stripped before mutation ────────
--
-- mock_render_ctx returns src_path = "/vault/note.md".
-- fnamemodify(":t:r") → "note" → wikilink suffix = " [[note]]".
-- After the fix, resolve_task_at strips the suffix before parsing, so cmd
-- modules serialize a clean (no wikilink) task back to the render buffer.
-- These tests guard against the regression where [[note]] was written to disk.

T["toggle: wikilink stripped from render line before mutation"] = function()
  -- Render line includes wikilink appended by layout.lua.
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.toggle").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Status toggled; wikilink must be absent from the mutated line.
  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["done: wikilink stripped from render line before mutation"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.done").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [x]")
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["cancel: wikilink stripped from render line before mutation"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.cancel").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [-]")
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["inProgress: wikilink stripped from render line before mutation"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.inProgress").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [/]")
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["onHold: wikilink stripped from render line before mutation"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.onHold").run({}, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:sub(1, 5), "- [h]")
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

-- ── toggle: respects user status overrides ────────────────────────────────────

T["toggle: respects user-overridden next via status.merge"] = function()
  local status = require("obsidian-tasks.task.status")
  -- Override: space -> / instead of the default space -> x.
  status.merge({ [" "] = { next = "/" } })

  local result = run_cmd_on_line("obsidian-tasks.cmd.toggle", "- [ ] My task")

  -- Restore defaults.
  status.merge({})

  MiniTest.expect.equality(result, "- [/] My task")
end

-- ── done_date_tz wiring ───────────────────────────────────────────────────────

--- Capture the format argument passed to os.date; returns captured_fmt getter + restore fn.
local function capture_os_date_fmt(fixed_result)
  local captured = nil
  local orig = os.date
  os.date = function(fmt)
    captured = fmt
    return fixed_result
  end
  return function()
    os.date = orig
    return captured
  end
end

T["done: done_date_tz=utc prepends ! to format passed to os.date"] = function()
  local ot_restore = install_mock("obsidian-tasks", {
    opts = { done_date_format = "%Y-%m-%d", done_date_tz = "utc" },
  })
  local get_fmt = capture_os_date_fmt("2024-01-15")
  run_cmd_on_line("obsidian-tasks.cmd.done", "- [ ] My task")
  local fmt = get_fmt()
  ot_restore()
  MiniTest.expect.equality(fmt ~= nil and fmt:sub(1, 1) == "!", true)
end

T["done: done_date_tz=local does not prepend ! to format"] = function()
  local ot_restore = install_mock("obsidian-tasks", {
    opts = { done_date_format = "%Y-%m-%d", done_date_tz = "local" },
  })
  local get_fmt = capture_os_date_fmt("2024-01-15")
  run_cmd_on_line("obsidian-tasks.cmd.done", "- [ ] My task")
  local fmt = get_fmt()
  ot_restore()
  MiniTest.expect.equality(fmt ~= nil and fmt:sub(1, 1) ~= "!", true)
end

T["cancel: done_date_tz=utc prepends ! to format passed to os.date"] = function()
  local ot_restore = install_mock("obsidian-tasks", {
    opts = { done_date_format = "%Y-%m-%d", done_date_tz = "utc" },
  })
  local get_fmt = capture_os_date_fmt("2024-01-15")
  run_cmd_on_line("obsidian-tasks.cmd.cancel", "- [ ] My task")
  local fmt = get_fmt()
  ot_restore()
  MiniTest.expect.equality(fmt ~= nil and fmt:sub(1, 1) == "!", true)
end

T["cancel: done_date_tz=local does not prepend ! to format"] = function()
  local ot_restore = install_mock("obsidian-tasks", {
    opts = { done_date_format = "%Y-%m-%d", done_date_tz = "local" },
  })
  local get_fmt = capture_os_date_fmt("2024-01-15")
  run_cmd_on_line("obsidian-tasks.cmd.cancel", "- [ ] My task")
  local fmt = get_fmt()
  ot_restore()
  MiniTest.expect.equality(fmt ~= nil and fmt:sub(1, 1) ~= "!", true)
end

return T
