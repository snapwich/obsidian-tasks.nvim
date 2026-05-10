-- tests/unit/test_serialize.lua
-- Unit + round-trip tests for task/serialize.lua

local T = MiniTest.new_set()
local parse = require("obsidian-tasks.task.parse")
local serialize = require("obsidian-tasks.task.serialize")

-- ── helpers ────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Parse then serialize with given opts; asserts result equals expected.
local function roundtrip(line, opts, expected)
  local task = parse.parse(line)
  MiniTest.expect.equality(task ~= nil, true)
  local result = serialize.serialize(task, opts)
  MiniTest.expect.equality(result, expected or line)
end

-- ── empty / minimal ────────────────────────────────────────────────────────

T["empty task: - [ ] round-trips"] = function()
  roundtrip("- [ ]")
end

T["no fields: description only"] = function()
  roundtrip("- [ ] Just a task")
end

T["no fields: done status"] = function()
  roundtrip("- [x] Done task")
end

T["no fields: in-progress status"] = function()
  roundtrip("- [/] In progress task")
end

T["no fields: cancelled status"] = function()
  roundtrip("- [-] Cancelled task")
end

T["no fields: on-hold status"] = function()
  roundtrip("- [h] On hold task")
end

T["indented: sub-task"] = function()
  roundtrip("  - [ ] Indented sub-task")
end

-- ── single emoji fields ────────────────────────────────────────────────────

T["emoji: due date round-trips"] = function()
  roundtrip("- [ ] Task 📅 2024-01-15")
end

T["emoji: scheduled date round-trips"] = function()
  roundtrip("- [ ] Task ⏳ 2024-02-01")
end

T["emoji: start date round-trips"] = function()
  roundtrip("- [ ] Task 🛫 2024-03-10")
end

T["emoji: done date round-trips"] = function()
  roundtrip("- [x] Task ✅ 2024-04-20")
end

T["emoji: cancelled date round-trips"] = function()
  roundtrip("- [-] Task ❌ 2024-05-05")
end

T["emoji: created date round-trips"] = function()
  roundtrip("- [ ] Task ➕ 2024-06-01")
end

T["emoji: recurrence single round-trips"] = function()
  roundtrip("- [ ] Task 🔁 every week")
end

T["emoji: recurrence multi-word round-trips"] = function()
  roundtrip("- [ ] Task 🔁 every month on the 1st")
end

T["emoji: id round-trips"] = function()
  roundtrip("- [ ] Task 🆔 abc-123")
end

T["emoji: depends_on round-trips"] = function()
  roundtrip("- [ ] Task ⛔ xyz-456")
end

T["emoji: on_completion round-trips"] = function()
  roundtrip("- [ ] Task 🏁 delete")
end

-- ── priority emoji ─────────────────────────────────────────────────────────

T["priority: highest (🔺) round-trips"] = function()
  roundtrip("- [ ] Task 🔺")
end

T["priority: high (⏫) round-trips"] = function()
  roundtrip("- [ ] Task ⏫")
end

T["priority: medium (🔼) round-trips"] = function()
  roundtrip("- [ ] Task 🔼")
end

T["priority: low (🔽) round-trips"] = function()
  roundtrip("- [ ] Task 🔽")
end

T["priority: lowest (⏬) round-trips"] = function()
  roundtrip("- [ ] Task ⏬")
end

-- ── multiple emoji fields ──────────────────────────────────────────────────

T["emoji: multiple fields in canonical order"] = function()
  roundtrip("- [ ] Task ⏫ 🛫 2024-01-01 ⏳ 2024-01-05 📅 2024-01-10 ➕ 2024-01-01")
end

T["emoji: all fields round-trip"] = function()
  roundtrip(
    "- [x] Full task ⏫ 🔁 every week 🛫 2024-01-01 ⏳ 2024-01-05 📅 2024-01-10 ➕ 2024-01-01 ✅ 2024-01-10 ❌ 2024-01-11 🆔 abc-123 ⛔ def-456 🏁 delete"
  )
end

-- ── tags ───────────────────────────────────────────────────────────────────

T["tags: embedded tag in description round-trips"] = function()
  roundtrip("- [ ] Task #project")
end

T["tags: trailing tag after field round-trips"] = function()
  roundtrip("- [ ] Task 📅 2024-01-01 #urgent")
end

T["tags: embedded tag + field round-trips"] = function()
  roundtrip("- [ ] My #work task 📅 2024-01-01")
end

-- ── pure dataview ──────────────────────────────────────────────────────────

