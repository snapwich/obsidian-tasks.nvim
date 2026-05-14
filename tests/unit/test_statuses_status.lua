-- tests/unit/test_statuses_status.lua
-- Parity with .deps/obsidian-tasks/tests/Statuses/{Status,StatusRegistry}.test.ts
--
-- Covers the default status table, opts.statuses override semantics, and
-- isCompleted helper.  Most of these are also exercised by tests/unit/test_status.lua
-- — this file adds upstream-specific edge cases.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local status = require("obsidian-tasks.task.status")

-- Reset to defaults before each test to keep isolation when other tests
-- mutate the registry via status.merge().
local function reset()
  status.merge({})
end

T["defaults: 5 entries (Todo / Done / In Progress / Cancelled / On Hold)"] = function()
  reset()
  eq(#status.statuses, 5)
end

T["lookup by symbol covers all defaults"] = function()
  reset()
  eq(status.by_symbol[" "].name, "Todo")
  eq(status.by_symbol["x"].name, "Done")
  eq(status.by_symbol["/"].name, "In Progress")
  eq(status.by_symbol["-"].name, "Cancelled")
  eq(status.by_symbol["h"].name, "On Hold")
end

T["lookup by type covers all defaults"] = function()
  reset()
  eq(status.by_type.TODO.symbol, " ")
  eq(status.by_type.DONE.symbol, "x")
  eq(status.by_type.IN_PROGRESS.symbol, "/")
  eq(status.by_type.CANCELLED.symbol, "-")
  eq(status.by_type.ON_HOLD.symbol, "h")
end

T["is_completed: DONE and CANCELLED are both completed"] = function()
  reset()
  eq(status.is_completed("x"), true)
  eq(status.is_completed("-"), true)
end

T["is_completed: TODO, IN_PROGRESS, ON_HOLD are NOT completed"] = function()
  reset()
  eq(status.is_completed(" "), false)
  eq(status.is_completed("/"), false)
  eq(status.is_completed("h"), false)
end

T["is_completed: unknown symbol → false"] = function()
  reset()
  eq(status.is_completed("?"), false)
end

T["merge: override existing symbol's next char"] = function()
  status.merge({ [" "] = { next = "/" } }) -- TODO now cycles to IN_PROGRESS, not DONE
  eq(status.next(" "), "/")
  reset() -- restore defaults
end

T["merge: add new custom status symbol"] = function()
  status.merge({ ["?"] = { name = "Question", next = " ", type = "TODO" } })
  eq(status.by_symbol["?"].name, "Question")
  eq(status.next("?"), " ")
  reset()
end

T["merge: is idempotent (calling twice with same opts is safe)"] = function()
  status.merge({ ["?"] = { name = "Question", next = " ", type = "TODO" } })
  status.merge({ ["?"] = { name = "Question", next = " ", type = "TODO" } })
  eq(status.by_symbol["?"].name, "Question")
  eq(#status.statuses, 6) -- 5 defaults + 1 custom, NOT 5 + 2
  reset()
end

T["cycle: next(' ') is 'x' by default (Todo → Done)"] = function()
  reset()
  eq(status.next(" "), "x")
end

T["cycle: unknown symbol returned unchanged"] = function()
  reset()
  eq(status.next("?"), "?")
end

return T
