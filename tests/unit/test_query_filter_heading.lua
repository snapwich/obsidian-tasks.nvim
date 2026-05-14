-- tests/unit/test_query_filter_heading.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/HeadingField.test.ts
--
-- `heading includes <value>` matches the nearest preceding markdown heading
-- of the task's source line.  In v1 we don't track the surrounding heading
-- context on parsed Task objects; this filter operates on an empty string,
-- so it consistently fails for any non-empty value.
--
-- KNOWN GAP vs upstream: heading-context tracking is not implemented in v1.
-- These tests document the current "filter never matches" behavior.  When
-- heading context is added, expand these to upstream-equivalent cases.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function matches(line, t, p)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(t, p)
end

T["heading includes <value>: no-heading-context — false for any value (v1 limitation)"] = function()
  -- Document the current v1 behavior: without heading tracking, the heading
  -- is the empty string, so `includes <non-empty>` is always false.
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("heading includes Section", t, "/vault/note.md"), false)
end

T["heading does not include <value>: trivially true under v1 (no heading tracked)"] = function()
  local t = assert(parse_task.parse("- [ ] Task"))
  eq(matches("heading does not include Section", t, "/vault/note.md"), true)
end

return T
