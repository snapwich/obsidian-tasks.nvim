-- tests/unit/test_query_filter_path.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/PathField.test.ts
--
-- `path includes <value>` matches the full absolute path of the task's file.
-- See tests/unit/helpers/path_field.lua for the shared operator matrix.

local T =
  require("unit.helpers.path_field").make_tests("path", "/home/user/vault/projects/web.md", "projects", "archive")

-- Field-specific: path matches against the FULL absolute path, not just the
-- filename or any single component.
local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function matches(line, t, p)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(t, p)
end

T["path includes matches deep-nested directory portion"] = function()
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("path includes user/vault/projects", t, "/home/user/vault/projects/web.md"), true)
end

T["path includes matches a single filename character"] = function()
  -- Substring semantics: any contiguous substring of the path matches.
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("path includes web.md", t, "/home/user/vault/projects/web.md"), true)
end

return T
