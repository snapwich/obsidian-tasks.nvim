-- tests/unit/test_query_filter_priority.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/PriorityField.test.ts
--
-- Priority levels (high → low):
--   highest 🔺  →  high ⏫  →  medium 🔼  →  none (no emoji)  →  low 🔽  →  lowest ⏬
-- Operators: `priority is X`, `priority above X`, `priority below X`,
--            `priority not is X` (where X is one of the level names).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(filter_line, task)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

-- ── priority is <level> ───────────────────────────────────────────────────

T["priority is highest: matches 🔺"] = function()
  eq(matches("priority is highest", pt("- [ ] Task 🔺")), true)
end

T["priority is high: matches ⏫"] = function()
  eq(matches("priority is high", pt("- [ ] Task ⏫")), true)
end

T["priority is medium: matches 🔼"] = function()
  eq(matches("priority is medium", pt("- [ ] Task 🔼")), true)
end

T["priority is low: matches 🔽"] = function()
  eq(matches("priority is low", pt("- [ ] Task 🔽")), true)
end

T["priority is lowest: matches ⏬"] = function()
  eq(matches("priority is lowest", pt("- [ ] Task ⏬")), true)
end

T["priority is none: matches no-emoji task"] = function()
  eq(matches("priority is none", pt("- [ ] Plain task")), true)
end

T["priority is none: false when any priority is set"] = function()
  eq(matches("priority is none", pt("- [ ] Task ⏫")), false)
end

T["priority is high: false for medium task"] = function()
  eq(matches("priority is high", pt("- [ ] Task 🔼")), false)
end

-- ── priority above / below <level> (strict comparison) ────────────────────

T["priority above medium: matches highest"] = function()
  eq(matches("priority above medium", pt("- [ ] Task 🔺")), true)
end

T["priority above medium: matches high"] = function()
  eq(matches("priority above medium", pt("- [ ] Task ⏫")), true)
end

T["priority above medium: false for medium (strict)"] = function()
  eq(matches("priority above medium", pt("- [ ] Task 🔼")), false)
end

T["priority above medium: false for low"] = function()
  eq(matches("priority above medium", pt("- [ ] Task 🔽")), false)
end

T["priority below medium: matches low"] = function()
  eq(matches("priority below medium", pt("- [ ] Task 🔽")), true)
end

T["priority below medium: matches lowest"] = function()
  eq(matches("priority below medium", pt("- [ ] Task ⏬")), true)
end

T["priority below medium: false for medium (strict)"] = function()
  eq(matches("priority below medium", pt("- [ ] Task 🔼")), false)
end

T["priority below medium: false for high"] = function()
  eq(matches("priority below medium", pt("- [ ] Task ⏫")), false)
end

-- ── priority not is <level> ───────────────────────────────────────────────

T["priority not is low: matches high"] = function()
  eq(matches("priority not is low", pt("- [ ] Task ⏫")), true)
end

T["priority not is low: matches none"] = function()
  eq(matches("priority not is low", pt("- [ ] Plain task")), true)
end

T["priority not is low: false for low"] = function()
  eq(matches("priority not is low", pt("- [ ] Task 🔽")), false)
end

-- ── 'none' placement in the priority ordering ─────────────────────────────

T["priority above none: matches all explicitly-set priorities"] = function()
  -- 'none' sits between medium and low in upstream's ordering.  Tasks with
  -- a higher priority than none (highest/high/medium) pass; tasks with low/
  -- lowest fail.
  eq(matches("priority above none", pt("- [ ] Task 🔺")), true)
  eq(matches("priority above none", pt("- [ ] Task ⏫")), true)
  eq(matches("priority above none", pt("- [ ] Task 🔼")), true)
  eq(matches("priority above none", pt("- [ ] Task 🔽")), false)
end

T["priority below none: matches low and lowest"] = function()
  eq(matches("priority below none", pt("- [ ] Task 🔽")), true)
  eq(matches("priority below none", pt("- [ ] Task ⏬")), true)
  eq(matches("priority below none", pt("- [ ] Task 🔼")), false)
end

return T
