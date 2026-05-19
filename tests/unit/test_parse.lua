-- tests/unit/test_parse.lua
-- Unit tests for task/parse.lua

local T = MiniTest.new_set()
local parse = require("obsidian-tasks.task.parse")

-- ── helpers ────────────────────────────────────────────────────────────────

--- Assert equality with a descriptive label (uses MiniTest.expect.equality).
local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

-- ── non-task lines return nil ──────────────────────────────────────────────

T["nil: plain text"] = function()
  eq(parse.parse("not a task"), nil)
end

T["nil: empty string"] = function()
  eq(parse.parse(""), nil)
end

T["nil: heading"] = function()
  eq(parse.parse("## My Heading"), nil)
end

T["nil: list item without checkbox"] = function()
  eq(parse.parse("- plain list item"), nil)
end

T["nil: code fence"] = function()
  eq(parse.parse("```lua"), nil)
end

-- ── prefix detection ──────────────────────────────────────────────────────

T["prefix: space status symbol (todo)"] = function()
  local t = parse.parse("- [ ] My task")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.status_symbol, " ")
  eq(t.marker, "-")
  eq(t.indent, "")
  eq(t.description, "My task")
end

T["prefix: x status symbol (done)"] = function()
  local t = parse.parse("- [x] Done task")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.status_symbol, "x")
end

T["prefix: all list markers accepted"] = function()
  local function get_marker(line)
    return parse.parse(line).marker
  end
  eq(get_marker("- [ ] dash"), "-")
  eq(get_marker("* [ ] star"), "*")
  eq(get_marker("+ [ ] plus"), "+")
end

T["prefix: indented sub-task"] = function()
  local t = parse.parse("  - [ ] sub task")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.indent, "  ")
  eq(t.marker, "-")
  eq(t.description, "sub task")
end

T["prefix: deeply indented"] = function()
  local t = parse.parse("    * [/] deep")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.indent, "    ")
  eq(t.status_symbol, "/")
end

T["prefix: raw_line preserved"] = function()
  local line = "- [x] Some task 📅 2024-01-15"
  local t = parse.parse(line)
  eq(t.raw_line, line)
end

-- ── pure emoji format ──────────────────────────────────────────────────────

T["emoji: due date"] = function()
  local t = parse.parse("- [ ] Buy milk 📅 2024-01-15")
  eq(t.fields.due, "2024-01-15")
  eq(t._origin.due, "emoji")
end

T["emoji: scheduled date"] = function()
  local t = parse.parse("- [ ] Task ⏳ 2024-02-01")
  eq(t.fields.scheduled, "2024-02-01")
  eq(t._origin.scheduled, "emoji")
end

T["emoji: start date"] = function()
  local t = parse.parse("- [ ] Task 🛫 2024-03-10")
  eq(t.fields.start, "2024-03-10")
  eq(t._origin.start, "emoji")
end

T["emoji: done date"] = function()
  local t = parse.parse("- [x] Task ✅ 2024-04-20")
  eq(t.fields.done, "2024-04-20")
  eq(t._origin.done, "emoji")
end

T["emoji: cancelled date"] = function()
  local t = parse.parse("- [-] Task ❌ 2024-05-05")
  eq(t.fields.cancelled, "2024-05-05")
  eq(t._origin.cancelled, "emoji")
end

T["emoji: created date"] = function()
  local t = parse.parse("- [ ] Task ➕ 2024-06-01")
  eq(t.fields.created, "2024-06-01")
  eq(t._origin.created, "emoji")
end

T["emoji: recurrence as opaque string (single word)"] = function()
  local t = parse.parse("- [ ] Task 🔁 every day")
  eq(t.fields.recurrence, "every day")
  eq(t._origin.recurrence, "emoji")
end

T["emoji: recurrence multi-word preserved verbatim"] = function()
  local t = parse.parse("- [ ] Task 🔁 every week on Monday")
  eq(t.fields.recurrence, "every week on Monday")
end

T["emoji: id field"] = function()
  local t = parse.parse("- [ ] Task 🆔 abc-123")
  eq(t.fields.id, "abc-123")
  eq(t._origin.id, "emoji")
end

T["emoji: depends_on field"] = function()
  local t = parse.parse("- [ ] Task ⛔ xyz-456")
  eq(t.fields.depends_on, "xyz-456")
  eq(t._origin.depends_on, "emoji")
end

T["emoji: on_completion field"] = function()
  local t = parse.parse("- [ ] Task 🏁 delete")
  eq(t.fields.on_completion, "delete")
  eq(t._origin.on_completion, "emoji")
end

-- ── priority emoji variants ────────────────────────────────────────────────

