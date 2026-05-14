-- tests/unit/test_query_filter_due_date.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/DueDateField.test.ts
--
-- Covers the supported v1 operators: has/no/before/after/on/in/date_invalid.
--
-- KNOWN GAPS vs upstream (tracked for Bucket B / Phase 2):
--   • ISO-week period (`due 2024-W09`) — not yet supported
--   • Quarter period (`due 2024-Q1`) — not yet supported

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  return t
end

local function matches(filter_line, task)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

-- ── has / no due date ─────────────────────────────────────────────────────

T["has due date: true when due set"] = function()
  eq(matches("has due date", pt("- [ ] Task 📅 2024-04-20")), true)
end

T["has due date: false when no due"] = function()
  eq(matches("has due date", pt("- [ ] Task without due")), false)
end

T["no due date: true when no due"] = function()
  eq(matches("no due date", pt("- [ ] Task without due")), true)
end

T["no due date: false when due set"] = function()
  eq(matches("no due date", pt("- [ ] Task 📅 2024-04-20")), false)
end

-- ── due before <date> ─────────────────────────────────────────────────────

T["due before: true when date is strictly earlier"] = function()
  eq(matches("due before 2024-04-20", pt("- [ ] Task 📅 2024-04-15")), true)
end

T["due before: false when date is equal (strict)"] = function()
  eq(matches("due before 2024-04-20", pt("- [ ] Task 📅 2024-04-20")), false)
end

T["due before: false when date is later"] = function()
  eq(matches("due before 2024-04-20", pt("- [ ] Task 📅 2024-04-25")), false)
end

T["due before: false when no due date (filter-fail, not error)"] = function()
  eq(matches("due before 2024-04-20", pt("- [ ] Task without due")), false)
end

-- ── due after <date> ──────────────────────────────────────────────────────

T["due after: true when date is strictly later"] = function()
  eq(matches("due after 2024-04-20", pt("- [ ] Task 📅 2024-04-25")), true)
end

T["due after: false when date is equal (strict)"] = function()
  eq(matches("due after 2024-04-20", pt("- [ ] Task 📅 2024-04-20")), false)
end

T["due after: false when date is earlier"] = function()
  eq(matches("due after 2024-04-20", pt("- [ ] Task 📅 2024-04-15")), false)
end

T["due after: false when no due date"] = function()
  eq(matches("due after 2024-04-20", pt("- [ ] Task without due")), false)
end

-- ── due on <date> ─────────────────────────────────────────────────────────

T["due on: true when date matches exactly"] = function()
  eq(matches("due on 2024-04-20", pt("- [ ] Task 📅 2024-04-20")), true)
end

T["due on: false when date differs by one day"] = function()
  eq(matches("due on 2024-04-20", pt("- [ ] Task 📅 2024-04-21")), false)
end

T["due on: false when no due date"] = function()
  eq(matches("due on 2024-04-20", pt("- [ ] Task without due")), false)
end

-- ── due before/after/on with relative tokens (today/tomorrow) ─────────────