T["dataview: due date round-trips"] = function()
  roundtrip("- [ ] Task [due:: 2024-01-15]")
end

T["dataview: priority round-trips"] = function()
  roundtrip("- [ ] Task [priority:: high]")
end

T["dataview: recurrence (repeat key) round-trips"] = function()
  roundtrip("- [ ] Task [repeat:: every week]")
end

T["dataview: done (completion key) round-trips"] = function()
  roundtrip("- [x] Task [completion:: 2024-04-20]")
end

T["dataview: cancelled round-trips"] = function()
  roundtrip("- [-] Task [cancelled:: 2024-05-05]")
end

T["dataview: all fields in canonical order round-trip"] = function()
  roundtrip(
    "- [ ] Task [priority:: highest] [repeat:: every day] [start:: 2024-01-01] [scheduled:: 2024-01-05] [due:: 2024-01-10] [created:: 2024-01-01] [completion:: 2024-01-10] [cancelled:: 2024-01-11] [id:: abc-123] [dependsOn:: def-456] [onCompletion:: delete]"
  )
end

-- ── mixed emoji + dataview ─────────────────────────────────────────────────

T["mixed: dataview scheduled before emoji due round-trips"] = function()
  -- scheduled < due in canonical order, so dataview-scheduled then emoji-due is stable
  roundtrip("- [ ] Task [scheduled:: 2024-01-10] 📅 2024-01-15")
end

-- ── fixture file: all lines round-trip ────────────────────────────────────

T["fixture file: every line round-trips with preserve format"] = function()
  local fixture = "tests/fixtures/tasks/round_trip.txt"
  local lines = vim.fn.readfile(fixture)
  MiniTest.expect.equality(type(lines), "table")
  MiniTest.expect.equality(#lines >= 30, true)

  for _, line in ipairs(lines) do
    if line ~= "" then
      local task = parse.parse(line)
      MiniTest.expect.equality(task ~= nil, true)
      local result = serialize.serialize(task, { format = "preserve" })
      if result ~= line then
        -- surface the failing line in the error message
        error(string.format("round-trip failed:\n  input:  %q\n  output: %q", line, result))
      end
    end
  end
end

-- ── format: explicit emoji / dataview ─────────────────────────────────────

T["format=emoji: emits emoji tokens regardless of _origin"] = function()
  local task = parse.parse("- [ ] Task [due:: 2024-01-15]")
  -- origin is 'dataview', but format='emoji' forces emoji output
  local result = serialize.serialize(task, { format = "emoji" })
  eq(result, "- [ ] Task 📅 2024-01-15")
end

T["format=dataview: emits dataview tokens regardless of _origin"] = function()
  local task = parse.parse("- [ ] Task 📅 2024-01-15")
  -- origin is 'emoji', but format='dataview' forces dataview output
  local result = serialize.serialize(task, { format = "dataview" })
  eq(result, "- [ ] Task [due:: 2024-01-15]")
end

T["format=emoji: priority emits correct emoji for each level"] = function()
  local cases = {
    { "highest", "🔺" },
    { "high", "⏫" },
    { "medium", "🔼" },
    { "low", "🔽" },
    { "lowest", "⏬" },
  }
  for _, c in ipairs(cases) do
    local task = parse.parse("- [ ] Task [priority:: " .. c[1] .. "]")
    local result = serialize.serialize(task, { format = "emoji" })
    eq(result, "- [ ] Task " .. c[2])
  end
end

T["format=dataview: priority emits level name"] = function()
  local task = parse.parse("- [ ] Task ⏫")
  local result = serialize.serialize(task, { format = "dataview" })
  eq(result, "- [ ] Task [priority:: high]")
end

T["format=dataview: done field uses 'completion' key"] = function()
  local task = parse.parse("- [x] Task ✅ 2024-01-15")
  local result = serialize.serialize(task, { format = "dataview" })
  eq(result, "- [x] Task [completion:: 2024-01-15]")
end

T["format=dataview: recurrence field uses 'repeat' key"] = function()
  local task = parse.parse("- [ ] Task 🔁 every week")
  local result = serialize.serialize(task, { format = "dataview" })
  eq(result, "- [ ] Task [repeat:: every week]")
end

T["format=dataview: depends_on uses 'dependsOn' key"] = function()
  local task = parse.parse("- [ ] Task ⛔ abc-123")
  local result = serialize.serialize(task, { format = "dataview" })
  eq(result, "- [ ] Task [dependsOn:: abc-123]")
end

T["format=dataview: on_completion uses 'onCompletion' key"] = function()
  local task = parse.parse("- [ ] Task 🏁 delete")
  local result = serialize.serialize(task, { format = "dataview" })
  eq(result, "- [ ] Task [onCompletion:: delete]")
end

-- ── format-conversion lossless (all 12 fields) ────────────────────────────
-- Parse dataview → serialize emoji → parse → serialize dataview → equal original.

T["conversion lossless: due"] = function()
  local orig = "- [ ] Task [due:: 2024-01-15]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task 📅 2024-01-15")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: scheduled"] = function()
  local orig = "- [ ] Task [scheduled:: 2024-02-01]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task ⏳ 2024-02-01")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: start"] = function()
  local orig = "- [ ] Task [start:: 2024-03-10]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task 🛫 2024-03-10")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: done (completion)"] = function()
  local orig = "- [x] Task [completion:: 2024-04-20]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [x] Task ✅ 2024-04-20")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: cancelled"] = function()
  local orig = "- [-] Task [cancelled:: 2024-05-05]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [-] Task ❌ 2024-05-05")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: created"] = function()
  local orig = "- [ ] Task [created:: 2024-06-01]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task ➕ 2024-06-01")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: priority"] = function()
  local orig = "- [ ] Task [priority:: highest]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task 🔺")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: recurrence (repeat)"] = function()
  local orig = "- [ ] Task [repeat:: every week]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task 🔁 every week")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: id"] = function()
  local orig = "- [ ] Task [id:: abc-123]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task 🆔 abc-123")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: depends_on (dependsOn)"] = function()
  local orig = "- [ ] Task [dependsOn:: xyz-456]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task ⛔ xyz-456")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: on_completion (onCompletion)"] = function()
  local orig = "- [ ] Task [onCompletion:: delete]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(mid, "- [ ] Task 🏁 delete")
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

