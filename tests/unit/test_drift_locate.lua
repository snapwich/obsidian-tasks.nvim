-- tests/unit/test_drift_locate.lua
-- RED-phase tests for cmd.locate — content-search drift recovery (Q12).
--
-- All tests fail while locate() is a stub returning nil.
-- They pass once the GREEN task (ot-32mh) implements the real search.
--
-- Locked decision Q12: content-search ±10 rows for stored task_text.
--   Found → return located row (caller writes at new row, updates extmark).
--   Not found (>10 row drift) → return nil (caller reverts + notifies).
--   Multiple matches → prefer the closest to expected_row.

local T = MiniTest.new_set()

local cmd = require("obsidian-tasks.cmd")

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

--- Build a source file with *task_text* placed at *task_row* (0-indexed),
--- surrounded by enough filler lines to allow ±10 drift room.
local function build_file_with_task(task_text, task_row, total_lines)
  total_lines = total_lines or 30
  local lines = {}
  for i = 1, total_lines do
    if i - 1 == task_row then
      lines[i] = task_text
    else
      lines[i] = "# filler line " .. i
    end
  end
  return make_tmpfile(lines)
end

-- ── Exact match at expected_row ───────────────────────────────────────────────

T["locate: exact match at expected_row"] = function()
  local task = "- [ ] Buy milk #task"
  local row = 10
  local path = build_file_with_task(task, row)

  local result = cmd.locate(path, row, task)
  eq(result, row, "should locate row exactly when no drift")

  vim.fn.delete(path)
end

-- ── ±1 row drift ─────────────────────────────────────────────────────────────

T["locate: +1 row drift found"] = function()
  local task = "- [ ] Task drifted plus one #task"
  local actual_row = 11 -- expected = 10, actual = 11 → +1 drift
  local path = build_file_with_task(task, actual_row)

  local result = cmd.locate(path, 10, task)
  eq(result, actual_row, "should find task at +1 drift")

  vim.fn.delete(path)
end

T["locate: -1 row drift found"] = function()
  local task = "- [ ] Task drifted minus one #task"
  local actual_row = 9 -- expected = 10, actual = 9 → -1 drift
  local path = build_file_with_task(task, actual_row)

  local result = cmd.locate(path, 10, task)
  eq(result, actual_row, "should find task at -1 drift")

  vim.fn.delete(path)
end

-- ── ±5 row drift ─────────────────────────────────────────────────────────────

T["locate: +5 row drift found"] = function()
  local task = "- [ ] Task drifted +5 #task"
  local actual_row = 15
  local path = build_file_with_task(task, actual_row)

  local result = cmd.locate(path, 10, task)
  eq(result, actual_row, "should find task at +5 drift")

  vim.fn.delete(path)
end

T["locate: -5 row drift found"] = function()
  local task = "- [ ] Task drifted -5 #task"
  local actual_row = 5
  local path = build_file_with_task(task, actual_row)

  local result = cmd.locate(path, 10, task)
  eq(result, actual_row, "should find task at -5 drift")

  vim.fn.delete(path)
end

-- ── ±10 row drift (boundary) ──────────────────────────────────────────────────

T["locate: +10 row drift found (boundary)"] = function()
  local task = "- [ ] Task at boundary +10 #task"
  local actual_row = 20
  local path = build_file_with_task(task, actual_row)

  local result = cmd.locate(path, 10, task)
  eq(result, actual_row, "should find task at exactly +10 drift (boundary)")

  vim.fn.delete(path)
end

T["locate: -10 row drift found (boundary)"] = function()
  local task = "- [ ] Task at boundary -10 #task"
  -- expected_row=10, actual_row=0 → -10 drift; need enough lines
  local actual_row = 0
  local path = build_file_with_task(task, actual_row, 25)

  local result = cmd.locate(path, 10, task)
  eq(result, actual_row, "should find task at exactly -10 drift (boundary)")

  vim.fn.delete(path)
end

-- ── ±11 row drift → returns nil ───────────────────────────────────────────────

T["locate: +11 row drift returns nil"] = function()
  local task = "- [ ] Task too far +11 #task"
  local actual_row = 21 -- expected=10, actual=21 → 11 beyond window
  local path = build_file_with_task(task, actual_row, 35)

  local result = cmd.locate(path, 10, task)
  eq(result, nil, "should return nil when drift exceeds ±10")

  vim.fn.delete(path)
end

T["locate: -11 row drift returns nil"] = function()
  local task = "- [ ] Task too far -11 #task"
  -- expected_row=15, actual_row=4 → 11 rows above → out of window
  local actual_row = 4
  local path = build_file_with_task(task, actual_row, 30)

  local result = cmd.locate(path, 15, task)
  eq(result, nil, "should return nil when drift is -11 (out of ±10 window)")

  vim.fn.delete(path)
end

-- ── Multiple matches → prefer closest ────────────────────────────────────────

T["locate: multiple identical lines, returns closest to expected_row"] = function()
  -- Place the same task text at rows 5 and 15 (expected = 10).
  -- Row 5 is distance 5; row 15 is distance 5.  Both within window.
  -- When tied, either is acceptable but the result must be one of them.
  -- If expected=10 and both row 8 and row 12 match, row 8 and row 12 are
  -- equidistant — test just asserts we get ONE of them (not nil).
  local task = "- [ ] Duplicated task #task"
  local lines = {}
  for i = 1, 30 do
    lines[i] = "# filler " .. i
  end
  lines[6] = task -- row 5 (0-indexed)
  lines[16] = task -- row 15 (0-indexed)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)

  local result = cmd.locate(path, 10, task)
  -- Both rows 5 and 15 are equidistant from 10; either is a valid locate result.
  local valid = (result == 5 or result == 15)
  MiniTest.expect.equality(valid, true, "should return one of the two closest matching rows")

  vim.fn.delete(path)
end

T["locate: when one match is closer, returns closest"] = function()
  -- Row 8 (distance 2) vs row 14 (distance 4) from expected_row=10.
  local task = "- [ ] Closer vs further #task"
  local lines = {}
  for i = 1, 30 do
    lines[i] = "# filler " .. i
  end
  lines[9] = task -- row 8 (0-indexed, distance=2)
  lines[15] = task -- row 14 (0-indexed, distance=4)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)

  local result = cmd.locate(path, 10, task)
  eq(result, 8, "should prefer the closest matching row (row 8, distance 2)")

  vim.fn.delete(path)
end

return T
