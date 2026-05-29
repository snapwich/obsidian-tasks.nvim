-- tests/runner_standalone.lua
-- mini.test entrypoint for the standalone (zero-obsidian) suite. Sourced by
-- tests/minit_standalone.lua after obsidian-tasks has been set up without
-- obsidian.nvim on the runtimepath.

local cwd = vim.fn.getcwd()
package.path = cwd .. "/tests/?.lua;" .. cwd .. "/tests/?/init.lua;" .. package.path

require("mini.test").setup()

MiniTest.run({
  collect = {
    find_files = function()
      local files = vim.fn.globpath("tests/integration_standalone", "**/test_*.lua", true, true)
      for _, f in ipairs(vim.fn.globpath("tests/integration_standalone", "test_*.lua", true, true)) do
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
