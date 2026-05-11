-- tests/runner_integration.lua
-- mini.test entrypoint for the "real-plugin" integration suite. Sourced by
-- tests/minit_integration.lua *after* obsidian.nvim and obsidian-tasks have
-- both been required and set up.

require("mini.test").setup()

MiniTest.run({
  collect = {
    find_files = function()
      return vim.fn.globpath("tests/integration_real", "test_*.lua", true, true)
    end,
  },
  execute = {
    reporter = MiniTest.gen_reporter.stdout({ group_depth = 2 }),
  },
})
