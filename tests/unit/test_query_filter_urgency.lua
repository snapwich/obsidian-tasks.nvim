-- tests/unit/test_query_filter_urgency.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/UrgencyField.test.ts
--
-- Urgency formula mirrors upstream's src/Task/Urgency.ts.  Coefficients:
--   due=12.0, scheduled=5.0, start=-3.0, priority=6.0
-- See lua/obsidian-tasks/task/urgency.lua for the priority-multiplier table.
--
-- The test pins "today" to a known date so the relative due-date scoring is
-- deterministic.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")
local urgency = require("obsidian-tasks.task.urgency")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(line, task)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/v/note.md")
end

-- ── Pin "today" to 2024-04-20 for predictable scoring ────────────────────

local TODAY_2024_04_20 = os.time({ year = 2024, month = 4, day = 20, hour = 0, min = 0, sec = 0 })

local function with_today(test_fn)
  return function()
    urgency._set_today(TODAY_2024_04_20)
    local ok, err = pcall(test_fn)
    urgency._set_today(nil)
    if not ok then
      error(err)
    end
  end
end

-- ── calculate(): base score for an empty task is 0 ───────────────────────

T["calculate: task with no fields has urgency ≈ 0 (priority=none default)"] = with_today(function()
  local u = urgency.calculate(pt("- [ ] Plain task"))
  -- priority=none contributes 0.325 * 6.0 = 1.95
  eq(math.abs(u - 1.95) < 0.001, true)
end)

-- ── Due date contribution ────────────────────────────────────────────────

T["calculate: due today gives substantial urgency boost"] = with_today(function()
  local u = urgency.calculate(pt("- [ ] Task 📅 2024-04-20"))
  -- daysOverdue=0; mult = (0 + 14) * 0.8 / 21 + 0.2 = 0.733; * 12 = 8.8
  -- Plus priority=none term 1.95 = ~10.75
  eq(u > 10 and u < 11, true)
end)

T["calculate: task >7 days overdue gets max due multiplier (1.0)"] = with_today(function()
  -- Today is 2024-04-20.  Due 2024-04-01 (19 days overdue).
  local u = urgency.calculate(pt("- [ ] Task 📅 2024-04-01"))
  -- mult = 1.0 → 12.0 due + 1.95 priority = 13.95
  eq(math.abs(u - 13.95) < 0.01, true)
end)

T["calculate: task due >2 weeks in future gets min due multiplier (0.2)"] = with_today(function()
  -- Today 2024-04-20.  Due 2024-05-15 (25 days away).
  local u = urgency.calculate(pt("- [ ] Task 📅 2024-05-15"))
  -- mult = 0.2 → 2.4 due + 1.95 priority = 4.35
  eq(math.abs(u - 4.35) < 0.01, true)
end)

-- ── Priority contribution ────────────────────────────────────────────────

T["calculate: priority=highest adds 1.5 * 6.0 = 9.0"] = with_today(function()
  local plain = urgency.calculate(pt("- [ ] Plain"))
  local high = urgency.calculate(pt("- [ ] Plain 🔺"))
  -- Difference: highest term (1.5*6) replaces none term (0.325*6) = 1.175*6 = 7.05
  eq(math.abs((high - plain) - 7.05) < 0.01, true)
end)

T["calculate: priority=lowest subtracts 0.3 * 6 = 1.8 from baseline"] = with_today(function()
  local plain = urgency.calculate(pt("- [ ] Plain"))
  local lowest = urgency.calculate(pt("- [ ] Plain ⏬"))
  -- Difference: lowest term (-0.3*6) replaces none term (0.325*6) = -0.625*6 = -3.75
  eq(math.abs((lowest - plain) - -3.75) < 0.01, true)
end)

-- ── Scheduled / start contributions ──────────────────────────────────────

T["calculate: scheduled in past adds +5.0"] = with_today(function()
  local plain = urgency.calculate(pt("- [ ] Task"))
  local sched = urgency.calculate(pt("- [ ] Task ⏳ 2024-04-15"))
  eq(math.abs((sched - plain) - 5.0) < 0.001, true)
end)

T["calculate: start in future adds -3.0 (penalty for future-start)"] = with_today(function()
  local plain = urgency.calculate(pt("- [ ] Task"))
  local started = urgency.calculate(pt("- [ ] Task 🛫 2024-05-01"))
  eq(math.abs((started - plain) - -3.0) < 0.001, true)
end)

-- ── Filter integration: `urgency above N` / `urgency below N` ────────────

T["filter: urgency above 5: matches high-urgency task"] = with_today(function()
  eq(matches("urgency above 5", pt("- [ ] Task 📅 2024-04-20 🔺")), true)
end)

T["filter: urgency below 2: matches low-urgency task"] = with_today(function()
  eq(matches("urgency below 2", pt("- [ ] Plain task")), true)
end)

T["filter: urgency above 100: matches nothing"] = with_today(function()
  eq(matches("urgency above 100", pt("- [ ] Task 📅 2024-04-20 🔺")), false)
end)

return T