T["priority: highest (🔺)"] = function()
  local t = parse.parse("- [ ] Task 🔺")
  eq(t.fields.priority, "highest")
  eq(t._origin.priority, "emoji")
end

T["priority: high (⏫)"] = function()
  local t = parse.parse("- [ ] Task ⏫")
  eq(t.fields.priority, "high")
  eq(t._origin.priority, "emoji")
end

T["priority: medium (🔼)"] = function()
  local t = parse.parse("- [ ] Task 🔼")
  eq(t.fields.priority, "medium")
  eq(t._origin.priority, "emoji")
end

T["priority: low (🔽)"] = function()
  local t = parse.parse("- [ ] Task 🔽")
  eq(t.fields.priority, "low")
  eq(t._origin.priority, "emoji")
end

T["priority: lowest (⏬)"] = function()
  local t = parse.parse("- [ ] Task ⏬")
  eq(t.fields.priority, "lowest")
  eq(t._origin.priority, "emoji")
end

T["priority: emoji before date fields"] = function()
  local t = parse.parse("- [ ] Task 🔺 📅 2024-01-01")
  eq(t.fields.priority, "highest")
  eq(t.fields.due, "2024-01-01")
end

-- ── multiple emoji fields on one line ─────────────────────────────────────

T["emoji: multiple fields on one line"] = function()
  local t = parse.parse("- [ ] My task 📅 2024-01-15 ⏳ 2024-01-10 🛫 2024-01-05")
  eq(t.description, "My task")
  eq(t.fields.due, "2024-01-15")
  eq(t.fields.scheduled, "2024-01-10")
  eq(t.fields.start, "2024-01-05")
end

T["emoji: full field set"] = function()
  local line =
    "- [x] Buy milk ➕ 2024-01-01 🛫 2024-01-10 ⏳ 2024-01-12 📅 2024-01-15 ✅ 2024-01-15 🔁 every week 🔺"
  local t = parse.parse(line)
  eq(t.description, "Buy milk")
  eq(t.fields.created, "2024-01-01")
  eq(t.fields.start, "2024-01-10")
  eq(t.fields.scheduled, "2024-01-12")
  eq(t.fields.due, "2024-01-15")
  eq(t.fields.done, "2024-01-15")
  eq(t.fields.recurrence, "every week")
  eq(t.fields.priority, "highest")
end

-- ── alternate emoji ────────────────────────────────────────────────────────

T["emoji alternate: 📆 maps to due"] = function()
  local t = parse.parse("- [ ] Task 📆 2024-01-01")
  eq(t.fields.due, "2024-01-01")
  eq(t._origin.due, "emoji")
end

T["emoji alternate: 🗓 maps to due"] = function()
  local t = parse.parse("- [ ] Task 🗓 2024-01-01")
  eq(t.fields.due, "2024-01-01")
end

T["emoji alternate: ⌛ maps to scheduled"] = function()
  local t = parse.parse("- [ ] Task ⌛ 2024-01-01")
  eq(t.fields.scheduled, "2024-01-01")
end

-- ── pure dataview format ──────────────────────────────────────────────────

T["dataview: due date"] = function()
  local t = parse.parse("- [ ] Buy milk [due:: 2024-01-15]")
  eq(t.fields.due, "2024-01-15")
  eq(t._origin.due, "dataview")
end

T["dataview: scheduled date"] = function()
  local t = parse.parse("- [ ] Task [scheduled:: 2024-02-01]")
  eq(t.fields.scheduled, "2024-02-01")
  eq(t._origin.scheduled, "dataview")
end

T["dataview: start date"] = function()
  local t = parse.parse("- [ ] Task [start:: 2024-03-10]")
  eq(t.fields.start, "2024-03-10")
end

T["dataview: completion field maps to done"] = function()
  local t = parse.parse("- [x] Task [completion:: 2024-04-20]")
  eq(t.fields.done, "2024-04-20")
  eq(t._origin.done, "dataview")
end

T["dataview: cancelled field"] = function()
  local t = parse.parse("- [-] Task [cancelled:: 2024-05-05]")
  eq(t.fields.cancelled, "2024-05-05")
end

T["dataview: created field"] = function()
  local t = parse.parse("- [ ] Task [created:: 2024-06-01]")
  eq(t.fields.created, "2024-06-01")
end

T["dataview: priority as level name"] = function()
  local t = parse.parse("- [ ] Task [priority:: high]")
  eq(t.fields.priority, "high")
  eq(t._origin.priority, "dataview")
end

T["dataview: recurrence as repeat key"] = function()
  local t = parse.parse("- [ ] Task [repeat:: every week]")
  eq(t.fields.recurrence, "every week")
  eq(t._origin.recurrence, "dataview")
