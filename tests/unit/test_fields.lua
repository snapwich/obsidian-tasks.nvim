-- tests/unit/test_fields.lua
-- Unit tests for task/fields.lua

local T = MiniTest.new_set()
local fields = require("obsidian-tasks.task.fields")

-- ── M.fields list ─────────────────────────────────────────────────────────────

T["fields list: contains 11 entries"] = function()
  MiniTest.expect.equality(#fields.fields, 11)
end

T["fields list: every entry has required keys"] = function()
  for _, f in ipairs(fields.fields) do
    MiniTest.expect.equality(type(f.key), "string")
    MiniTest.expect.equality(type(f.emoji), "string")
    MiniTest.expect.equality(type(f.alternates), "table")
    MiniTest.expect.equality(type(f.dataview), "string")
    MiniTest.expect.equality(type(f.kind), "string")
  end
end

T["fields list: kind values are valid"] = function()
  local valid_kinds = { date = true, string = true, priority = true, ["tag-list"] = true }
  for _, f in ipairs(fields.fields) do
    MiniTest.expect.equality(valid_kinds[f.kind] ~= nil, true)
  end
end

-- ── field keys present ────────────────────────────────────────────────────────

local function find_field(key)
  for _, f in ipairs(fields.fields) do
    if f.key == key then
      return f
    end
  end
  return nil
end

T["fields list: all v1 keys present"] = function()
  local expected_keys = {
    "due",
    "scheduled",
    "start",
    "done",
    "cancelled",
    "created",
    "priority",
    "recurrence",
    "id",
    "depends_on",
    "on_completion",
  }
  for _, k in ipairs(expected_keys) do
    MiniTest.expect.equality(find_field(k) ~= nil, true)
  end
end

-- ── by_emoji lookups ──────────────────────────────────────────────────────────

T["by_emoji: primary emoji resolves to correct field"] = function()
  MiniTest.expect.equality(fields.by_emoji["📅"].key, "due")
  MiniTest.expect.equality(fields.by_emoji["⏳"].key, "scheduled")
  MiniTest.expect.equality(fields.by_emoji["🛫"].key, "start")
  MiniTest.expect.equality(fields.by_emoji["✅"].key, "done")
  MiniTest.expect.equality(fields.by_emoji["❌"].key, "cancelled")
  MiniTest.expect.equality(fields.by_emoji["➕"].key, "created")
  MiniTest.expect.equality(fields.by_emoji["⏫"].key, "priority")
  MiniTest.expect.equality(fields.by_emoji["🔁"].key, "recurrence")
  MiniTest.expect.equality(fields.by_emoji["🆔"].key, "id")
  MiniTest.expect.equality(fields.by_emoji["⛔"].key, "depends_on")
  MiniTest.expect.equality(fields.by_emoji["🏁"].key, "on_completion")
end

T["by_emoji: alternate due emoji map to 'due'"] = function()
  MiniTest.expect.equality(fields.by_emoji["📆"].key, "due")
  MiniTest.expect.equality(fields.by_emoji["🗓"].key, "due")
end

T["by_emoji: alternate scheduled emoji maps to 'scheduled'"] = function()
  MiniTest.expect.equality(fields.by_emoji["⌛"].key, "scheduled")
end

T["by_emoji: priority alternates all map to 'priority'"] = function()
  -- 🔺 high, 🔼 medium, 🔽 low, ⏬ lowest are alternates of the priority field
  MiniTest.expect.equality(fields.by_emoji["🔺"].key, "priority")
  MiniTest.expect.equality(fields.by_emoji["🔼"].key, "priority")
  MiniTest.expect.equality(fields.by_emoji["🔽"].key, "priority")
  MiniTest.expect.equality(fields.by_emoji["⏬"].key, "priority")
end

T["by_emoji: 🏁 maps to on_completion, not cancelled"] = function()
  MiniTest.expect.equality(fields.by_emoji["🏁"].key, "on_completion")
end

T["by_emoji: ❌ maps to cancelled date, not on_completion"] = function()
  MiniTest.expect.equality(fields.by_emoji["❌"].key, "cancelled")
end

-- ── by_dataview lookups ───────────────────────────────────────────────────────

T["by_dataview: all dataview keys resolve correctly"] = function()
  MiniTest.expect.equality(fields.by_dataview["due"].key, "due")
  MiniTest.expect.equality(fields.by_dataview["scheduled"].key, "scheduled")
  MiniTest.expect.equality(fields.by_dataview["start"].key, "start")
  MiniTest.expect.equality(fields.by_dataview["completion"].key, "done")
  MiniTest.expect.equality(fields.by_dataview["cancelled"].key, "cancelled")
  MiniTest.expect.equality(fields.by_dataview["created"].key, "created")
  MiniTest.expect.equality(fields.by_dataview["priority"].key, "priority")
  MiniTest.expect.equality(fields.by_dataview["repeat"].key, "recurrence")
  MiniTest.expect.equality(fields.by_dataview["id"].key, "id")
  MiniTest.expect.equality(fields.by_dataview["dependsOn"].key, "depends_on")
  MiniTest.expect.equality(fields.by_dataview["onCompletion"].key, "on_completion")
end

-- ── priority_levels ───────────────────────────────────────────────────────────

T["priority_levels: correct emoji for each level"] = function()
  MiniTest.expect.equality(fields.priority_levels.highest, "🔺")
  MiniTest.expect.equality(fields.priority_levels.high, "⏫")
  MiniTest.expect.equality(fields.priority_levels.medium, "🔼")
  MiniTest.expect.equality(fields.priority_levels.low, "🔽")
  MiniTest.expect.equality(fields.priority_levels.lowest, "⏬")
end

T["priority_levels: exactly 5 levels"] = function()
  local count = 0
  for _ in pairs(fields.priority_levels) do
    count = count + 1
  end
  MiniTest.expect.equality(count, 5)
end

-- ── priority_by_emoji ─────────────────────────────────────────────────────────

T["priority_by_emoji: emoji → level name round-trips"] = function()
  MiniTest.expect.equality(fields.priority_by_emoji["🔺"], "highest")
  MiniTest.expect.equality(fields.priority_by_emoji["⏫"], "high")
  MiniTest.expect.equality(fields.priority_by_emoji["🔼"], "medium")
  MiniTest.expect.equality(fields.priority_by_emoji["🔽"], "low")
  MiniTest.expect.equality(fields.priority_by_emoji["⏬"], "lowest")
end

T["priority_by_emoji: all priority_levels emoji have reverse mapping"] = function()
  for level, emoji in pairs(fields.priority_levels) do
    MiniTest.expect.equality(fields.priority_by_emoji[emoji], level)
  end
end

return T