T["conversion lossless: all fields together"] = function()
  local orig =
    "- [x] Task [priority:: high] [repeat:: every day] [start:: 2024-01-01] [scheduled:: 2024-01-05] [due:: 2024-01-10] [created:: 2024-01-01] [completion:: 2024-01-10] [cancelled:: 2024-01-11] [id:: abc-123] [dependsOn:: def-456] [onCompletion:: delete]"
  local mid = serialize.serialize(parse.parse(orig), { format = "emoji" })
  eq(
    mid,
    "- [x] Task ⏫ 🔁 every day 🛫 2024-01-01 ⏳ 2024-01-05 📅 2024-01-10 ➕ 2024-01-01 ✅ 2024-01-10 ❌ 2024-01-11 🆔 abc-123 ⛔ def-456 🏁 delete"
  )
  local back = serialize.serialize(parse.parse(mid), { format = "dataview" })
  eq(back, orig)
end

-- ── field emission order ───────────────────────────────────────────────────

T["field order: priority before recurrence before dates"] = function()
  -- Build a task manually with fields in non-canonical order to verify serializer reorders
  local task = parse.parse("- [ ] Task 📅 2024-01-10 ⏫")
  -- After parse, fields are populated regardless of original order.
  -- Serialize should put priority first, then due.
  local result = serialize.serialize(task, { format = "emoji" })
  eq(result, "- [ ] Task ⏫ 📅 2024-01-10")
end

T["field order: created before done before cancelled"] = function()
  local task = parse.parse("- [x] Task ✅ 2024-01-10 ❌ 2024-01-11 ➕ 2024-01-01")
  -- Canonical: created (➕) before done (✅) before cancelled (❌)
  local result = serialize.serialize(task, { format = "emoji" })
  eq(result, "- [x] Task ➕ 2024-01-01 ✅ 2024-01-10 ❌ 2024-01-11")
end

-- ── preserve: defaults to emoji when _origin absent ───────────────────────

T["preserve: absent _origin entry defaults to emoji"] = function()
  -- Manually construct a task without _origin for a field
  local task = {
    indent = "",
    marker = "-",
    status_symbol = " ",
    description = "Task",
    fields = { due = "2024-01-01" },
    tags = {},
    _origin = {},
  }
  local result = serialize.serialize(task, { format = "preserve" })
  eq(result, "- [ ] Task 📅 2024-01-01")
end

-- ── nil / missing fields not emitted ──────────────────────────────────────

T["nil fields: not emitted"] = function()
  local task = parse.parse("- [ ] Just a task")
  local result = serialize.serialize(task, { format = "emoji" })
  eq(result, "- [ ] Just a task")
end

return T
