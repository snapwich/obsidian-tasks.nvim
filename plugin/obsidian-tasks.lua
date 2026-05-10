-- plugin/obsidian-tasks.lua
-- Plugin entry point. Defines the :ObsidianTask ex-command stub.
-- Full dispatcher wired in F5 T1.

if vim.g.loaded_obsidian_tasks then
  return
end
vim.g.loaded_obsidian_tasks = true

vim.api.nvim_create_user_command("ObsidianTask", function(_)
  vim.notify("obsidian-tasks: dispatcher not yet wired (F5)", vim.log.levels.INFO)
end, {
  nargs = "*",
  range = true,
  desc = "ObsidianTask subcommands (not yet wired — see F5)",
})
