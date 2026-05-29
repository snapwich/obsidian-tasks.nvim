-- tests/integration_real/test_setup_smoke.lua
-- Smoke test: obsidian-tasks loaded for real WITHOUT obsidian.nvim present.
-- setup() must populate M.opts and the native util/obsidian adapter must detect
-- the fixture vault from its `.obsidian/` marker alone.
--
-- The obsidian.nvim-integration smoke (the `Obsidian` global / workspace) lives
-- in tests/integration_obsidian/test_obsidian_smoke.lua.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

T["obsidian-tasks setup ran (M.opts populated)"] = function()
  local ot = require("obsidian-tasks")
  eq(type(ot.opts), "table")
  eq(ot.opts.global_filter, "#task")
end

T["util/obsidian.workspace_for_path detects the fixture vault natively"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local ws = adapter.workspace_for_path(fixture_vault .. "/tasks_a.md")
  eq(type(ws), "table")
  eq(tostring(ws.root):find(fixture_vault, 1, true) ~= nil, true)
end

return T
