-- tests/unit/test_log.lua
-- Unit tests for log.lua: prefix, level gating.

local T = MiniTest.new_set()

T["log functions exist"] = function()
  local log = require("obsidian-tasks.log")
  MiniTest.expect.equality(type(log.debug), "function")
  MiniTest.expect.equality(type(log.info), "function")
  MiniTest.expect.equality(type(log.warn), "function")
  MiniTest.expect.equality(type(log.error), "function")
end

T["log.info emits via vim.notify with prefix"] = function()
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(captured, { msg = msg, level = level })
  end

  local log = require("obsidian-tasks.log")
  log.info("hello info")

  vim.notify = orig

  MiniTest.expect.equality(#captured, 1)
  MiniTest.expect.equality(captured[1].msg:find("%[obsidian%-tasks%]") ~= nil, true)
  MiniTest.expect.equality(captured[1].msg:find("hello info") ~= nil, true)
  MiniTest.expect.equality(captured[1].level, vim.log.levels.INFO)
end

T["log.warn emits via vim.notify with WARN level"] = function()
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(captured, { msg = msg, level = level })
  end

  local log = require("obsidian-tasks.log")
  log.warn("something fishy")

  vim.notify = orig

  MiniTest.expect.equality(#captured, 1)
  MiniTest.expect.equality(captured[1].level, vim.log.levels.WARN)
end

T["log.error emits via vim.notify with ERROR level"] = function()
  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(captured, { msg = msg, level = level })
  end

  local log = require("obsidian-tasks.log")
  log.error("broke")

  vim.notify = orig

  MiniTest.expect.equality(#captured, 1)
  MiniTest.expect.equality(captured[1].level, vim.log.levels.ERROR)
end

T["log.debug suppressed when log_level is 'info'"] = function()
  -- Ensure plugin opts are set to info level
  local plugin = require("obsidian-tasks")
  plugin.setup({ log_level = "info" })

  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(captured, { msg = msg, level = level })
  end

  local log = require("obsidian-tasks.log")
  log.debug("should not appear")

  vim.notify = orig

  MiniTest.expect.equality(#captured, 0)
end

T["log.debug emitted when log_level is 'debug'"] = function()
  local plugin = require("obsidian-tasks")
  plugin.setup({ log_level = "debug" })

  local captured = {}
  local orig = vim.notify
  vim.notify = function(msg, level)
    table.insert(captured, { msg = msg, level = level })
  end

  local log = require("obsidian-tasks.log")
  log.debug("should appear")

  vim.notify = orig

  -- Reset to info so other tests aren't affected
  plugin.setup({ log_level = "info" })

  MiniTest.expect.equality(#captured, 1)
  MiniTest.expect.equality(captured[1].level, vim.log.levels.DEBUG)
  MiniTest.expect.equality(captured[1].msg:find("should appear") ~= nil, true)
end

return T
