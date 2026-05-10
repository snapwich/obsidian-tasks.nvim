-- tests/unit/test_cmd_priority_recurrence_tags.lua
-- Tests for: priority, recurrence, tags subcommands.
--
-- Covers:
--   • priority: set each of the 6 levels (verify exact emoji from fields.priority_levels)
--   • priority: none removes the field
--   • priority: none is a no-op when field is absent
--   • priority: invalid level emits error
--   • priority: missing level emits error
--   • priority: visual range — all tasks get the priority
--   • priority: render line mutates buffer in-place
--   • priority: no task in range emits warning
--   • priority: tab completion returns 6 levels
--   • recurrence: set raw pattern
--   • recurrence: overwrites existing recurrence
--   • recurrence: multi-word pattern
--   • recurrence: no arg appends 🔁 emoji + space
--   • recurrence: no arg on non-task line emits error
--   • recurrence: no arg on render line appends emoji in-place
--   • recurrence: visual range — all tasks get recurrence
--   • recurrence: render line with arg mutates buffer in-place
--   • recurrence: no task in range emits warning
--   • tags add: appends tag as trailing tag
--   • tags add: idempotent (no duplicates)
--   • tags remove: removes trailing tag
--   • tags remove: removes embedded tag from description
--   • tags remove: silent no-op when tag absent
--   • tags: missing sub-subcommand emits error
--   • tags: unknown sub-subcommand emits error
--   • tags: missing tag arg emits error
--   • tags: tag without '#' emits error
--   • tags: no task in range emits warning
--   • tags: render line add mutates buffer in-place
--   • tags: render line remove mutates buffer in-place
--   • tags: visual range add — all tasks get tag
--   • tags: visual range remove — all tasks lose tag

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

--- Run a command module against a single-line source buffer; return resulting line.
--- @param mod_name string  e.g. "obsidian-tasks.cmd.priority"
--- @param line     string  source task line
--- @param args     table   arguments passed to mod.run
--- @param range    table?  { line1, line2 } defaults to { 1, 1 }
--- @return string
local function run_cmd(mod_name, line, args, range)
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

  require(mod_name).run(args, range)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local result = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return result[1]
end

-- ════════════════════════════════════════════════════════════════════════════
-- priority
-- ════════════════════════════════════════════════════════════════════════════

-- Exact emoji bytes from fields.priority_levels:
--   highest → 🔺  \xf0\x9f\x94\xba
--   high    → ⏫  \xe2\x8f\xab
--   medium  → 🔼  \xf0\x9f\x94\xbc
--   low     → 🔽  \xf0\x9f\x94\xbd
--   lowest  → ⏬  \xe2\x8f\xac

