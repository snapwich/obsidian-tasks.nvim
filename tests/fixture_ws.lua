-- tests/fixture_ws.lua
-- Native fixture-vault workspace for the integration suite (no obsidian.nvim).
return function()
  local vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")
  return require("obsidian-tasks.util.obsidian").workspace_for_path(vault .. "/tasks_a.md")
end
