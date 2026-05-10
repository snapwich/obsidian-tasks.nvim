-- tests/unit/test_render_foldtext.lua
-- Unit tests for render/foldtext.lua — the query-derived foldtext summarizer.
--
-- All tests exercise M.summarize(ast, count) directly; that function is a pure
-- function that takes a parsed query AST and a result count and returns a string.
-- The live M.foldtext() callback (reads v:foldstart, buffer lines, and the result
-- cache) is covered by tests/integration/test_folding.lua.

local T = MiniTest.new_set()

local foldtext = require("obsidian-tasks.render.foldtext")
local parse = require("obsidian-tasks.query.parse")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Build a minimal AST with no errors and the given filter nodes.
--- @param filters table[]  list of filter AST nodes
--- @return table
local function make_ast(filters)
  return {
    filters = filters or {},
    sort_by = {},
    group_by = {},
    limit = nil,
    hide = {},
    errors = {},
  }
end

--- Build a leaf node.
--- @param filter table  filter spec
--- @return table
local function leaf(filter)
  return { kind = "leaf", filter = filter }
end

--- Build an AND node.
local function and_node(left, right)
  return { kind = "and", children = { left, right } }
end

--- Build an OR node.
local function or_node(left, right)
  return { kind = "or", children = { left, right } }
end

--- Build a NOT node.
local function not_node(child)
  return { kind = "not", children = { child } }
end

-- ── Empty filter list ──────────────────────────────────────────────────────────

T["empty filter list → all tasks placeholder"] = function()
  local ast = make_ast({})
  eq(foldtext.summarize(ast, 0), "📋 all tasks  (0)")
end

T["empty filter list with non-zero count"] = function()
  local ast = make_ast({})
  eq(foldtext.summarize(ast, 7), "📋 all tasks  (7)")
end

-- ── Parse error fallback ───────────────────────────────────────────────────────

T["parse error → invalid query fallback"] = function()
  local ast = {
    filters = {},
    sort_by = {},
    group_by = {},
    limit = nil,
    hide = {},
    errors = { { kind = "parse_error", msg = "Unknown directive: bogus", line = 1 } },
  }
  -- count is ignored when there are errors
  eq(foldtext.summarize(ast, 42), "📋 invalid query")
end

T["multiple parse errors → invalid query"] = function()
  local ast = {
    filters = {},
    errors = { { kind = "parse_error", msg = "e1" }, { kind = "v2_feature", msg = "e2" } },
    sort_by = {},
    group_by = {},
    limit = nil,
    hide = {},
  }
  eq(foldtext.summarize(ast, 0), "📋 invalid query")
end

-- ── Single-filter queries ──────────────────────────────────────────────────────

T["single filter: not done"] = function()
  local ast = make_ast({ leaf({ type = "not_done" }) })
  eq(foldtext.summarize(ast, 3), "📋 not done  (3)")
end

T["single filter: done"] = function()
  local ast = make_ast({ leaf({ type = "done" }) })
  eq(foldtext.summarize(ast, 1), "📋 done  (1)")
end

T["single filter: priority is high"] = function()
  local ast = make_ast({ leaf({ type = "priority", operator = "is", value = "high" }) })
  eq(foldtext.summarize(ast, 2), "📋 priority is high  (2)")
end

T["single filter: priority above medium"] = function()
  local ast = make_ast({ leaf({ type = "priority", operator = "above", value = "medium" }) })
  eq(foldtext.summarize(ast, 0), "📋 priority above medium  (0)")
end

T["single filter: is recurring"] = function()
  local ast = make_ast({ leaf({ type = "is_recurring" }) })
  eq(foldtext.summarize(ast, 5), "📋 recurring  (5)")
end

T["single filter: is not recurring"] = function()
  local ast = make_ast({ leaf({ type = "is_not_recurring" }) })
  eq(foldtext.summarize(ast, 0), "📋 not recurring  (0)")
end

T["single filter: has due date"] = function()
  local ast = make_ast({ leaf({ type = "has_date", field = "due" }) })
  eq(foldtext.summarize(ast, 4), "📋 has due date  (4)")
end

T["single filter: no due date"] = function()
  local ast = make_ast({ leaf({ type = "no_date", field = "due" }) })
  eq(foldtext.summarize(ast, 0), "📋 no due date  (0)")
end

T["single filter: date on today"] = function()
  local today = os.date("%Y-%m-%d")
  local ast = make_ast({ leaf({ type = "date", field = "due", operator = "on", value = today }) })
  eq(foldtext.summarize(ast, 2), "📋 due on today  (2)")
end

T["single filter: date before tomorrow"] = function()
  local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)
  local ast = make_ast({ leaf({ type = "date", field = "scheduled", operator = "before", value = tomorrow }) })
  eq(foldtext.summarize(ast, 1), "📋 scheduled before tomorrow  (1)")
end

T["single filter: date on specific ISO date"] = function()
  local ast = make_ast({ leaf({ type = "date", field = "due", operator = "on", value = "2025-12-31" }) })
  eq(foldtext.summarize(ast, 0), "📋 due on 2025-12-31  (0)")
