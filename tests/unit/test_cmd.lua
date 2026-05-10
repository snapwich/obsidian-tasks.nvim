-- tests/unit/test_cmd.lua
-- Unit tests for cmd/init.lua — dispatcher, resolver, bulk-range helper.

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

--- Capture all vim.notify calls during f().
--- Returns list of { msg, level } tables.
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

-- ── resolve_task_at: source buffer ───────────────────────────────────────────

T["resolve_task_at: task line returns {kind='source'}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  -- Stub draw.is_render_line → nil (not a render line)
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({ "- [ ] My task" })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(result ~= nil, true)
  MiniTest.expect.equality(result.kind, "source")
  MiniTest.expect.equality(result.bufnr, bufnr)
  MiniTest.expect.equality(result.lnum, 0)
  MiniTest.expect.equality(result.task ~= nil, true)
  MiniTest.expect.equality(result.task.status_symbol, " ")
end

T["resolve_task_at: non-task line returns nil"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({ "just a plain paragraph" })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(result, nil)
end

T["resolve_task_at: empty buffer line returns nil"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({ "" })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(result, nil)
end

T["resolve_task_at: lnum beyond buffer returns nil"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({ "- [ ] Task" })
  local result = cmd.resolve_task_at(bufnr, 99)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(result, nil)
end

-- ── resolve_task_at: render buffer ───────────────────────────────────────────

T["resolve_task_at: render line returns {kind='render'}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local fake_info = {
    src_path = "/vault/note.md",
    src_line = 5,
    src_hash = "abc123",
    source_text_hash = "def456",
  }
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return fake_info
    end,
  })

  local bufnr = make_buf({ "- [ ] Rendered task" })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(result ~= nil, true)
  MiniTest.expect.equality(result.kind, "render")
  MiniTest.expect.equality(result.src_path, "/vault/note.md")
  MiniTest.expect.equality(result.src_line, 5)
  MiniTest.expect.equality(result.src_hash, "abc123")
  MiniTest.expect.equality(result.source_text_hash, "def456")
end

T["resolve_task_at: render line takes precedence over source parse"] = function()
  local cmd = require("obsidian-tasks.cmd")
  -- is_render_line returns info even if the line text is also a valid task.
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return { src_path = "/x.md", src_line = 1, src_hash = "h", source_text_hash = "s" }
    end,
  })

  local bufnr = make_buf({ "- [x] Done task" })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(result.kind, "render")
end

-- ── bulk_range ────────────────────────────────────────────────────────────────

