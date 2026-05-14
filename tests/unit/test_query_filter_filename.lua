-- tests/unit/test_query_filter_filename.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/FilenameField.test.ts

local T = require("unit.helpers.path_field").make_tests("filename", "/vault/projects/web-app.md", "web", "archive")

-- Field-specific: filename matches only the basename, not any parent dir.
local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function matches(line, t, p)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(t, p)
end

T["filename does NOT match parent directory name"] = function()
  -- The parent dir is "projects" — filename should not include it.
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("filename includes projects", t, "/vault/projects/web-app.md"), false)
end

return T
