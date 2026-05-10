-- tests/unit/test_cmd_date.lua
-- Tests for date commands: due, scheduled, start.
-- Also covers the cmp/date_nl stub parser.
--
-- Covers:
--   • date_nl.parse: ISO dates, today, tomorrow, invalid inputs
--   • due/scheduled/start: set date on task (emoji format)
--   • due/scheduled/start: set date on task (dataview format preserved)
--   • Overwrite: existing date replaced, not appended
--   • Visual range: all tasks in range get date set
--   • No arg: emoji appended to task line (insert mode is UI-only, not tested)
--   • No arg on non-task line: error emitted
--   • No arg on render line: warning emitted
--   • Invalid date arg: error emitted
--   • No task in range with arg: warning emitted
--   • Render line with arg: warning emitted

local T = MiniTest.new_set()

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function buf_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

local function mock_source_ctx()
  return install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })
end

local function mock_render_ctx()
  return install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return { src_path = "/vault/note.md", src_line = 1, src_hash = "h1", source_text_hash = "s1" }
    end,
  })
end

local function mock_current_buf(bufnr)
  local orig = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  return function()
    vim.api.nvim_get_current_buf = orig
  end
end

--- Capture vim.notify calls during f().
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

--- Run a date command module against a single-line buffer; return the resulting line.
--- @param mod_name  string  e.g. "obsidian-tasks.cmd.due"
--- @param line      string  source task line
--- @param args      table   argument list passed to mod.run
--- @param range     table?  { line1, line2 } defaults to { 1, 1 }
--- @return string, function  resulting_line, cleanup_fn
local function run_date_cmd(mod_name, line, args, range)
  range = range or { line1 = 1, line2 = 1 }
  local bufnr = make_buf({ line })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  -- Suppress startinsert! in headless tests.
  local orig_cmd = vim.cmd
  vim.cmd = function(c)
    if type(c) == "string" and c:find("startinsert") then
      return
    end
    orig_cmd(c)
  end

  local mod = require(mod_name)
  mod.run(args, range)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local result = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return result[1]
end

-- ── cmp/date_nl stub ──────────────────────────────────────────────────────────

T["date_nl: ISO YYYY-MM-DD returns the date string"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse("2026-12-31"), "2026-12-31")
end

T["date_nl: leading/trailing whitespace is trimmed"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse("  2026-06-15  "), "2026-06-15")
end

