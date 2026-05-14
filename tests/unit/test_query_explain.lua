-- tests/unit/test_query_explain.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Explain/{Explainer,Explanation}.test.ts
--
-- `explain` is a query block keyword.  When present, the result carries an
-- explain=true flag and the renderer prepends a human-readable summary of
-- the parsed query (filters + sort + group + limit) above the result list.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local qp = require("obsidian-tasks.query.parse")

T["parse: bare 'explain' line sets ast.explain = true"] = function()
  local ast = qp.parse("explain")
  eq(ast.explain, true)
end

T["parse: missing 'explain' line leaves ast.explain = false"] = function()
  local ast = qp.parse("not done")
  eq(ast.explain, false)
end

T["parse: 'explain' coexists with other directives"] = function()
  local ast = qp.parse("not done\nexplain\nsort by due")
  eq(ast.explain, true)
  eq(#ast.filters, 1)
  eq(#ast.sort_by, 1)
end

T["run: result.explain forwarded from ast"] = function()
  local run_mod = require("obsidian-tasks.query.run")
  local ast = qp.parse("not done\nexplain")
  -- Mock index with no tasks.
  local idx = {
    tasks_in = function()
      return function()
        return nil
      end
    end,
  }
  local result = run_mod.run(ast, idx)
  eq(result.explain, true)
end

T["run: result.explain is false when ast.explain is false"] = function()
  local run_mod = require("obsidian-tasks.query.run")
  local idx = {
    tasks_in = function()
      return function()
        return nil
      end
    end,
  }
  local result = run_mod.run(qp.parse("not done"), idx)
  eq(result.explain, false)
end

return T
