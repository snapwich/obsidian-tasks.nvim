-- tests/unit/test_query_filter_folder.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/FolderField.test.ts

local T = require("unit.helpers.path_field").make_tests("folder", "/vault/projects/web.md", "projects", "archive")

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function matches(line, t, p)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(t, p)
end

T["folder does NOT match the filename portion"] = function()
  -- folder = directory part only; "web.md" basename is excluded.
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("folder includes web.md", t, "/vault/projects/web.md"), false)
end

T["folder matches the whole directory path"] = function()
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("folder includes /vault/projects", t, "/vault/projects/web.md"), true)
end

return T
