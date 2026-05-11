-- tests/integration_real/test_setup_smoke.lua
-- Smoke test: both obsidian.nvim and obsidian-tasks loaded for real;
-- the workspace points at our fixture vault; util/obsidian adapter works.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

T["Obsidian global is set"] = function()
  eq(type(_G.Obsidian), "table")
end

T["Obsidian.workspace points at fixture vault"] = function()
  eq(type(Obsidian.workspace), "table")
  eq(type(Obsidian.workspace.root), "table") -- obsidian.nvim wraps root in a Path object
  -- Path objects stringify via tostring(); accept either string or Path.
  local root_str = tostring(Obsidian.workspace.root)
  eq(root_str:find(fixture_vault, 1, true) ~= nil, true)
end

T["obsidian-tasks setup ran (M.opts populated)"] = function()
  local ot = require("obsidian-tasks")
  eq(type(ot.opts), "table")
  eq(ot.opts.global_filter, "#task")
end

T["util/obsidian.current_workspace returns the test vault"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local ws = adapter.current_workspace()
  eq(type(ws), "table")
end

return T
