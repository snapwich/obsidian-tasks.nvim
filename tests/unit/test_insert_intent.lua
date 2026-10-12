-- tests/unit/test_insert_intent.lua
-- Plan D2 (group-top insert, step 2a): the pure insert-intent classifier.
--
-- insert_intent.classify(first, old_last, new_last, tracked_row) reads one
-- on_lines change plus the cursor row tracked BEFORE the change (all 0-indexed)
-- and tells which side of the pushed-down task the user typed on:
--   "above" — cursor was on the pushed-down task (`O` / `P` on it), so the new
--             line belongs to that task's group (group-top slot when it is the
--             first task of its group);
--   "below" — cursor was on the row above (`o` / `p` on the task above);
--   "none"  — not a pure line insert, or no cursor relation.

local T = MiniTest.new_set()

local classify = require("obsidian-tasks.render.insert_intent").classify

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

-- ── pure single-line insert ─────────────────────────────────────────────────

T["intent: O on the pushed-down task → above"] = function()
  -- Insert one line at row 5; cursor was on row 5 (the task that moves to 6).
  eq(classify(5, 5, 6, 5), "above")
end

T["intent: o on the task above → below"] = function()
  eq(classify(5, 5, 6, 4), "below")
end

T["intent: cursor far away → none"] = function()
  eq(classify(5, 5, 6, 9), "none")
  eq(classify(5, 5, 6, 2), "none")
end

T["intent: no tracked row → none"] = function()
  eq(classify(5, 5, 6, nil), "none")
end

-- ── multi-line insert ───────────────────────────────────────────────────────

T["intent: multi-line insert (3O / P of 3 lines) above → above"] = function()
  eq(classify(5, 5, 8, 5), "above")
end

T["intent: multi-line insert below → below"] = function()
  eq(classify(5, 5, 8, 4), "below")
end

-- ── not a pure insert ───────────────────────────────────────────────────────

T["intent: replacement of one line (typing on a row) → none"] = function()
  eq(classify(5, 6, 6, 5), "none")
end

T["intent: replacement that also adds lines → none"] = function()
  -- One line changed into two (e.g. <CR> in the middle of a row).
  eq(classify(5, 6, 7, 5), "none")
end

T["intent: delete → none"] = function()
  eq(classify(5, 6, 5, 5), "none")
  eq(classify(5, 8, 5, 4), "none")
end

T["intent: no-op change → none"] = function()
  eq(classify(5, 5, 5, 5), "none")
end

-- ── row 0 ───────────────────────────────────────────────────────────────────

T["intent: O on row 0 → above"] = function()
  eq(classify(0, 0, 1, 0), "above")
end

T["intent: insert at row 0 with an unrelated cursor → none"] = function()
  eq(classify(0, 0, 1, 3), "none")
  eq(classify(0, 0, 1, nil), "none")
end

T["intent: tracked row -1 never classifies as below at row 0"] = function()
  -- A stale / bogus tracked row must not invent a "task above" at row 0.
  eq(classify(0, 0, 1, -1), "none")
end

return T
