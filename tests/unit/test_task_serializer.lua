-- tests/unit/test_task_serializer.lua
-- Parity with .deps/obsidian-tasks/tests/TaskSerializer/{Default,Dataview}TaskSerializer.test.ts
--
-- Focused on round-trip property: parse(serialize(t)) ~= t for tasks
-- expressed in both emoji and dataview field syntax.  Our task/serialize.lua
-- emits emoji form by default; parser accepts both.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local serialize = require("obsidian-tasks.task.serialize")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

-- ── Round-trip: parse(serialize(parse(line))) preserves fields ───────────

T["round-trip: simple task with no fields"] = function()
  local t1 = pt("- [ ] Simple task")
  local t2 = pt(serialize.serialize(t1))
  eq(t2.description, t1.description)
  eq(t2.status_symbol, t1.status_symbol)
end

T["round-trip: emoji-encoded task with all dates"] = function()
  local t1 = pt("- [ ] Multi-date task 📅 2024-04-20 ⏳ 2024-04-15 🛫 2024-04-10 ➕ 2024-04-01")
  local s2 = serialize.serialize(t1)
  local t2 = pt(s2)
  eq(t2.fields.due, "2024-04-20")
  eq(t2.fields.scheduled, "2024-04-15")
  eq(t2.fields.start, "2024-04-10")
  eq(t2.fields.created, "2024-04-01")
end

T["round-trip: done task with done date"] = function()
  local t1 = pt("- [x] Done task ✅ 2024-04-20")
  local t2 = pt(serialize.serialize(t1))
  eq(t2.fields.done, "2024-04-20")
  eq(t2.status_symbol, "x")
end

T["round-trip: cancelled task with cancelled date"] = function()
  local t1 = pt("- [-] Cancelled ❌ 2024-04-20")
  local t2 = pt(serialize.serialize(t1))
  eq(t2.fields.cancelled, "2024-04-20")
  eq(t2.status_symbol, "-")
end

T["round-trip: priority preserved (each level)"] = function()
  for _, case in ipairs({
    { line = "- [ ] T 🔺", expect = "highest" },
    { line = "- [ ] T ⏫", expect = "high" },
    { line = "- [ ] T 🔼", expect = "medium" },
    { line = "- [ ] T 🔽", expect = "low" },
    { line = "- [ ] T ⏬", expect = "lowest" },
  }) do
    local t = pt(serialize.serialize(pt(case.line)))
    eq(t.fields.priority, case.expect)
  end
end

T["round-trip: recurrence string preserved verbatim"] = function()
  for _, pattern in ipairs({
    "every day",
    "every week",
    "every month",
    "every 3 weeks",
    "every Monday, Wednesday, Friday",
    "every 6 months",
  }) do
    local t = pt(serialize.serialize(pt("- [ ] T 🔁 " .. pattern)))
    eq(t.fields.recurrence, pattern)
  end
end

T["round-trip: tags preserved with order"] = function()
  local t = pt(serialize.serialize(pt("- [ ] Task #foo #bar #baz")))
  eq(t.tags[1], "#foo")
  eq(t.tags[2], "#bar")
  eq(t.tags[3], "#baz")
end

-- ── Parse: dataview form is accepted as input ────────────────────────────

T["parse: dataview [due:: ...] is recognized"] = function()
  local t = pt("- [ ] Dataview task [due:: 2024-04-20]")
  eq(t.fields.due, "2024-04-20")
end

T["parse: dataview [priority:: high] is recognized"] = function()
  local t = pt("- [ ] Task [priority:: high]")
  eq(t.fields.priority, "high")
end

T["parse: emoji + dataview can coexist on the same line"] = function()
  local t = pt("- [ ] T 📅 2024-04-20 [priority:: high]")
  eq(t.fields.due, "2024-04-20")
  eq(t.fields.priority, "high")
end

-- ── Serializer preserves the per-field source form (emoji vs dataview) ──

T["serialize: dataview-parsed fields are emitted as dataview"] = function()
  -- Round-trip property: a task parsed from dataview syntax is serialized
  -- back in the same syntax so the source file stays consistent.
  local t = pt("- [ ] T [due:: 2024-04-20] [priority:: high]")
  local s = serialize.serialize(t)
  eq(s:find("%[due:: 2024%-04%-20%]") ~= nil, true)
  eq(s:find("%[priority:: high%]") ~= nil, true)
end

T["serialize: emoji-parsed fields are emitted as emoji"] = function()
  local t = pt("- [ ] T 📅 2024-04-20 ⏫")
  local s = serialize.serialize(t)
  eq(s:find("📅 2024%-04%-20") ~= nil, true)
  eq(s:find("⏫") ~= nil, true)
end

T["serialize: mixed-syntax input round-trips with mixed syntax"] = function()
  local t = pt("- [ ] T 📅 2024-04-20 [priority:: high]")
  local s = serialize.serialize(t)
  -- Each field stays in its original form.
  eq(s:find("📅 2024%-04%-20") ~= nil, true)
  eq(s:find("%[priority:: high%]") ~= nil, true)
end

-- ── Field ordering matches upstream emoji order ──────────────────────────

T["serialize: field order matches upstream emoji conventional order"] = function()
  -- Upstream order: description → tags → priority → recurrence → start →
  -- scheduled → due → created → cancelled → done → on_completion → id →
  -- depends_on → blocking.
  local t = pt("- [ ] Task #tag 🔺 🔁 every week 🛫 2024-01-01 ⏳ 2024-02-01 📅 2024-03-01")
  local s = serialize.serialize(t)
  -- Emoji order in output: 🔺 (priority) before 🔁 (recurrence) before 🛫 before ⏳ before 📅.
  -- We check positions rather than exact string to allow for trailing whitespace differences.
  local function pos(emoji)
    return s:find(emoji, 1, true)
  end
  local p_pri = pos("🔺")
  local p_rec = pos("🔁")
  local p_start = pos("🛫")
  local p_sched = pos("⏳")
  local p_due = pos("📅")
  assert(p_pri and p_rec and p_start and p_sched and p_due, "all emojis must be present: " .. s)
  eq(p_pri < p_rec, true)
  eq(p_rec < p_start, true)
  eq(p_start < p_sched, true)
  eq(p_sched < p_due, true)
end

return T