T["due before today: resolves 'today' to current date string"] = function()
  -- The ISO date for "today" is computed at parse time.  We can't easily
  -- mock the system clock here — just verify the predicate returns a
  -- boolean and the parse didn't error.
  local ast = qp.parse("due before today")
  eq(#ast.errors, 0)
  local pred = filter_mod.compile_all(ast.filters)
  eq(type(pred(pt("- [ ] Task 📅 2024-01-01"), "/vault/note.md")), "boolean")
end

T["due after tomorrow: resolves 'tomorrow'"] = function()
  local ast = qp.parse("due after tomorrow")
  eq(#ast.errors, 0)
end

-- ── due date is invalid ───────────────────────────────────────────────────

T["due date is invalid: true when field has non-ISO value"] = function()
  local t = pt("- [ ] Task")
  t.fields.due = "not-a-date"
  local ast = qp.parse("due date is invalid")
  local pred = filter_mod.compile_all(ast.filters)
  eq(pred(t, "/vault/note.md"), true)
end

T["due date is invalid: false when field has valid ISO date"] = function()
  eq(matches("due date is invalid", pt("- [ ] Task 📅 2024-04-20")), false)
end

T["due date is invalid: false when field is absent"] = function()
  -- Upstream: a task with no due date is NOT 'date invalid' (it has no date
  -- to be invalid).  Verify our parity.
  eq(matches("due date is invalid", pt("- [ ] Task without due")), false)
end

-- ── due on or before <date> / due on or after <date> ─────────────────────

T["due on or before: true when date is strictly earlier"] = function()
  eq(matches("due on or before 2024-04-20", pt("- [ ] Task 📅 2024-04-15")), true)
end

T["due on or before: true when date is EQUAL"] = function()
  eq(matches("due on or before 2024-04-20", pt("- [ ] Task 📅 2024-04-20")), true)
end

T["due on or before: false when date is later"] = function()
  eq(matches("due on or before 2024-04-20", pt("- [ ] Task 📅 2024-04-25")), false)
end

T["due on or before: false when no due date"] = function()
  eq(matches("due on or before 2024-04-20", pt("- [ ] Task without due")), false)
end

T["due on or after: true when date is strictly later"] = function()
  eq(matches("due on or after 2024-04-20", pt("- [ ] Task 📅 2024-04-25")), true)
end

T["due on or after: true when date is EQUAL"] = function()
  eq(matches("due on or after 2024-04-20", pt("- [ ] Task 📅 2024-04-20")), true)
end

T["due on or after: false when date is earlier"] = function()
  eq(matches("due on or after 2024-04-20", pt("- [ ] Task 📅 2024-04-15")), false)
end

T["due on or after: false when no due date"] = function()
  eq(matches("due on or after 2024-04-20", pt("- [ ] Task without due")), false)
end

-- ── due in <range> (single-date semantics in v1) ──────────────────────────

T["due in <date>: matches when due equals the date"] = function()
  -- Single-date `in` is a synonym for `on`.
  eq(matches("due in 2024-04-20", pt("- [ ] Task 📅 2024-04-20")), true)
end

-- ── Two-date range syntax (`<field> [op] <start> <end>`) ──────────────────

T["due 2024-01-01 2024-01-31: matches dates within the range (inclusive)"] = function()
  eq(matches("due 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-01-15")), true)
  eq(matches("due 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-01-01")), true) -- inclusive lower
  eq(matches("due 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-01-31")), true) -- inclusive upper
  eq(matches("due 2024-01-01 2024-01-31", pt("- [ ] T 📅 2023-12-31")), false)
  eq(matches("due 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-02-01")), false)
end

T["due in 2024-01-01 2024-01-31: explicit `in` operator with range"] = function()
  eq(matches("due in 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-01-15")), true)
end

T["due on or before 2024-01-01 2024-01-31: tv <= range_end"] = function()
  -- Matches anything ≤ 2024-01-31 (the range upper-bound).
  eq(matches("due on or before 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-01-31")), true)
  eq(matches("due on or before 2024-01-01 2024-01-31", pt("- [ ] T 📅 2024-02-01")), false)
end

-- ── Year shortcut: `<field> YYYY` ────────────────────────────────────────

T["due 2024: matches any date in calendar year"] = function()
  eq(matches("due 2024", pt("- [ ] T 📅 2024-01-01")), true)
  eq(matches("due 2024", pt("- [ ] T 📅 2024-06-15")), true)
  eq(matches("due 2024", pt("- [ ] T 📅 2024-12-31")), true)
  eq(matches("due 2024", pt("- [ ] T 📅 2023-12-31")), false)
  eq(matches("due 2024", pt("- [ ] T 📅 2025-01-01")), false)
end

-- ── Month shortcut: `<field> YYYY-MM` ────────────────────────────────────

T["due 2024-03: matches any date in March 2024"] = function()
  eq(matches("due 2024-03", pt("- [ ] T 📅 2024-03-01")), true)
  eq(matches("due 2024-03", pt("- [ ] T 📅 2024-03-31")), true)
  eq(matches("due 2024-03", pt("- [ ] T 📅 2024-02-29")), false)
  eq(matches("due 2024-03", pt("- [ ] T 📅 2024-04-01")), false)
end

T["due 2024-02: month with 29 days in leap year"] = function()
  eq(matches("due 2024-02", pt("- [ ] T 📅 2024-02-29")), true)
end

T["due 2023-02: non-leap year February ends on 28"] = function()
  eq(matches("due 2023-02", pt("- [ ] T 📅 2023-02-28")), true)
  eq(matches("due 2023-02", pt("- [ ] T 📅 2023-03-01")), false)
end

return T