end

T["single filter: tag includes #next"] = function()
  local ast = make_ast({ leaf({ type = "tag", operator = "includes", value = "#next" }) })
  eq(foldtext.summarize(ast, 3), "📋 #next  (3)")
end

T["single filter: tag includes value without hash prefix"] = function()
  -- Parser stores value without '#' prefix; foldtext adds it.
  local ast = make_ast({ leaf({ type = "tag", operator = "includes", value = "next" }) })
  eq(foldtext.summarize(ast, 3), "📋 #next  (3)")
end

T["single filter: has tag"] = function()
  local ast = make_ast({ leaf({ type = "tag", operator = "has" }) })
  eq(foldtext.summarize(ast, 0), "📋 has tag  (0)")
end

T["single filter: no tag"] = function()
  local ast = make_ast({ leaf({ type = "tag", operator = "no" }) })
  eq(foldtext.summarize(ast, 0), "📋 no tag  (0)")
end

T["single filter: path includes"] = function()
  local ast = make_ast({ leaf({ type = "text", field = "path", operator = "includes", value = "work" }) })
  eq(foldtext.summarize(ast, 6), "📋 path includes work  (6)")
end

T["single filter: unknown type → angle-bracket fallback"] = function()
  local ast = make_ast({ leaf({ type = "some_future_filter" }) })
  eq(foldtext.summarize(ast, 0), "📋 <some_future_filter>  (0)")
end

T["single filter: exclude sub-items"] = function()
  local ast = make_ast({ leaf({ type = "exclude_sub_items" }) })
  eq(foldtext.summarize(ast, 2), "📋 exclude sub-items  (2)")
end

T["single filter: status name"] = function()
  local ast = make_ast({ leaf({ type = "status_name", operator = "is", value = "In Progress" }) })
  eq(foldtext.summarize(ast, 1), "📋 status In Progress  (1)")
end

-- ── Multi-filter queries ───────────────────────────────────────────────────────

T["multi-filter: two leaf filters joined with middle dot"] = function()
  local ast = make_ast({
    leaf({ type = "not_done" }),
    leaf({ type = "date", field = "due", operator = "on", value = os.date("%Y-%m-%d") }),
  })
  eq(foldtext.summarize(ast, 5), "📋 not done · due on today  (5)")
end

T["multi-filter: three leaf filters"] = function()
  local today = os.date("%Y-%m-%d")
  local ast = make_ast({
    leaf({ type = "not_done" }),
    leaf({ type = "date", field = "due", operator = "on", value = today }),
    leaf({ type = "tag", operator = "includes", value = "#next" }),
  })
  eq(foldtext.summarize(ast, 5), "📋 not done · due on today · #next  (5)")
end

T["AND node flattens both children into phrase list"] = function()
  local node = and_node(leaf({ type = "not_done" }), leaf({ type = "priority", operator = "is", value = "high" }))
  local ast = make_ast({ node })
  eq(foldtext.summarize(ast, 2), "📋 not done · priority is high  (2)")
end

T["OR node formats as 'A or B'"] = function()
  local node = or_node(leaf({ type = "done" }), leaf({ type = "priority", operator = "is", value = "high" }))
  local ast = make_ast({ node })
  eq(foldtext.summarize(ast, 3), "📋 done or priority is high  (3)")
end

T["NOT node wraps child in 'not (...)'"] = function()
  local node = not_node(leaf({ type = "done" }))
  local ast = make_ast({ node })
  eq(foldtext.summarize(ast, 1), "📋 not (done)  (1)")
end

-- ── Result count ───────────────────────────────────────────────────────────────

T["result count zero shows (0)"] = function()
  local ast = make_ast({ leaf({ type = "not_done" }) })
  eq(foldtext.summarize(ast, 0), "📋 not done  (0)")
end

T["result count large number"] = function()
  local ast = make_ast({ leaf({ type = "not_done" }) })
  eq(foldtext.summarize(ast, 999), "📋 not done  (999)")
end

-- ── round-trip: parse then summarize ─────────────────────────────────────────

T["round-trip: parse 'not done' query"] = function()
  local ast = parse.parse("not done")
  local result = foldtext.summarize(ast, 0)
  eq(result, "📋 not done  (0)")
end

T["round-trip: parse empty query → all tasks"] = function()
  local ast = parse.parse("")
  eq(foldtext.summarize(ast, 3), "📋 all tasks  (3)")
end

T["round-trip: parse invalid query line → invalid query"] = function()
  local ast = parse.parse("this is not a valid directive xyzzy")
  eq(foldtext.summarize(ast, 0), "📋 invalid query")
end

-- ── result count cache ────────────────────────────────────────────────────────

T["set_result_count and clear_buffer"] = function()
  -- Use a scratch buffer to test cache lifecycle.
  local bufnr = vim.api.nvim_create_buf(false, true)
  foldtext.set_result_count(bufnr, 0, 42)
  -- We can't directly inspect the cache, but clear_buffer must not error.
  foldtext.clear_buffer(bufnr)
  -- A second clear is also safe.
  foldtext.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
