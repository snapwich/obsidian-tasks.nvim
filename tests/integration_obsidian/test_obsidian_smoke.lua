-- tests/integration_obsidian/test_obsidian_smoke.lua
-- Smoke test for the optional obsidian.nvim integration: obsidian.nvim is loaded
-- for real, so the `Obsidian` global must be set and its active workspace must
-- point at our fixture vault. (Moved out of integration_real/test_setup_smoke.lua
-- when that suite stopped loading obsidian.nvim.)

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

return T
