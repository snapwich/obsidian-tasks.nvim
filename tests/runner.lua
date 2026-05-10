-- tests/runner.lua
-- mini.test entrypoint. Discovers and runs all unit tests.
-- Sourced by tests/minit.lua.

require("mini.test").setup()

MiniTest.run({
  collect = {
    find_files = function()
      return vim.fn.globpath("tests/unit", "test_*.lua", true, true)
    end,
  },
  execute = {
    reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
  },
})
