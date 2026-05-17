-- tests/unit/test_would_move.lua
-- RED-phase unit tests for the M._would_move helper.
--
-- All tests load without error.  The majority assert moves=true which
-- FAILS against the current stub (always returns { moves = false }).
-- Once the P6 GREEN task (ot-ckin) implements real detection logic these
-- tests must pass.
--
-- Locked decisions exercised:
--   - Date change crossing group boundary (group by due) → moves=true
--   - Tag change (group by tags) → moves=true
--   - Description change with no group/sort impact → moves=false
--   - Status change (group by status) → moves=true
--   - Priority change (sort by priority, order changes) → moves=true
--   - Same-group edit that changes within-group index → moves=true
--     with prior_index_within_group captured correctly

local T = MiniTest.new_set()

local edit_mod = require("obsidian-tasks.render.edit")
local parse_task = require("obsidian-tasks.task.parse")

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

--- Parse a task line; asserts it succeeded.
local function pt(line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected parseable task line: " .. line)
  return t
end

-- ── 1. Date change crosses group boundary (group by due) ─────────────────────
-- Editing the due date to a value in a different group should be detected as a
-- visual move.  The linger must be recorded so the task stays at the prior
-- position until manual refresh.
--
-- RED: stub returns { moves = false } → eq(result.moves, true) FAILS.

T["_would_move: due-date change crossing group boundary → moves=true"] = function()
  local task_before = pt("- [ ] Task A 📅 2026-01-01")
  local task_after = pt("- [ ] Task A 📅 2026-02-01")
  local layout_ctx = {
    group_by = { { key = "due" } },
    sort_by = {},
    current_group_name = "2026-01-01",
    current_index = 0,
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  -- Expect: the edit moves the task from group "2026-01-01" to "2026-02-01".
  eq(result.moves, true, "due-date change to a different group must return moves=true")
  eq(result.prior_group_name, "2026-01-01", "prior_group_name must be captured")
  eq(result.prior_index_within_group, 0, "prior_index_within_group must be captured")
end

-- ── 2. Tag change on group-by-tags dashboard ──────────────────────────────────
-- Editing the tag that determines the group should move the task.
--
-- RED: stub returns { moves = false } → eq(result.moves, true) FAILS.

T["_would_move: tag change on group-by-tags dashboard → moves=true"] = function()
  local task_before = pt("- [ ] Task #alpha")
  local task_after = pt("- [ ] Task #beta")
  local layout_ctx = {
    group_by = { { key = "tags" } },
    sort_by = {},
    current_group_name = "#alpha",
    current_index = 0,
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  eq(result.moves, true, "tag change to a different tag group must return moves=true")
  eq(result.prior_group_name, "#alpha", "prior_group_name must be #alpha")
end

-- ── 3. Description change — no group/sort impact → moves=false ───────────────
-- Editing only the description when the query has no group-by or sort-by on
-- description should NOT be detected as a visual move.
--
-- GREEN: this test PASSES with the stub since stub returns { moves = false }.

T["_would_move: description-only change with no group/sort impact → moves=false"] = function()
  local task_before = pt("- [ ] Buy milk")
  local task_after = pt("- [ ] Buy oat milk")
  local layout_ctx = {
    group_by = {},
    sort_by = {},
    current_group_name = "",
    current_index = 0,
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  -- No group-by or sort-by: description edit cannot change position.
  eq(result.moves, false, "description-only change must return moves=false when no group/sort on description")
end

-- ── 4. Status change on group-by-status dashboard ────────────────────────────
-- Toggling a task from Todo to Done should move it to a different status group.
--
-- RED: stub returns { moves = false } → eq(result.moves, true) FAILS.

T["_would_move: status change on group-by-status dashboard → moves=true"] = function()
  local task_before = pt("- [ ] Task") -- Todo
  local task_after = pt("- [x] Task") -- Done
  local layout_ctx = {
    group_by = { { key = "status" } },
    sort_by = {},
    current_group_name = "Todo",
    current_index = 0,
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  eq(result.moves, true, "status change from Todo to Done must return moves=true on group-by-status dashboard")
  eq(result.prior_group_name, "Todo", "prior_group_name must be Todo")
end

-- ── 5. Priority change causes sort-order shift ───────────────────────────────
-- Changing priority from high (⏫) to lowest (⏬) on a sort-by-priority
-- dashboard should move the task to a lower position in the sort order.
--
-- RED: stub returns { moves = false } → eq(result.moves, true) FAILS.

T["_would_move: priority change on sort-by-priority dashboard → moves=true"] = function()
  -- Two tasks exist: task_before is ⏫ (high, sort order 2) and another task
  -- with ⏬ (lowest, sort order 5).  After changing to ⏬, task_before would
  -- sort after the lowest-priority task → index shift.
  local task_before = pt("- [ ] Task ⏫") -- high priority
  local task_after = pt("- [ ] Task ⏬") -- lowest priority (sort order changes)
  local layout_ctx = {
    group_by = {},
    sort_by = { { key = "priority", reverse = false } },
    current_group_name = "",
    current_index = 0, -- was first in sort order (high priority sorts to front)
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  eq(result.moves, true, "priority change causing sort-order shift must return moves=true")
  eq(result.prior_index_within_group, 0, "prior_index_within_group must be captured")
end

-- ── 6. Same-group edit changes within-group sort index ───────────────────────
-- Editing a date field that determines sort order within the SAME group should
-- also be detected as a move (prior_index captured).
--
-- RED: stub returns { moves = false } → eq(result.moves, true) FAILS.

T["_would_move: same-group due-date change with sort-by-due shifts index → moves=true"] = function()
  -- Task was at index 2 in the group (sorted by due asc).
  -- Editing the due date to an earlier date would move the task to a lower index.
  local task_before = pt("- [ ] Task 📅 2026-01-15") -- sorts to index 2 within group
  local task_after = pt("- [ ] Task 📅 2026-01-01") -- would sort to index 0 (earlier date)
  local layout_ctx = {
    group_by = {},
    sort_by = { { key = "due", reverse = false } },
    current_group_name = "",
    current_index = 2,
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  eq(result.moves, true, "due-date edit causing within-group sort shift must return moves=true")
  eq(result.prior_index_within_group, 2, "prior_index_within_group must be 2")
end

-- ── 7. Return shape: non-moving edit has no prior_group_name ─────────────────
-- When moves=false, prior_group_name and prior_index_within_group need not be
-- present (nil is acceptable).
--
-- GREEN: this test PASSES with the stub since stub returns { moves = false }.

T["_would_move: non-moving edit result has moves=false and no prior position fields"] = function()
  local task_before = pt("- [ ] Note task")
  local task_after = pt("- [ ] Note task edited")
  local layout_ctx = {
    group_by = {},
    sort_by = {},
    current_group_name = "",
    current_index = 0,
  }

  local result = edit_mod._would_move(task_before, task_after, layout_ctx)

  eq(result.moves, false)
  -- prior_group_name and prior_index_within_group should be nil (or absent).
  eq(result.prior_group_name, nil)
  eq(result.prior_index_within_group, nil)
end

return T
