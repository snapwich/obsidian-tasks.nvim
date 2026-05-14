-- tests/unit/test_query_filter_boolean.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/BooleanField.test.ts
-- (plus BooleanDelimiters.test.ts and BooleanPreprocessor.test.ts edge cases).
--
-- Tests our v1 boolean combinators: AND, OR, NOT, parentheses, nesting.
--
-- KNOWN GAPS vs upstream:
--   • Upstream supports custom delimiters via quoted strings ("not done")
--     to disambiguate filters that themselves contain "and"/"or"/"not"
--     keywords.  We rely on space-delimited operators only.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(line, task)
  local ast = qp.parse(line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

-- ── AND ────────────────────────────────────────────────────────────────────

T["AND: both true → true"] = function()
  local t = pt("- [ ] Task #work 📅 2024-04-20")
  eq(matches("(not done and has due date)", t), true)
end

T["AND: one false → false"] = function()
  -- done = true, has due date = true → AND of (not done and has due date) = (false and true) = false
  local t = pt("- [x] Task ✅ 2024-01-01 📅 2024-04-20")
  eq(matches("(not done and has due date)", t), false)
end

T["AND: both false → false"] = function()
  local t = pt("- [x] Task ✅ 2024-01-01")
  eq(matches("(not done and has due date)", t), false)
end

-- ── OR ─────────────────────────────────────────────────────────────────────

T["OR: both true → true"] = function()
  local t = pt("- [ ] Task #work 📅 2024-04-20")
  eq(matches("(not done or has due date)", t), true)
end

T["OR: first true second false → true"] = function()
  local t = pt("- [ ] Task without due")
  eq(matches("(not done or has due date)", t), true)
end

T["OR: first false second true → true"] = function()
  local t = pt("- [x] Task ✅ 2024-01-01 📅 2024-04-20")
  eq(matches("(not done or has due date)", t), true)
end

T["OR: both false → false"] = function()
  local t = pt("- [x] Task ✅ 2024-01-01")
  eq(matches("(not done or has due date)", t), false)
end

-- ── NOT ────────────────────────────────────────────────────────────────────

T["NOT: negates true to false"] = function()
  eq(matches("not (done)", pt("- [x] Task ✅ 2024-01-01")), false)
end

T["NOT: negates false to true"] = function()
  eq(matches("not (done)", pt("- [ ] Task")), true)
end

-- ── Nested expressions ────────────────────────────────────────────────────

T["nested: (A and B) or C"] = function()
  local t = pt("- [ ] Task #work")
  -- (not done and has tag) or has due date
  -- (true and true) or false = true
  eq(matches("((not done and has tag) or has due date)", t), true)
end

T["nested: A and (B or C)"] = function()
  local t = pt("- [ ] Task")
  -- not done and (has tag or has due date)
  -- true and (false or false) = false
  eq(matches("(not done and (has tag or has due date))", t), false)
end

T["nested: not (A and B) — upstream syntax accepted"] = function()
  local t = pt("- [ ] Task #work")
  eq(matches("not (not done and has tag)", t), false)
end

T["nested: not (A or B) — upstream syntax accepted"] = function()
  local t = pt("- [ ] Task #work")
  eq(matches("not (done or has tag)", t), false)
end

-- ── Vault portability: upstream's natural infix syntax ────────────────────
-- Queries written against upstream obsidian-tasks must parse identically
-- in our plugin because vaults are portable.

T["portability: `(A) AND (B)` works without outer wrapping parens"] = function()
  local t = pt("- [ ] Task #work")
  eq(matches("(not done) AND (has tag)", t), true)
end

T["portability: `A AND B` works without any parens"] = function()
  local t = pt("- [ ] Task #work")
  eq(matches("not done AND has tag", t), true)
end

T["portability: case-insensitive AND/OR/NOT keywords"] = function()
  local t = pt("- [ ] Task #work")
  eq(matches("not done AND has tag", t), true)
  eq(matches("not done and has tag", t), true)
  eq(matches("done OR not done", t), true)
  eq(matches("done or not done", t), true)
  eq(matches("NOT done", t), true)
end

T["portability: multi-AND chain `A AND B AND C`"] = function()
  local t = pt("- [ ] Task #work 📅 2024-04-20")
  eq(matches("not done AND has tag AND has due date", t), true)
end

T["portability: `NOT (priority above medium)` from upstream fixtures"] = function()
  -- One of the fixture queries in tests/fixtures/vault/queries/combinators.md
  eq(matches("NOT (priority above medium)", pt("- [ ] Task")), true)
  eq(matches("NOT (priority above medium)", pt("- [ ] Task 🔺")), false)
end

T["portability: complex `(A) AND (B) AND ((C) OR (D))` from upstream fixtures"] = function()
  -- Another fixture query: bigger combinator nesting.
  local t = pt("- [ ] Task #work 📅 2026-05-15")
  local q = "(path includes work) AND (not done) AND ((priority above medium) OR (due before 2026-05-20))"
  -- path doesn't include "work" → first clause is false → overall false.
  eq(matches(q, t), false)
end

-- ── Operator precedence (left-to-right, no precedence) ────────────────────

T["precedence: explicit parens required for AND/OR mix"] = function()
  -- Without parens, the parser handles left-to-right.  This test verifies
  -- that the parens we add produce the expected result.
  local t = pt("- [ ] Task")
  -- not done and (done or not done) = true and true = true
  eq(matches("(not done and (done or not done))", t), true)
end

return T
