-- tests/runner.lua
-- mini.test entrypoint. Discovers and runs all unit tests.
-- Sourced by tests/minit.lua.

require("mini.test").setup()

MiniTest.run({
  collect = {
    find_files = function()
      local unit = vim.fn.globpath("tests/unit", "test_*.lua", true, true)
      local integration = vim.fn.globpath("tests/integration", "test_*.lua", true, true)
      local all = {}
      for _, f in ipairs(unit) do
        all[#all + 1] = f
      end
      for _, f in ipairs(integration) do
        all[#all + 1] = f
      end
      return all
    end,
  },
  execute = {
    reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
  },
})