T["priority: highest sets 🔺"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local result = run_cmd("obsidian-tasks.cmd.priority", "- [ ] My task", { "highest" })
  MiniTest.expect.equality(result:find(fields.priority_levels.highest, 1, true) ~= nil, true)
end

T["priority: high sets ⏫"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local result = run_cmd("obsidian-tasks.cmd.priority", "- [ ] My task", { "high" })
  MiniTest.expect.equality(result:find(fields.priority_levels.high, 1, true) ~= nil, true)
end

T["priority: medium sets 🔼"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local result = run_cmd("obsidian-tasks.cmd.priority", "- [ ] My task", { "medium" })
  MiniTest.expect.equality(result:find(fields.priority_levels.medium, 1, true) ~= nil, true)
end

T["priority: low sets 🔽"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local result = run_cmd("obsidian-tasks.cmd.priority", "- [ ] My task", { "low" })
  MiniTest.expect.equality(result:find(fields.priority_levels.low, 1, true) ~= nil, true)
end

T["priority: lowest sets ⏬"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local result = run_cmd("obsidian-tasks.cmd.priority", "- [ ] My task", { "lowest" })
  MiniTest.expect.equality(result:find(fields.priority_levels.lowest, 1, true) ~= nil, true)
end

T["priority: none removes the priority field"] = function()
  local fields = require("obsidian-tasks.task.fields")
  -- Task already has high priority (⏫).
  local line = "- [ ] My task " .. fields.priority_levels.high
  local result = run_cmd("obsidian-tasks.cmd.priority", line, { "none" })
  -- All priority emojis must be gone.
  for _, emoji in pairs(fields.priority_levels) do
    MiniTest.expect.equality(result:find(emoji, 1, true) == nil, true, "emoji should be removed: " .. emoji)
  end
end

T["priority: none is a no-op when field absent"] = function()
  local result = run_cmd("obsidian-tasks.cmd.priority", "- [ ] My task", { "none" })
  MiniTest.expect.equality(result, "- [ ] My task")
end

T["priority: overwrites existing priority"] = function()
  local fields = require("obsidian-tasks.task.fields")
  -- Task has high (⏫); change to highest (🔺).
  local line = "- [ ] My task " .. fields.priority_levels.high
  local result = run_cmd("obsidian-tasks.cmd.priority", line, { "highest" })
  MiniTest.expect.equality(result:find(fields.priority_levels.highest, 1, true) ~= nil, true)
  MiniTest.expect.equality(result:find(fields.priority_levels.high, 1, true) == nil, true)
end

T["priority: preserves description and other fields"] = function()
  local fields = require("obsidian-tasks.task.fields")
  -- Task has due date.
  local line = "- [ ] Write report \xf0\x9f\x93\x85 2026-06-01"
  local result = run_cmd("obsidian-tasks.cmd.priority", line, { "high" })
  MiniTest.expect.equality(result:find(fields.priority_levels.high, 1, true) ~= nil, true)
  MiniTest.expect.equality(result:find("2026%-06%-01") ~= nil, true)
  MiniTest.expect.equality(result:find("Write report") ~= nil, true)
end

T["priority: invalid level emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.priority").run({ "urgent" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "- [ ] My task") -- unchanged
  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("invalid level") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["priority: missing level emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.priority").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("missing level") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["priority: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.priority").run({ "high" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("priority") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["priority: render line mutates buffer in-place"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "high" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must have the high-priority emoji set.
  MiniTest.expect.equality(lines[1]:find(fields.priority_levels.high, 1, true) ~= nil, true)
end

T["priority: visual range — all tasks get priority"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [ ] Task B",
    "- [ ] Task C",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "medium" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(
      line:find(fields.priority_levels.medium, 1, true) ~= nil,
      true,
      "line " .. i .. " missing medium priority emoji"
    )
  end
end

T["priority: visual range skips non-task lines"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local bufnr = make_buf({
    "- [ ] Task A",
    "not a task",
    "- [ ] Task B",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "low" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find(fields.priority_levels.low, 1, true) ~= nil, true)
  MiniTest.expect.equality(lines[2], "not a task")
  MiniTest.expect.equality(lines[3]:find(fields.priority_levels.low, 1, true) ~= nil, true)
end

T["priority: tab completion returns all 6 levels"] = function()
  local mod = require("obsidian-tasks.cmd.priority")
  local completions = mod.complete("", "", 0)
  -- Must include all 6 levels.
  local expected = { "highest", "high", "medium", "low", "lowest", "none" }
  MiniTest.expect.equality(#completions, #expected)
  local set = {}
  for _, v in ipairs(completions) do
    set[v] = true
  end
  for _, v in ipairs(expected) do
    MiniTest.expect.equality(set[v], true, "missing level: " .. v)
  end
end

T["priority: tab completion filters by prefix"] = function()
  local mod = require("obsidian-tasks.cmd.priority")
  local completions = mod.complete("h", "", 0)
  -- "highest" and "high" start with "h".
  MiniTest.expect.equality(#completions, 2)
  local set = {}
  for _, v in ipairs(completions) do
    set[v] = true
  end
  MiniTest.expect.equality(set["highest"], true)
  MiniTest.expect.equality(set["high"], true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- recurrence
-- ════════════════════════════════════════════════════════════════════════════

-- 🔁 emoji bytes: \xf0\x9f\x94\x81

T["recurrence: sets raw pattern on task"] = function()
  local result = run_cmd("obsidian-tasks.cmd.recurrence", "- [ ] My task", { "every week" })
  MiniTest.expect.equality(result:find("every week") ~= nil, true)
  MiniTest.expect.equality(result:find("\xf0\x9f\x94\x81") ~= nil, true) -- 🔁
end

T["recurrence: multi-word pattern is joined correctly"] = function()
  local result = run_cmd("obsidian-tasks.cmd.recurrence", "- [ ] My task", { "every", "2", "weeks" })
  MiniTest.expect.equality(result:find("every 2 weeks") ~= nil, true)
end

T["recurrence: overwrites existing recurrence"] = function()
  -- Task already has recurrence: 🔁 every day
  local line = "- [ ] My task \xf0\x9f\x94\x81 every day"
  local result = run_cmd("obsidian-tasks.cmd.recurrence", line, { "every week" })
  MiniTest.expect.equality(result:find("every week") ~= nil, true)
  MiniTest.expect.equality(result:find("every day") == nil, true)
end

T["recurrence: preserves description and other fields"] = function()
  local line = "- [ ] Write report \xf0\x9f\x93\x85 2026-06-01"
  local result = run_cmd("obsidian-tasks.cmd.recurrence", line, { "every week" })
  MiniTest.expect.equality(result:find("every week") ~= nil, true)
  MiniTest.expect.equality(result:find("2026%-06%-01") ~= nil, true)
  MiniTest.expect.equality(result:find("Write report") ~= nil, true)
end

T["recurrence: no arg appends 🔁 emoji + space to task line"] = function()
  local result = run_cmd("obsidian-tasks.cmd.recurrence", "- [ ] My task", {})
  MiniTest.expect.equality(result:find("\xf0\x9f\x94\x81 $") ~= nil, true)
end

T["recurrence: no arg on non-task line emits error"] = function()
  local bufnr = make_buf({ "not a task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.recurrence").run({}, { line1 = 1, line2 = 1 })
  end)

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "not a task")
  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("no task at cursor") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["recurrence: no arg on render line appends emoji in-place"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end -- suppress startinsert!

  require("obsidian-tasks.cmd.recurrence").run({}, { line1 = 1, line2 = 1 })

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must have the 🔁 emoji appended.
  MiniTest.expect.equality(lines[1]:find("\xf0\x9f\x94\x81 $") ~= nil, true)
end

T["recurrence: render line with arg mutates buffer in-place"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.recurrence").run({ "every week" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must have the recurrence pattern set.
  MiniTest.expect.equality(lines[1]:find("every week") ~= nil, true)
  MiniTest.expect.equality(lines[1]:find("\xf0\x9f\x94\x81") ~= nil, true) -- 🔁
end

T["recurrence: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.recurrence").run({ "every week" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("recurrence") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["recurrence: visual range — all tasks get recurrence"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [ ] Task B",
    "- [ ] Task C",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.recurrence").run({ "every day" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:find("every day") ~= nil, true, "line " .. i .. " missing recurrence")
    MiniTest.expect.equality(line:find("\xf0\x9f\x94\x81") ~= nil, true, "line " .. i .. " missing emoji")
  end
end

T["recurrence: dataview origin preserved when overwriting"] = function()
  local line = "- [ ] My task [repeat:: every day]"
  local result = run_cmd("obsidian-tasks.cmd.recurrence", line, { "every week" })
  MiniTest.expect.equality(result:find("%[repeat::") ~= nil, true)
  MiniTest.expect.equality(result:find("every week") ~= nil, true)
  MiniTest.expect.equality(result:find("every day") == nil, true)
end

-- ════════════════════════════════════════════════════════════════════════════
-- tags
-- ════════════════════════════════════════════════════════════════════════════

T["tags add: appends tag as trailing tag"] = function()
  local result = run_cmd("obsidian-tasks.cmd.tags", "- [ ] My task", { "add", "#project" })
  MiniTest.expect.equality(result:find("#project") ~= nil, true)
end

T["tags add: idempotent — does not duplicate existing tag"] = function()
  -- Tag already present as trailing.
  local line = "- [ ] My task #project"
  local result = run_cmd("obsidian-tasks.cmd.tags", line, { "add", "#project" })
  -- Should appear exactly once.
  local count = 0
  for _ in result:gmatch("#project") do
    count = count + 1
  end
  MiniTest.expect.equality(count, 1)
end

T["tags add: idempotent — does not duplicate embedded tag"] = function()
  -- Tag embedded in description.
  local line = "- [ ] My #project task"
  local result = run_cmd("obsidian-tasks.cmd.tags", line, { "add", "#project" })
  local count = 0
  for _ in result:gmatch("#project") do
    count = count + 1
  end
  MiniTest.expect.equality(count, 1)
end

T["tags add: multiple different tags can be added sequentially"] = function()
  -- Add first tag.
  local line1 = run_cmd("obsidian-tasks.cmd.tags", "- [ ] My task", { "add", "#work" })
  -- Add second tag to the result.
  local result = run_cmd("obsidian-tasks.cmd.tags", line1, { "add", "#urgent" })
  MiniTest.expect.equality(result:find("#work") ~= nil, true)
  MiniTest.expect.equality(result:find("#urgent") ~= nil, true)
end

T["tags remove: removes trailing tag"] = function()
  local line = "- [ ] My task \xf0\x9f\x93\x85 2026-01-01 #project"
  local result = run_cmd("obsidian-tasks.cmd.tags", line, { "remove", "#project" })
  MiniTest.expect.equality(result:find("#project") == nil, true)
  -- Other content preserved.
  MiniTest.expect.equality(result:find("2026%-01%-01") ~= nil, true)
end

T["tags remove: removes embedded tag from description"] = function()
  local line = "- [ ] My #project task"
  local result = run_cmd("obsidian-tasks.cmd.tags", line, { "remove", "#project" })
  MiniTest.expect.equality(result:find("#project") == nil, true)
  MiniTest.expect.equality(result:find("My") ~= nil, true)
  MiniTest.expect.equality(result:find("task") ~= nil, true)
end

T["tags remove: silent no-op when tag absent"] = function()
  local line = "- [ ] My task"
  local result = run_cmd("obsidian-tasks.cmd.tags", line, { "remove", "#missing" })
  -- Line unchanged.
  MiniTest.expect.equality(result, "- [ ] My task")
end

T["tags remove: preserves other tags when removing one"] = function()
  local line = "- [ ] My task #work #urgent"
  local result = run_cmd("obsidian-tasks.cmd.tags", line, { "remove", "#work" })
  MiniTest.expect.equality(result:find("#work") == nil, true)
  MiniTest.expect.equality(result:find("#urgent") ~= nil, true)
end

T["tags: missing sub-subcommand emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.tags").run({}, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("missing sub%-subcommand") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["tags: unknown sub-subcommand emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.tags").run({ "toggle", "#foo" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("unknown sub%-subcommand") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["tags: missing tag arg emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.tags").run({ "add" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("missing tag argument") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["tags: tag without '#' emits error"] = function()
  local bufnr = make_buf({ "- [ ] My task" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.tags").run({ "add", "project" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_error = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("must start with") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["tags: no task in range emits warning"] = function()
  local bufnr = make_buf({ "plain text" })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local calls = capture_notify(function()
    require("obsidian-tasks.cmd.tags").run({ "add", "#foo" }, { line1 = 1, line2 = 1 })
  end)

  draw_cleanup()
  buf_cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  local found_warn = false
  for _, c in ipairs(calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("tags") then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)
end

T["tags add: render line mutates buffer in-place"] = function()
  local bufnr = make_buf({ "- [ ] Render task" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.tags").run({ "add", "#foo" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must have the tag added.
  MiniTest.expect.equality(lines[1]:find("#foo") ~= nil, true)
end

T["tags remove: render line mutates buffer in-place"] = function()
  local bufnr = make_buf({ "- [ ] Render task #foo" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.tags").run({ "remove", "#foo" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must have the tag removed.
  MiniTest.expect.equality(lines[1]:find("#foo") == nil, true)
  MiniTest.expect.equality(lines[1]:find("Render task") ~= nil, true)
end

T["tags add: visual range — all tasks get tag"] = function()
  local bufnr = make_buf({
    "- [ ] Task A",
    "- [ ] Task B",
    "- [ ] Task C",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.tags").run({ "add", "#bulk" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:find("#bulk") ~= nil, true, "line " .. i .. " missing tag")
  end
end

T["tags remove: visual range — all tasks lose tag"] = function()
  local bufnr = make_buf({
    "- [ ] Task A #bulk",
    "- [ ] Task B #bulk",
    "- [ ] Task C #bulk",
  })
  local draw_cleanup = mock_source_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.tags").run({ "remove", "#bulk" }, { line1 = 1, line2 = 3 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  for i, line in ipairs(lines) do
    MiniTest.expect.equality(line:find("#bulk") == nil, true, "line " .. i .. " still has tag")
  end
end

-- ── Render-line wikilink regression ──────────────────────────────────────────
--
-- mock_render_ctx returns src_path = "/vault/note.md".
-- fnamemodify(":t:r") → "note" → wikilink suffix = " [[note]]".
-- After the fix, resolve_task_at strips the suffix before parsing so all cmd
-- modules serialize a clean (no-wikilink) result back to the render buffer.

T["priority: wikilink stripped from render line before setting priority"] = function()
  local fields = require("obsidian-tasks.task.fields")
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.priority").run({ "high" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find(fields.priority_levels.high, 1, true) ~= nil, true)
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["recurrence: wikilink stripped from render line (with arg)"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.recurrence").run({ "every week" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find("every week") ~= nil, true)
  MiniTest.expect.equality(lines[1]:find("\xf0\x9f\x94\x81") ~= nil, true) -- 🔁
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["recurrence: wikilink stripped from render line (no-arg path)"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  local orig_cmd = vim.cmd
  vim.cmd = function() end -- suppress startinsert!

  require("obsidian-tasks.cmd.recurrence").run({}, { line1 = 1, line2 = 1 })

  vim.cmd = orig_cmd
  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find("\xf0\x9f\x94\x81 $") ~= nil, true) -- 🔁
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["tags add: wikilink stripped from render line"] = function()
  local bufnr = make_buf({ "- [ ] Render task [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.tags").run({ "add", "#foo" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find("#foo") ~= nil, true)
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
end

T["tags remove: wikilink stripped from render line"] = function()
  -- Buffer has both a tag and a wikilink suffix appended by layout.lua.
  local bufnr = make_buf({ "- [ ] Render task #bar [[note]]" })
  local draw_cleanup = mock_render_ctx()
  local buf_cleanup = mock_current_buf(bufnr)

  require("obsidian-tasks.cmd.tags").run({ "remove", "#bar" }, { line1 = 1, line2 = 1 })

  draw_cleanup()
  buf_cleanup()

  local lines = buf_lines(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1]:find("#bar") == nil, true)
  MiniTest.expect.equality(lines[1]:find("%[%[") == nil, true)
  MiniTest.expect.equality(lines[1]:find("Render task") ~= nil, true)
end

T["tags: tab completion returns add and remove"] = function()
  local mod = require("obsidian-tasks.cmd.tags")
  local completions = mod.complete("", "", 0)
  MiniTest.expect.equality(#completions, 2)
  local set = {}
  for _, v in ipairs(completions) do
    set[v] = true
  end
  MiniTest.expect.equality(set["add"], true)
  MiniTest.expect.equality(set["remove"], true)
end

T["tags: tab completion filters by prefix"] = function()
  local mod = require("obsidian-tasks.cmd.tags")
  local completions = mod.complete("r", "", 0)
  MiniTest.expect.equality(#completions, 1)
  MiniTest.expect.equality(completions[1], "remove")
end

return T
