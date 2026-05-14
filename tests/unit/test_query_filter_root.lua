-- tests/unit/test_query_filter_root.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/RootField.test.ts
--
-- `root` is the first directory below the vault root.  Differs from `folder`
-- (which is the full directory path) and from `filename` (just the basename).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(line, task, path)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, path)
end

T["root includes: matches first directory below vault root"] = function()
  eq(matches("root includes projects", pt("- [ ] Task"), "/vault/projects/web.md"), true)
end

T["root includes: false for non-first-level directory"] = function()
  -- "web" appears in the path but is below "projects" — root only gives the
  -- first subdirectory.
  eq(matches("root includes web", pt("- [ ] Task"), "/vault/projects/web.md"), false)
end

T["root: empty when file is directly under vault root"] = function()
  -- /vault/note.md → root = "" → won't match "anything".
  eq(matches("root includes anything", pt("- [ ] Task"), "/vault/note.md"), false)
end

T["root includes works with multiple matching levels: matches the deepest correct level"] = function()
  -- /vault/a/b/c/note.md → root = "a".
  eq(matches("root includes a", pt("- [ ] Task"), "/vault/a/b/c/note.md"), true)
  eq(matches("root includes b", pt("- [ ] Task"), "/vault/a/b/c/note.md"), false)
end

return T
