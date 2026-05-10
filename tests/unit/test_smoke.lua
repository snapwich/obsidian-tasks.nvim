-- tests/unit/test_smoke.lua
-- Sanity checks that the plugin loads and setup() is callable.

local T = MiniTest.new_set()

T["require obsidian-tasks succeeds"] = function()
  local ok, mod = pcall(require, "obsidian-tasks")
  MiniTest.expect.equality(ok, true)
  MiniTest.expect.equality(type(mod), "table")
end

T["setup({}) is callable without error"] = function()
  local mod = require("obsidian-tasks")
  MiniTest.expect.no_error(function()
    mod.setup({})
  end)
end

T["opts table exposed after setup"] = function()
  local mod = require("obsidian-tasks")
  mod.setup({})
  MiniTest.expect.equality(type(mod.opts), "table")
end

return T
