-- tests/integration_real/test_workspace_membership.lua
-- Verifies util/obsidian.workspace_for_path against the *real* obsidian.api,
-- not a stub. Confirms our adapter's expected shape still matches upstream.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

T["workspace_for_path: in-vault path returns the test workspace"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local path = fixture_vault .. "/work/sprint.md"
  local ws = adapter.workspace_for_path(path)
  eq(type(ws), "table")
  -- Path is wrapped in obsidian.path.Path; tostring works on both string + Path.
  local root_str = tostring(ws.root)
  eq(root_str:find(fixture_vault, 1, true) ~= nil, true)
end

T["workspace_for_path: out-of-vault path returns nil"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local ws = adapter.workspace_for_path("/tmp/definitely-not-in-the-vault.md")
  eq(ws, nil)
end

return T