end

T["dataview: id field"] = function()
  local t = parse.parse("- [ ] Task [id:: abc-123]")
  eq(t.fields.id, "abc-123")
  eq(t._origin.id, "dataview")
end

T["dataview: dependsOn field"] = function()
  local t = parse.parse("- [ ] Task [dependsOn:: xyz]")
  eq(t.fields.depends_on, "xyz")
  eq(t._origin.depends_on, "dataview")
end

T["dataview: onCompletion field"] = function()
  local t = parse.parse("- [ ] Task [onCompletion:: delete]")
  eq(t.fields.on_completion, "delete")
  eq(t._origin.on_completion, "dataview")
end

T["dataview: multiple fields"] = function()
  local t = parse.parse("- [ ] Task [due:: 2024-01-15] [scheduled:: 2024-01-10]")
  eq(t.fields.due, "2024-01-15")
  eq(t.fields.scheduled, "2024-01-10")
end

T["dataview: description before dataview fields"] = function()
  local t = parse.parse("- [ ] Buy groceries [due:: 2024-01-15]")
  eq(t.description, "Buy groceries")
end

-- ── unknown dataview keys ignored ─────────────────────────────────────────

T["dataview: unknown key does not error, not added to fields"] = function()
  local t = parse.parse("- [ ] Task [unknown:: value]")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.description, "Task [unknown:: value]")
end

-- ── mixed emoji + dataview ─────────────────────────────────────────────────

