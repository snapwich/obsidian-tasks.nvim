-- tests/unit/test_recurrence.lua
-- Unit tests for task/recurrence.lua

local T = MiniTest.new_set()
local recurrence = require("obsidian-tasks.task.recurrence")
local parse = require("obsidian-tasks.task.parse")
local serialize = require("obsidian-tasks.task.serialize")

-- ── M.preserve ────────────────────────────────────────────────────────────────

T["preserve: returns raw string verbatim"] = function()
  MiniTest.expect.equality(recurrence.preserve("every week"), "every week")
end

T["preserve: multi-word string round-trips unchanged"] = function()
  MiniTest.expect.equality(recurrence.preserve("every month on the 1st"), "every month on the 1st")
end

T["preserve: empty string round-trips unchanged"] = function()
  MiniTest.expect.equality(recurrence.preserve(""), "")
end

-- ── M.next_occurrence ─────────────────────────────────────────────────────────

T["next_occurrence: raises v2 not-implemented error"] = function()
  local ok, err = pcall(recurrence.next_occurrence, {}, nil)
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(type(err), "string")
  -- Error message must contain version info
  MiniTest.expect.equality(err:find("v2") ~= nil, true)
  MiniTest.expect.equality(err:find("not implemented in v1") ~= nil, true)
end

T["next_occurrence: error message mentions obsidian-tasks"] = function()
  local ok, err = pcall(recurrence.next_occurrence, {}, "2024-01-01")
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err:find("obsidian%-tasks") ~= nil, true)
end

-- ── round-trip: 🔁 stored as opaque string ────────────────────────────────────

T["round-trip: parse then serialize preserves 🔁 field verbatim"] = function()
  local line = "- [ ] task 🔁 every week"
  local task = parse.parse(line)
  MiniTest.expect.equality(task ~= nil, true)
  MiniTest.expect.equality(task.fields.recurrence, "every week")
  local result = serialize.serialize(task)
  MiniTest.expect.equality(result, line)
end

T["round-trip: multi-word recurrence preserved"] = function()
  local line = "- [ ] task 🔁 every month on the 1st"
  local task = parse.parse(line)
  MiniTest.expect.equality(task ~= nil, true)
  MiniTest.expect.equality(task.fields.recurrence, "every month on the 1st")
  local result = serialize.serialize(task)
  MiniTest.expect.equality(result, line)
end

return T
