-- tests/integration_real/test_frontmatter_ignore.lua
-- Verifies our index/ignore.is_ignored detection against the *real*
-- obsidian.frontmatter.parse. The unit suite uses a hand-rolled YAML scanner
-- in test_index.lua; this confirms the contract still holds against upstream.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

T["ignored_note.md (nested tasks-plugin.ignore: true) is detected"] = function()
  local ignore = require("obsidian-tasks.index.ignore")
  local path = fixture_vault .. "/ignored_note.md"
  eq(ignore.is_ignored(path), true)
end

T["edge/ignored-2.md (second nested-form ignored note) is detected"] = function()
  -- Confirms a *second* ignored file is also excluded — one ignore doesn't
  -- mask another. (The flat-key form `tasks-plugin.ignore: true` is NOT
  -- supported: obsidian.nvim's YAML parser collapses dotted keys.)
  local ignore = require("obsidian-tasks.index.ignore")
  local path = fixture_vault .. "/edge/ignored-2.md"
  eq(ignore.is_ignored(path), true)
end

T["work/sprint.md (no frontmatter) is NOT ignored"] = function()
  local ignore = require("obsidian-tasks.index.ignore")
  local path = fixture_vault .. "/work/sprint.md"
  eq(ignore.is_ignored(path), false)
end

T["edge/frontmatter-tagged.md (frontmatter without tasks-plugin key) is NOT ignored"] = function()
  local ignore = require("obsidian-tasks.index.ignore")
  local path = fixture_vault .. "/edge/frontmatter-tagged.md"
  eq(ignore.is_ignored(path), false)
end

return T