T["mixed: emoji due + dataview scheduled"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-15 [scheduled:: 2024-01-10]")
  eq(t.fields.due, "2024-01-15")
  eq(t.fields.scheduled, "2024-01-10")
  eq(t._origin.due, "emoji")
  eq(t._origin.scheduled, "dataview")
end

T["mixed: dataview before emoji"] = function()
  local t = parse.parse("- [ ] Task [due:: 2024-01-15] ⏳ 2024-01-10")
  eq(t.fields.due, "2024-01-15")
  eq(t.fields.scheduled, "2024-01-10")
  eq(t._origin.due, "dataview")
  eq(t._origin.scheduled, "emoji")
end

T["mixed: priority emoji + dataview date"] = function()
  local t = parse.parse("- [ ] Task 🔺 [due:: 2024-12-31]")
  eq(t.fields.priority, "highest")
  eq(t.fields.due, "2024-12-31")
end

-- ── missing fields ─────────────────────────────────────────────────────────

T["missing fields: all nil when no fields present"] = function()
  local t = parse.parse("- [ ] Just a task")
  eq(t.fields.due, nil)
  eq(t.fields.scheduled, nil)
  eq(t.fields.start, nil)
  eq(t.fields.done, nil)
  eq(t.fields.cancelled, nil)
  eq(t.fields.created, nil)
  eq(t.fields.priority, nil)
  eq(t.fields.recurrence, nil)
  eq(t.fields.id, nil)
  eq(t.fields.depends_on, nil)
  eq(t.fields.on_completion, nil)
end

T["missing fields: partial — only due set"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-01")
  eq(t.fields.due, "2024-01-01")
  eq(t.fields.scheduled, nil)
  eq(t.fields.priority, nil)
end

-- ── malformed / unusual dates: fields.due nil, raw preserved, error set ─────

T["malformed date: not-a-date string captured under _raw_fields/_errors"] = function()
  local t = parse.parse("- [ ] Task 📅 not-a-date")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "not-a-date")
  eq(type(t._errors.due), "string")
end

T["malformed date: partial date captured under _raw_fields/_errors"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-13")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "2024-13")
  eq(type(t._errors.due), "string")
end

T["malformed date: extra characters captured under _raw_fields/_errors"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-99-extra")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "2024-01-99-extra")
  eq(type(t._errors.due), "string")
end

T["malformed date: day 99 in well-shaped string rejected"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-99")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "2024-01-99")
end

T["valid date: ISO YYYY-MM-DD accepted unchanged"] = function()
  local t = parse.parse("- [ ] Task 📅 2025-12-01")
  eq(t.fields.due, "2025-12-01")
  eq(t._raw_fields.due, nil)
  eq(t._errors.due, nil)
end

-- ── tag extraction ─────────────────────────────────────────────────────────

T["tags: none present — empty list"] = function()
  local t = parse.parse("- [ ] Just a task")
  eq(#t.tags, 0)
end

T["tags: embedded mid-description kept in description text"] = function()
  local t = parse.parse("- [ ] My #project task")
  eq(t.description, "My #project task")
  eq(#t.tags, 1)
  eq(t.tags[1], "#project")
end

T["tags: multiple tags in description"] = function()
  local t = parse.parse("- [ ] My #work #project task")
  eq(t.description, "My #work #project task")
  eq(#t.tags, 2)
end

T["tags: trailing tag after emoji field stripped from value"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-01 #urgent")
  eq(t.fields.due, "2024-01-01")
  -- tag is in task.tags even though it trailed a field
  local found = false
  for _, tag in ipairs(t.tags) do
    if tag == "#urgent" then
      found = true
    end
  end
  MiniTest.expect.equality(found, true)
end

T["tags: trailing tag after last field not in description"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-01 #urgent")
  eq(t.description, "Task")
end

T["tags: tag between description and field stays in description"] = function()
  local t = parse.parse("- [ ] Do work #todo 📅 2024-01-01")
  eq(t.description, "Do work #todo")
  eq(#t.tags >= 1, true)
end

T["tags: tag with slash and hyphen"] = function()
  local t = parse.parse("- [ ] Task #project/sub-task")
  eq(t.tags[1], "#project/sub-task")
  eq(t.description, "Task #project/sub-task")
end

T["tags: tag with underscore"] = function()
  local t = parse.parse("- [ ] Task #my_tag")
  eq(t.tags[1], "#my_tag")
end

T["tags: wikilink heading anchor not collected as tag"] = function()
  local t = parse.parse("- [ ] Task [[note#some-heading|alias]] #real")
  eq(#t.tags, 1)
  eq(t.tags[1], "#real")
end

T["tags: from dataview line collected too"] = function()
  local t = parse.parse("- [ ] Task [due:: 2024-01-01] #someTag")
  local found = false
  for _, tag in ipairs(t.tags) do
    if tag == "#someTag" then
      found = true
    end
  end
  MiniTest.expect.equality(found, true)
end

-- ── description edge cases ─────────────────────────────────────────────────

T["description: empty body"] = function()
  local t = parse.parse("- [ ] ")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.description, "")
end

T["description: only fields, no text"] = function()
  local t = parse.parse("- [ ] 📅 2024-01-01")
  eq(t.description, "")
  eq(t.fields.due, "2024-01-01")
end

T["description: whitespace trimmed"] = function()
  local t = parse.parse("- [ ]   task with spaces   📅 2024-01-01")
  eq(t.description, "task with spaces")
end

-- ── unknown emoji in description ──────────────────────────────────────────

T["unknown emoji: left in description, no error"] = function()
  local t = parse.parse("- [ ] Task with 🎉 party emoji")
  MiniTest.expect.equality(t ~= nil, true)
  eq(t.description, "Task with 🎉 party emoji")
end

T["unknown emoji: does not pollute fields"] = function()
  local t = parse.parse("- [ ] Task 🎉 📅 2024-01-01")
  eq(t.fields.due, "2024-01-01")
end

-- ── recurrence stored verbatim ────────────────────────────────────────────

T["recurrence: simple interval"] = function()
  local t = parse.parse("- [ ] Task 🔁 every 2 weeks")
  eq(t.fields.recurrence, "every 2 weeks")
end

T["recurrence: complex expression"] = function()
  local t = parse.parse("- [ ] Task 🔁 every month on the 1st")
  eq(t.fields.recurrence, "every month on the 1st")
end

T["recurrence: dataview key is 'repeat'"] = function()
  local t = parse.parse("- [ ] Task [repeat:: every 3 days]")
  eq(t.fields.recurrence, "every 3 days")
  eq(t._origin.recurrence, "dataview")
end

-- ── status symbols ────────────────────────────────────────────────────────

T["status: various symbols captured"] = function()
  local cases = {
    { "- [ ] t", " " },
    { "- [x] t", "x" },
    { "- [/] t", "/" },
    { "- [-] t", "-" },
    { "- [h] t", "h" },
  }
  for _, c in ipairs(cases) do
    local t = parse.parse(c[1])
    MiniTest.expect.equality(t ~= nil, true)
    eq(t.status_symbol, c[2])
  end
end

-- ── _origin table ─────────────────────────────────────────────────────────

T["_origin: only set for fields present on line"] = function()
  local t = parse.parse("- [ ] Task 📅 2024-01-01")
  eq(t._origin.due, "emoji")
  eq(t._origin.scheduled, nil)
  eq(t._origin.priority, nil)
end

T["_origin: dataview overrides emoji for same field (last-write wins)"] = function()
  -- When the same field appears twice (emoji + dataview), last match wins
  -- (markers are processed in order of position)
  local t = parse.parse("- [ ] Task 📅 2024-01-01 [due:: 2024-02-01]")
  -- dataview appears after emoji, so it wins
  eq(t.fields.due, "2024-02-01")
  eq(t._origin.due, "dataview")
end

return T