T["date_nl: 'today' returns YYYY-MM-DD for today"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  local expected = os.date("%Y-%m-%d")
  MiniTest.expect.equality(date_nl.parse("today"), expected)
end

T["date_nl: 'TODAY' (uppercase) also works"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  local expected = os.date("%Y-%m-%d")
  MiniTest.expect.equality(date_nl.parse("TODAY"), expected)
end

T["date_nl: 'tomorrow' returns YYYY-MM-DD for tomorrow"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  local expected = os.date("%Y-%m-%d", os.time() + 86400)
  MiniTest.expect.equality(date_nl.parse("tomorrow"), expected)
end

T["date_nl: invalid string returns nil"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse("next week"), nil)
  MiniTest.expect.equality(date_nl.parse("yesterday"), nil)
  MiniTest.expect.equality(date_nl.parse("not-a-date"), nil)
end

T["date_nl: empty string returns nil"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse(""), nil)
end

T["date_nl: nil returns nil"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse(nil), nil)
end

T["date_nl: invalid month returns nil"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse("2026-13-01"), nil)
end

T["date_nl: invalid day returns nil"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse("2026-06-00"), nil)
end

T["date_nl: partial ISO format returns nil"] = function()
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  MiniTest.expect.equality(date_nl.parse("2026-12"), nil)
  MiniTest.expect.equality(date_nl.parse("2026"), nil)
end

-- ── due: with arg ─────────────────────────────────────────────────────────────

T["due: with ISO date sets 📅 field on task"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.due", "- [ ] My task", { "2026-12-31" })
  MiniTest.expect.equality(result:find("2026%-12%-31") ~= nil, true)
  MiniTest.expect.equality(result:find("\xf0\x9f\x93\x85") ~= nil, true) -- 📅
end

T["due: with 'today' sets today's date"] = function()
  local today = os.date("%Y-%m-%d")
  local result = run_date_cmd("obsidian-tasks.cmd.due", "- [ ] My task", { "today" })
  MiniTest.expect.equality(result:find(today:gsub("%-", "%%-")) ~= nil, true)
end

T["due: overwrites existing due date"] = function()
  -- Task already has 📅 2025-01-01; should become 📅 2026-12-31.
  local result = run_date_cmd("obsidian-tasks.cmd.due", "- [ ] My task \xf0\x9f\x93\x85 2025-01-01", { "2026-12-31" })
  MiniTest.expect.equality(result:find("2025%-01%-01") == nil, true) -- old date gone
  MiniTest.expect.equality(result:find("2026%-12%-31") ~= nil, true) -- new date present
end

T["due: preserves dataview origin when overwriting"] = function()
  -- Task uses dataview format for due: [due:: 2025-01-01].
  local result = run_date_cmd("obsidian-tasks.cmd.due", "- [ ] My task [due:: 2025-01-01]", { "2026-12-31" })
  -- Should emit dataview format since _origin.due = "dataview".
  MiniTest.expect.equality(result:find("%[due::") ~= nil, true)
  MiniTest.expect.equality(result:find("2026%-12%-31") ~= nil, true)
  MiniTest.expect.equality(result:find("2025%-01%-01") == nil, true)
end

T["due: preserves other fields when setting due"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.due", "- [ ] My task \xe2\x8f\xb3 2026-01-01", { "2026-12-31" }) -- ⏳
  MiniTest.expect.equality(result:find("2026%-12%-31") ~= nil, true)
  -- Scheduled date should still be present.
  MiniTest.expect.equality(result:find("2026%-01%-01") ~= nil, true)
end

T["due: invalid date arg emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.due").run({ "not-a-date" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()

  -- Line must be unchanged.
  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  MiniTest.expect.equality(lines[1], "- [ ] My task")

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("due") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["due: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.due").run({ "2026-12-31" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("due") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["due: render line with arg emits warning"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.due").run({ "2026-12-31" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "- [ ] Render task")
  local found_warn = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

-- ── due: visual range ────────────────────────────────────────────────────────

T["due: visual range — 3 tasks all get due date"] = function()
  local bufnr = make_buf({
    "- [ ] Task one",
    "- [ ] Task two",
    "- [ ] Task three",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.due").run({ "2026-12-31" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#lines, 3)
  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:find("2026%-12%-31") ~= nil, true, "line " .. i .. " missing date")
    MiniTest.expect.equality(line:find("\xf0\x9f\x93\x85") ~= nil, true, "line " .. i .. " missing emoji")
  end
end

T["due: visual range skips non-task lines silently"] = function()
  local bufnr = make_buf({
    "- [ ] Task one",
    "not a task",
    "- [ ] Task two",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.due").run({ "2026-12-31" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find("2026%-12%-31") ~= nil, true)
  MiniTest.expect.equality(lines[2], "not a task") -- unchanged
  MiniTest.expect.equality(lines[3]:find("2026%-12%-31") ~= nil, true)
end

-- ── due: no arg ───────────────────────────────────────────────────────────────

T["due: no arg appends emoji + space to task line"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.due", "- [ ] My task", {})
  -- Line should end with "📅 " (emoji + space).
  MiniTest.expect.equality(result:find("\xf0\x9f\x93\x85 $") ~= nil, true)
end

T["due: no arg on non-task line emits error"] = function()
  local bufnr = make_buf({ "not a task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.due").run({}, { line1 = 1, line2 = 1 })
  end)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "not a task") -- unchanged
  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("no task at cursor") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["due: no arg on render line emits warning"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.due").run({}, { line1 = 1, line2 = 1 })
  end)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "- [ ] Render task") -- unchanged
  local found_warn = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

-- ── scheduled: smoke tests ───────────────────────────────────────────────────

T["scheduled: with ISO date sets ⏳ field"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.scheduled", "- [ ] My task", { "2026-06-15" })
  MiniTest.expect.equality(result:find("2026%-06%-15") ~= nil, true)
  MiniTest.expect.equality(result:find("\xe2\x8f\xb3") ~= nil, true) -- ⏳
end

T["scheduled: overwrites existing scheduled date"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.scheduled", "- [ ] My task \xe2\x8f\xb3 2025-03-01", { "2026-06-15" })
  MiniTest.expect.equality(result:find("2025%-03%-01") == nil, true)
  MiniTest.expect.equality(result:find("2026%-06%-15") ~= nil, true)
end

T["scheduled: visual range — 3 tasks all get scheduled date"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [ ] Task B",
    "- [ ] Task C",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.scheduled").run({ "2026-06-15" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:find("2026%-06%-15") ~= nil, true, "line " .. i .. " missing date")
  end
end

T["scheduled: no arg appends ⏳ emoji + space to task line"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.scheduled", "- [ ] My task", {})
  MiniTest.expect.equality(result:find("\xe2\x8f\xb3 $") ~= nil, true)
end

T["scheduled: no arg on non-task line emits error"] = function()
  local bufnr = make_buf({ "not a task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.scheduled").run({}, { line1 = 1, line2 = 1 })
  end)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("no task at cursor") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["scheduled: invalid date emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.scheduled").run({ "not-a-date" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("scheduled") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

-- ── start: smoke tests ────────────────────────────────────────────────────────

T["start: with ISO date sets 🛫 field"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.start", "- [ ] My task", { "2026-03-10" })
  MiniTest.expect.equality(result:find("2026%-03%-10") ~= nil, true)
  MiniTest.expect.equality(result:find("\xf0\x9f\x9b\xab") ~= nil, true) -- 🛫
end

T["start: overwrites existing start date"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.start", "- [ ] My task \xf0\x9f\x9b\xab 2025-01-15", { "2026-03-10" })
  MiniTest.expect.equality(result:find("2025%-01%-15") == nil, true)
  MiniTest.expect.equality(result:find("2026%-03%-10") ~= nil, true)
end

T["start: visual range — 3 tasks all get start date"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [ ] Task B",
    "- [ ] Task C",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.start").run({ "2026-03-10" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:find("2026%-03%-10") ~= nil, true, "line " .. i .. " missing date")
  end
end

T["start: no arg appends 🛫 emoji + space to task line"] = function()
  local result = run_date_cmd("obsidian-tasks.cmd.start", "- [ ] My task", {})
  MiniTest.expect.equality(result:find("\xf0\x9f\x9b\xab $") ~= nil, true)
end

T["start: no arg on non-task line emits error"] = function()
  local bufnr = make_buf({ "not a task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.start").run({}, { line1 = 1, line2 = 1 })
  end)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("no task at cursor") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["start: invalid date emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.start").run({ "foobar" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("start") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

-- ── cross-field: preserving unrelated fields ──────────────────────────────────

T["due: does not disturb scheduled date or description"] = function()
  -- Task has scheduled date and description text.
  local line = "- [ ] Write report \xe2\x8f\xb3 2026-01-01"
  local result = run_date_cmd("obsidian-tasks.cmd.due", line, { "2026-12-31" })
  -- Due added.
  MiniTest.expect.equality(result:find("2026%-12%-31") ~= nil, true)
  -- Scheduled preserved.
  MiniTest.expect.equality(result:find("2026%-01%-01") ~= nil, true)
  -- Description preserved.
  MiniTest.expect.equality(result:find("Write report") ~= nil, true)
end

T["start: does not disturb due date when set together"] = function()
  local line = "- [ ] My task \xf0\x9f\x93\x85 2026-06-01"
  local result = run_date_cmd("obsidian-tasks.cmd.start", line, { "2026-03-01" })
  -- Start added.
  MiniTest.expect.equality(result:find("2026%-03%-01") ~= nil, true)
  -- Due preserved.
  MiniTest.expect.equality(result:find("2026%-06%-01") ~= nil, true)
end

return T