T["bulk_range: returns all tasks in range"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({
    "- [ ] Task A",
    "not a task",
    "- [x] Task B",
    "## heading",
    "- [ ] Task C",
  })
  local results = cmd.bulk_range(bufnr, { line1 = 1, line2 = 5 })
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#results, 3)
  MiniTest.expect.equality(results[1].task.status_symbol, " ")
  MiniTest.expect.equality(results[2].task.status_symbol, "x")
  MiniTest.expect.equality(results[3].task.status_symbol, " ")
end

T["bulk_range: single line (no range)"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({ "- [ ] Only task" })
  local results = cmd.bulk_range(bufnr, { line1 = 1, line2 = 1 })
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#results, 1)
  MiniTest.expect.equality(results[1].kind, "source")
end

T["bulk_range: no tasks in range returns empty list"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  local bufnr = make_buf({ "plain text", "## heading", "another line" })
  local results = cmd.bulk_range(bufnr, { line1 = 1, line2 = 3 })
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#results, 0)
end

T["bulk_range: 1-indexed range maps to correct lines"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  -- Only line 2 (1-indexed) is a task.
  local bufnr = make_buf({ "not a task", "- [ ] Task", "not a task" })
  -- Range covering only line 2.
  local results = cmd.bulk_range(bufnr, { line1 = 2, line2 = 2 })
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(#results, 1)
  MiniTest.expect.equality(results[1].lnum, 1) -- 0-indexed
end

-- ── dispatch: known subcommand ────────────────────────────────────────────────

T["dispatch: calls mod.run with args and range for known subcmd"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local called_args, called_range
  local cleanup = install_mock("obsidian-tasks.cmd.toggle", {
    run = function(args, range)
      called_args = args
      called_range = range
    end,
  })

  cmd.dispatch({
    fargs = { "toggle" },
    line1 = 3,
    line2 = 5,
  })
  cleanup()

  MiniTest.expect.equality(called_args ~= nil, true)
  MiniTest.expect.equality(#called_args, 0)
  MiniTest.expect.equality(called_range.line1, 3)
  MiniTest.expect.equality(called_range.line2, 5)
end

T["dispatch: forwards extra args to mod.run"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local called_args
  local cleanup = install_mock("obsidian-tasks.cmd.priority", {
    run = function(args, _range)
      called_args = args
    end,
  })

  cmd.dispatch({
    fargs = { "priority", "high" },
    line1 = 1,
    line2 = 1,
  })
  cleanup()

  MiniTest.expect.equality(called_args ~= nil, true)
  MiniTest.expect.equality(#called_args, 1)
  MiniTest.expect.equality(called_args[1], "high")
end

-- ── dispatch: unknown subcommand ─────────────────────────────────────────────

T["dispatch: unknown subcmd emits error with valid list"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local notify_calls = capture_notify(function()
    cmd.dispatch({ fargs = { "nonexistent" }, line1 = 1, line2 = 1 })
  end)

  MiniTest.expect.equality(#notify_calls >= 1, true)
  local found_error = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("nonexistent") then
      found_error = true
      -- Must mention some valid subcmds.
      MiniTest.expect.equality(c.msg:find("toggle") ~= nil, true)
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["dispatch: missing subcmd emits error"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local notify_calls = capture_notify(function()
    cmd.dispatch({ fargs = {}, line1 = 1, line2 = 1 })
  end)

  MiniTest.expect.equality(#notify_calls >= 1, true)
  local found_error = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.ERROR then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

T["dispatch: empty string subcmd emits error"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local notify_calls = capture_notify(function()
    cmd.dispatch({ fargs = { "" }, line1 = 1, line2 = 1 })
  end)

  MiniTest.expect.equality(#notify_calls >= 1, true)
  local found_error = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.ERROR then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

-- ── dispatch: unimplemented (known but no module) ────────────────────────────

T["dispatch: known subcmd with missing module emits error"] = function()
  local cmd = require("obsidian-tasks.cmd")

  -- Ensure the module doesn't exist in cache.
  local orig = package.loaded["obsidian-tasks.cmd.render"]
  package.loaded["obsidian-tasks.cmd.render"] = nil
  -- Also make require fail by providing a loader that errors.
  local orig_preload = package.preload["obsidian-tasks.cmd.render"]
  package.preload["obsidian-tasks.cmd.render"] = function()
    error("no module")
  end

  local notify_calls = capture_notify(function()
    cmd.dispatch({ fargs = { "render" }, line1 = 1, line2 = 1 })
  end)

  package.loaded["obsidian-tasks.cmd.render"] = orig
  package.preload["obsidian-tasks.cmd.render"] = orig_preload

  local found_error = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.ERROR and c.msg:find("render") then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)
end

-- ── dispatch: range passed through ───────────────────────────────────────────

T["dispatch: range line1=line2 (single cursor) passed to mod.run"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local got_range
  local cleanup = install_mock("obsidian-tasks.cmd.done", {
    run = function(_args, range)
      got_range = range
    end,
  })

  cmd.dispatch({ fargs = { "done" }, line1 = 7, line2 = 7 })
  cleanup()

  MiniTest.expect.equality(got_range.line1, 7)
  MiniTest.expect.equality(got_range.line2, 7)
end

T["dispatch: visual range passed unchanged to mod.run"] = function()
  local cmd = require("obsidian-tasks.cmd")

  local got_range
  local cleanup = install_mock("obsidian-tasks.cmd.done", {
    run = function(_args, range)
      got_range = range
    end,
  })

  cmd.dispatch({ fargs = { "done" }, line1 = 4, line2 = 12 })
  cleanup()

  MiniTest.expect.equality(got_range.line1, 4)
  MiniTest.expect.equality(got_range.line2, 12)
end

-- ── dispatch: all valid subcmd names accepted ─────────────────────────────────

T["dispatch: all valid subcmd names route without 'unknown' error"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local valid = {
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
    "edit",
    "refresh",
    "render",
    "new",
  }

  for _, name in ipairs(valid) do
    -- Install a stub so require succeeds.
    local key = "obsidian-tasks.cmd." .. name
    local orig = package.loaded[key]
    package.loaded[key] = { run = function() end }

    local notify_calls = capture_notify(function()
      cmd.dispatch({ fargs = { name }, line1 = 1, line2 = 1 })
    end)

    package.loaded[key] = orig

    -- None of the notify calls should be ERROR mentioning "unknown".
    for _, c in ipairs(notify_calls) do
      if c.level == vim.log.levels.ERROR and c.msg:find("unknown") then
        error("unexpected 'unknown' error for subcmd: " .. name)
      end
    end
  end
end

return T
