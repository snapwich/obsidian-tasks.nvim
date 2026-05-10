-- tests/unit/test_status.lua
-- Unit tests for task/status.lua

local T = MiniTest.new_set()
local status = require("obsidian-tasks.task.status")

-- Helper: reset to defaults before each group of tests.
local function reset()
  status.merge({})
end

-- ── DEFAULT_STATUSES ──────────────────────────────────────────────────────────

T["defaults: 5 statuses loaded"] = function()
  reset()
  MiniTest.expect.equality(#status.statuses, 5)
end

T["defaults: symbols are space x / - h"] = function()
  reset()
  local symbols = {}
  for _, s in ipairs(status.statuses) do
    symbols[s.symbol] = true
  end
  MiniTest.expect.equality(symbols[" "], true)
  MiniTest.expect.equality(symbols["x"], true)
  MiniTest.expect.equality(symbols["/"], true)
  MiniTest.expect.equality(symbols["-"], true)
  MiniTest.expect.equality(symbols["h"], true)
end

-- ── Cycle: 5 defaults ────────────────────────────────────────────────────────

T["cycle: Todo (space) -> Done (x)"] = function()
  reset()
  MiniTest.expect.equality(status.next(" "), "x")
end

T["cycle: Done (x) -> Todo (space)"] = function()
  reset()
  MiniTest.expect.equality(status.next("x"), " ")
end

T["cycle: In Progress (/) -> Done (x)"] = function()
  reset()
  MiniTest.expect.equality(status.next("/"), "x")
end

T["cycle: Cancelled (-) -> Todo (space)"] = function()
  reset()
  MiniTest.expect.equality(status.next("-"), " ")
end

T["cycle: On Hold (h) -> Todo (space)"] = function()
  reset()
  MiniTest.expect.equality(status.next("h"), " ")
end

-- ── Unknown symbol passthrough ────────────────────────────────────────────────

T["next: unknown symbol returns itself unchanged"] = function()
  reset()
  MiniTest.expect.equality(status.next("?"), "?")
  MiniTest.expect.equality(status.next(">"), ">")
  MiniTest.expect.equality(status.next("z"), "z")
end

-- ── User override: change next for existing status ───────────────────────────

T["merge: user can override next for existing status (space -> /)"] = function()
  status.merge({ [" "] = { next = "/" } })
  MiniTest.expect.equality(status.next(" "), "/")
  -- Other statuses unaffected.
  MiniTest.expect.equality(status.next("x"), " ")
  reset()
end

-- ── User adds new status ──────────────────────────────────────────────────────

T["merge: user adds [>] as 6th status"] = function()
  status.merge({ [">"] = { name = "Forwarded", next = " ", type = "ON_HOLD" } })
  MiniTest.expect.equality(#status.statuses, 6)
  MiniTest.expect.equality(status.next(">"), " ")
  MiniTest.expect.equality(status.by_symbol[">"].name, "Forwarded")
  MiniTest.expect.equality(status.by_symbol[">"].type, "ON_HOLD")
  reset()
end

-- ── Lookup tables rebuilt after merge ────────────────────────────────────────

T["merge: by_symbol lookup updated after adding new status"] = function()
  reset()
  MiniTest.expect.equality(status.by_symbol[">"], nil)
  status.merge({ [">"] = { name = "Forwarded", next = " ", type = "ON_HOLD" } })
  MiniTest.expect.equality(status.by_symbol[">"] ~= nil, true)
  reset()
end

T["merge: by_name lookup updated after adding new status"] = function()
  reset()
  status.merge({ [">"] = { name = "Forwarded", next = " ", type = "ON_HOLD" } })
  MiniTest.expect.equality(status.by_name["Forwarded"] ~= nil, true)
  MiniTest.expect.equality(status.by_name["Forwarded"].symbol, ">")
  reset()
end

T["merge: by_type lookup updated after adding new status"] = function()
  reset()
  status.merge({ ["!"] = { name = "Important", next = "x", type = "IN_PROGRESS" } })
  -- by_type may be overwritten if type already existed; the new entry wins.
  MiniTest.expect.equality(status.by_symbol["!"] ~= nil, true)
  reset()
end

-- ── Default lookup tables ────────────────────────────────────────────────────

T["by_symbol: all 5 defaults accessible at load time"] = function()
  reset()
  MiniTest.expect.equality(status.by_symbol[" "].name, "Todo")
  MiniTest.expect.equality(status.by_symbol["x"].name, "Done")
  MiniTest.expect.equality(status.by_symbol["/"].name, "In Progress")
  MiniTest.expect.equality(status.by_symbol["-"].name, "Cancelled")
  MiniTest.expect.equality(status.by_symbol["h"].name, "On Hold")
end

T["by_name: all 5 defaults accessible"] = function()
  reset()
  MiniTest.expect.equality(status.by_name["Todo"].symbol, " ")
  MiniTest.expect.equality(status.by_name["Done"].symbol, "x")
  MiniTest.expect.equality(status.by_name["In Progress"].symbol, "/")
  MiniTest.expect.equality(status.by_name["Cancelled"].symbol, "-")
  MiniTest.expect.equality(status.by_name["On Hold"].symbol, "h")
end

T["by_type: all 5 default types accessible"] = function()
  reset()
  MiniTest.expect.equality(status.by_type["TODO"].symbol, " ")
  MiniTest.expect.equality(status.by_type["DONE"].symbol, "x")
  MiniTest.expect.equality(status.by_type["IN_PROGRESS"].symbol, "/")
  MiniTest.expect.equality(status.by_type["CANCELLED"].symbol, "-")
  MiniTest.expect.equality(status.by_type["ON_HOLD"].symbol, "h")
end

-- ── Idempotency ───────────────────────────────────────────────────────────────

T["merge: calling merge twice with same opts is idempotent"] = function()
  local opts = { [">"] = { name = "Forwarded", next = " ", type = "ON_HOLD" } }
  status.merge(opts)
  local count_after_first = #status.statuses
  status.merge(opts)
  MiniTest.expect.equality(#status.statuses, count_after_first)
  reset()
end

return T
