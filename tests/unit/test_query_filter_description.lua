-- tests/unit/test_query_filter_description.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/DescriptionField.test.ts
--
-- `description includes <value>` matches the task's description (the text
-- portion before any field emojis).  Substring match, case-insensitive.

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
  return pred(task, path or "/vault/note.md")
end

T["description includes: matches substring"] = function()
  eq(matches("description includes milk", pt("- [ ] Buy milk and eggs")), true)
end

T["description includes: case-insensitive"] = function()
  eq(matches("description includes milk", pt("- [ ] Buy MILK today")), true)
  eq(matches("description includes MILK", pt("- [ ] buy milk")), true)
end

T["description includes: false when absent"] = function()
  eq(matches("description includes bread", pt("- [ ] Buy milk")), false)
end

T["description does not include: inverse"] = function()
  eq(matches("description does not include bread", pt("- [ ] Buy milk")), true)
  eq(matches("description does not include milk", pt("- [ ] Buy milk")), false)
end

T["description includes preserves multi-word phrase"] = function()
  eq(matches("description includes buy milk", pt("- [ ] Buy milk today")), true)
  eq(matches("description includes buy bread", pt("- [ ] Buy milk")), false)
end

-- ── regex operators ──────────────────────────────────────────────────────

T["description regex matches: simple pattern"] = function()
  eq(matches("description regex matches /^Buy/", pt("- [ ] Buy milk")), true)
end

T["description regex matches: anchored pattern fails when not anchored"] = function()
  -- Currently we use Lua pattern matching where /^Buy/ tests start-of-string.
  eq(matches("description regex matches /^milk/", pt("- [ ] Buy milk")), false)
end

T["description regex does not match: inverse"] = function()
  eq(matches("description regex does not match /^XYZ/", pt("- [ ] Buy milk")), true)
end

return T
