-- tests/runner.lua
-- mini.test entrypoint. Discovers and runs all unit tests.
-- Sourced by tests/minit.lua.

-- Make test-local helpers loadable via require("unit.helpers.foo") etc.
-- without leaking test code into the runtime path.
local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

require("mini.test").setup()

MiniTest.run({
  collect = {
    find_files = function()
      -- Recursive ** so per-field test files can live under tests/unit/<subdir>/
      -- (e.g. tests/unit/query/filter/test_due_date.lua) when we eventually
      -- migrate to a directory layout that mirrors upstream's tests/Query/Filter/.
      local unit = vim.fn.globpath("tests/unit", "**/test_*.lua", true, true)
      for _, f in ipairs(vim.fn.globpath("tests/unit", "test_*.lua", true, true)) do
        unit[#unit + 1] = f
      end
      local integration = vim.fn.globpath("tests/integration", "**/test_*.lua", true, true)
      for _, f in ipairs(vim.fn.globpath("tests/integration", "test_*.lua", true, true)) do
        integration[#integration + 1] = f
      end
      local all = {}
      local seen = {}
      for _, f in ipairs(unit) do
        if not seen[f] then
          seen[f] = true
          all[#all + 1] = f
        end
      end
      for _, f in ipairs(integration) do
        if not seen[f] then
          seen[f] = true
          all[#all + 1] = f
        end
      end
      return all
    end,
  },
  execute = {
    reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
  },
})
