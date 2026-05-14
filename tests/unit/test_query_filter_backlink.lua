-- tests/unit/test_query_filter_backlink.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/BacklinkField.test.ts
--
-- `backlink` is the filename without extension — what appears inside the
-- [[wikilink]] suffix on a rendered task row.

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

T["backlink includes: matches the filename stem"] = function()
  eq(matches("backlink includes my-note", pt("- [ ] Task"), "/vault/my-note.md"), true)
end

T["backlink does NOT include the .md extension"] = function()
  eq(matches("backlink includes .md", pt("- [ ] Task"), "/vault/note.md"), false)
end

T["backlink: substring match works"] = function()
  eq(matches("backlink includes note", pt("- [ ] Task"), "/vault/my-note.md"), true)
end

T["backlink does not include: inverse"] = function()
  eq(matches("backlink does not include archive", pt("- [ ] Task"), "/vault/note.md"), true)
  eq(matches("backlink does not include note", pt("- [ ] Task"), "/vault/note.md"), false)
end

return T
