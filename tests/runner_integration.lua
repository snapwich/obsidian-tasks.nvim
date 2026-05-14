-- tests/runner_integration.lua
-- mini.test entrypoint for the "real-plugin" integration suite. Sourced by
-- tests/minit_integration.lua *after* obsidian.nvim and obsidian-tasks have
-- both been required and set up.

-- Same path setup as runner.lua so tests can require shared helpers.
local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

require("mini.test").setup()

MiniTest.run({
  collect = {
    find_files = function()
      local files = vim.fn.globpath("tests/integration_real", "**/test_*.lua", true, true)
      for _, f in ipairs(vim.fn.globpath("tests/integration_real", "test_*.lua", true, true)) do
        files[#files + 1] = f
      end
      local out, seen = {}, {}
      for _, f in ipairs(files) do
        if not seen[f] then
          seen[f] = true
          out[#out + 1] = f
        end
      end
      return out
    end,
  },
  execute = {
    reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
  },
})
