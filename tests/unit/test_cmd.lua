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

-- ── resolve_task_at: render buffer (T7: uses managed.task_meta_for_row) ──────

T["resolve_task_at: render line returns {kind='render'} pointing at source"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local task_text = "- [ ] Rendered task"
  -- Create a real source file so the resolver can do drift check.
  local src_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ task_text }, src_path)

  local cleanup = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })

  local bufnr = make_buf({ task_text })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()

  -- Clean up source buffer opened by resolver.
  local src_bufnr = vim.fn.bufnr(src_path, false)
  if src_bufnr ~= -1 then
    vim.api.nvim_buf_delete(src_bufnr, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  MiniTest.expect.equality(result ~= nil, true)
  MiniTest.expect.equality(result.kind, "render")
  -- Resolver points at the SOURCE buffer (not the render buffer).
  MiniTest.expect.equality(result.src_path, src_path)
  MiniTest.expect.equality(result.src_line, 1) -- 1-indexed (source_row=0 → 1)
  MiniTest.expect.equality(result.task ~= nil, true)
  MiniTest.expect.equality(result.task.status_symbol, " ")
end

T["resolve_task_at: render line takes precedence over source parse"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local task_text = "- [x] Done task"
  local src_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ task_text }, src_path)

  -- managed.task_meta_for_row returns a meta → resolver treats as render line.
  local cleanup = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = task_text }
    end,
  })

  local bufnr = make_buf({ task_text })
  local result = cmd.resolve_task_at(bufnr, 0)
  cleanup()

  local src_bufnr = vim.fn.bufnr(src_path, false)
  if src_bufnr ~= -1 then
    vim.api.nvim_buf_delete(src_bufnr, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  MiniTest.expect.equality(result.kind, "render")
end

T["resolve_task_at: render line drift → returns nil with warn"] = function()
  local cmd = require("obsidian-tasks.cmd")
  -- Source file has a DIFFERENT line → drift detected.
  local src_path = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "- [x] Changed externally" }, src_path)

  local cleanup = install_mock("obsidian-tasks.render.managed", {
    task_meta_for_row = function()
      return { source_file = src_path, source_row = 0, task_text = "- [ ] Original task" }
    end,
  })

  local bufnr = make_buf({ "- [ ] Original task" })
  local notify_calls = capture_notify(function()
    local result = cmd.resolve_task_at(bufnr, 0)
    MiniTest.expect.equality(result, nil)
  end)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)

  local found_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and c.msg:find("drift", 1, true) then
      found_warn = true
      break
    end
  end
  MiniTest.expect.equality(found_warn, true)
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

-- ── M._completion: top-level subcmd name completion ─────────────────────────

T["completion: empty arg_lead returns all 18 valid subcmds"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("", "ObsidianTask ", 13)
  MiniTest.expect.equality(#result, 18)
  local set = {}
  for _, v in ipairs(result) do
    set[v] = true
  end
  MiniTest.expect.equality(set["toggle"], true)
  MiniTest.expect.equality(set["done"], true)
  MiniTest.expect.equality(set["new"], true)
  MiniTest.expect.equality(set["inProgress"], true)
  MiniTest.expect.equality(set["goto"], true)
end

T["completion: prefix 'to' returns only {toggle}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("to", "ObsidianTask to", 15)
  MiniTest.expect.equality(#result, 1)
  MiniTest.expect.equality(result[1], "toggle")
end

T["completion: prefix 's' returns {scheduled, start}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("s", "ObsidianTask s", 14)
  -- "scheduled" and "start" both start with "s"
  MiniTest.expect.equality(#result, 2)
  local set = {}
  for _, v in ipairs(result) do
    set[v] = true
  end
  MiniTest.expect.equality(set["scheduled"], true)
  MiniTest.expect.equality(set["start"], true)
end

T["completion: prefix with no matches returns {}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("zzz", "ObsidianTask zzz", 16)
  MiniTest.expect.equality(#result, 0)
end

-- ── M._completion: delegation to subcmd M.complete ───────────────────────────

T["completion: second word delegates to subcmd M.complete"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.cmd.priority", {
    run = function() end,
    complete = function(arg_lead, _cmdline, _pos)
      return { "marker-" .. arg_lead }
    end,
  })
  -- cmdline: "ObsidianTask priority h"  — arg_lead = "h"
  local result = cmd._completion("h", "ObsidianTask priority h", 23)
  cleanup()
  MiniTest.expect.equality(#result, 1)
  MiniTest.expect.equality(result[1], "marker-h")
end

T["completion: second word with no M.complete returns {}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local cleanup = install_mock("obsidian-tasks.cmd.toggle", {
    run = function() end,
    -- deliberately no complete field
  })
  local result = cmd._completion("x", "ObsidianTask toggle x", 21)
  cleanup()
  MiniTest.expect.equality(#result, 0)
end

T["completion: second word for unknown subcmd returns {}"] = function()
  local cmd = require("obsidian-tasks.cmd")
  local result = cmd._completion("foo", "ObsidianTask nosuchsubcmd foo", 29)
  MiniTest.expect.equality(#result, 0)
end

-- ── M.setup: command registration ────────────────────────────────────────────

T["setup: registers :ObsidianTask with nargs=* and range"] = function()
  local cmd = require("obsidian-tasks.cmd")
  -- Remove any prior registration to start fresh.
  pcall(vim.api.nvim_del_user_command, "ObsidianTask")

  cmd.setup()

  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(cmds["ObsidianTask"] ~= nil, true)
  MiniTest.expect.equality(cmds["ObsidianTask"].nargs, "*")
  -- range attribute present (non-nil / non-false)
  MiniTest.expect.equality(cmds["ObsidianTask"].range ~= nil, true)
end

T["setup: replaces pre-existing stub command"] = function()
  local cmd = require("obsidian-tasks.cmd")
  -- Install a stub with nargs="?" to simulate the F1 plugin/ stub.
  pcall(vim.api.nvim_del_user_command, "ObsidianTask")
  vim.api.nvim_create_user_command("ObsidianTask", function() end, { nargs = "?" })

  cmd.setup()

  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(cmds["ObsidianTask"] ~= nil, true)
  MiniTest.expect.equality(cmds["ObsidianTask"].nargs, "*")
end

T["setup: calling setup twice does not error"] = function()
  local cmd = require("obsidian-tasks.cmd")
  pcall(vim.api.nvim_del_user_command, "ObsidianTask")
  cmd.setup()
  -- Second call should replace the first without error.
  cmd.setup()
  local cmds = vim.api.nvim_get_commands({})
  MiniTest.expect.equality(cmds["ObsidianTask"] ~= nil, true)
end

-- ── M.setup: end-to-end via vim.cmd ──────────────────────────────────────────

T["setup: vim.cmd ObsidianTask toggle cycles source buffer task"] = function()
  local cmd = require("obsidian-tasks.cmd")
  cmd.setup()

  local bufnr = make_buf({ "- [ ] End-to-end task" })

  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  local draw_cleanup = install_mock("obsidian-tasks.render.draw", {
    is_render_line = function()
      return nil
    end,
  })

  -- Execute via the registered command; default range = current line = 1.
  vim.cmd("1ObsidianTask toggle")

  vim.api.nvim_get_current_buf = orig_gcb
  draw_cleanup()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  MiniTest.expect.equality(lines[1], "- [x] End-to-end task")
end

return T
