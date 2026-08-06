-- tests/unit/test_query_group_sort.lua
-- Tests for `# nvim: sort groups by <key> [reverse]` — the nvim-only magic
-- comment that orders GROUPS by their best member instead of by group name.
--
-- No upstream counterpart: upstream obsidian-tasks ignores every '#' line, so
-- the same query block still parses there (and orders groups alphabetically).
--
-- Covers query/parse.lua (the `# nvim:` namespace) and query/run.lua step 5
-- (hierarchical member ordering), plus the regression that group order stays
-- alphabetical when no directive is present.

local T = MiniTest.new_set()

local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local run_mod = require("obsidian-tasks.query.run")

-- ── helpers ────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Parse a task line into a Task object (must be a valid task line).
local function pt(line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  return t
end

--- Build a minimal mock index from a list of { task, path } items.
local function make_index(items)
  return {
    tasks_in = function(path_filter)
      local i = 0
      return function()
        while true do
          i = i + 1
          local item = items[i]
          if not item then
            return nil
          end
          if path_filter == nil or path_filter(item.path) then
            return item.task, item.path
          end
        end
      end
    end,
  }
end

--- Parse a query string and run it against an index.
local function run(query_str, index)
  local ast = qp.parse(query_str)
  return run_mod.run(ast, index)
end

--- Collect the ordered group names of a result.
local function names(result)
  local out = {}
  for i, g in ipairs(result.groups) do
    out[i] = g.name
  end
  return out
end

--- Collect the ordered task descriptions of one group.
local function descs(group)
  local out = {}
  for i, t in ipairs(group.tasks) do
    out[i] = t.description
  end
  return out
end

-- ── parsing ────────────────────────────────────────────────────────────────

local parse_tests = MiniTest.new_set()

parse_tests["directive populates sort_groups_by"] = function()
  local ast = qp.parse("group by filename\n# nvim: sort groups by priority")
  eq(#ast.errors, 0)
  eq(#ast.sort_groups_by, 1)
  eq(ast.sort_groups_by[1], { key = "priority", reverse = false })
end

parse_tests["reverse variant sets reverse"] = function()
  local ast = qp.parse("group by filename\n# nvim: sort groups by due reverse")
  eq(#ast.errors, 0)
  eq(#ast.sort_groups_by, 1)
  eq(ast.sort_groups_by[1], { key = "due", reverse = true })
end

parse_tests["repeated directives accumulate in order"] = function()
  local query = table.concat({
    "group by filename",
    "# nvim: sort groups by priority",
    "# nvim: sort groups by due reverse",
    "# nvim: sort groups by status",
  }, "\n")
  local ast = qp.parse(query)
  eq(#ast.errors, 0)
  eq(#ast.sort_groups_by, 3)
  eq(ast.sort_groups_by[1], { key = "priority", reverse = false })
  eq(ast.sort_groups_by[2], { key = "due", reverse = true })
  eq(ast.sort_groups_by[3], { key = "status", reverse = false })
end

parse_tests["directive text is case-insensitive"] = function()
  local ast = qp.parse("group by filename\n# NVIM: Sort Groups By Priority Reverse")
  eq(#ast.errors, 0)
  eq(ast.sort_groups_by[1], { key = "priority", reverse = true })
end

parse_tests["whitespace after # and after nvim: is flexible"] = function()
  local ast = qp.parse("group by filename\n#nvim:sort groups by priority")
  eq(#ast.errors, 0)
  eq(ast.sort_groups_by[1], { key = "priority", reverse = false })

  ast = qp.parse("group by filename\n#   nvim  :    sort groups by priority")
  eq(#ast.errors, 0)
  eq(ast.sort_groups_by[1], { key = "priority", reverse = false })
end

parse_tests["directive may appear before group by"] = function()
  local ast = qp.parse("# nvim: sort groups by priority\ngroup by filename")
  eq(#ast.errors, 0)
  eq(#ast.sort_groups_by, 1)
end

parse_tests["random and blocking keys are accepted"] = function()
  local ast = qp.parse("group by filename\n# nvim: sort groups by random\n# nvim: sort groups by blocking")
  eq(#ast.errors, 0)
  eq(ast.sort_groups_by[1], { key = "random", reverse = false })
  eq(ast.sort_groups_by[2], { key = "blocking", reverse = false })
end

parse_tests["sort_groups_by is always a table"] = function()
  eq(qp.parse("").sort_groups_by, {})
  eq(qp.parse("not done").sort_groups_by, {})
end

parse_tests["plain # comment is not an error"] = function()
  local ast = qp.parse("# just a note\nnot done\n# nvimble is not a directive")
  eq(#ast.errors, 0)
  eq(#ast.sort_groups_by, 0)
  eq(#ast.filters, 1)
end

parse_tests["plain # comment lines still count toward error line numbers"] = function()
  local ast = qp.parse("# comment\nnot done\nbad keyword here")
  eq(ast.errors[1].line, 3)
end

parse_tests["fatal: unknown sort key"] = function()
  local ast = qp.parse("group by filename\n# nvim: sort groups by nope")
  MiniTest.expect.equality(#ast.errors >= 1, true)
  eq(ast.errors[1].kind, "parse_error")
  eq(ast.errors[1].line, 2)
  eq(#ast.sort_groups_by, 0)
end

parse_tests["fatal: unparseable # nvim: line"] = function()
  local ast = qp.parse("group by filename\n# nvim: note to self")
  MiniTest.expect.equality(#ast.errors >= 1, true)
  eq(ast.errors[1].kind, "parse_error")
  eq(ast.errors[1].line, 2)
end

parse_tests["fatal: directive with no group by"] = function()
  local ast = qp.parse("not done\n# nvim: sort groups by priority")
  MiniTest.expect.equality(#ast.errors >= 1, true)
  eq(ast.errors[1].kind, "parse_error")
  eq(ast.errors[1].line, 2)
end

parse_tests["fatal: no group by is checked after the whole block"] = function()
  -- `group by` may appear AFTER the comment, so the check must be a post-pass.
  local ast = qp.parse("# nvim: sort groups by priority\nnot done")
  MiniTest.expect.equality(#ast.errors >= 1, true)
  eq(ast.errors[1].kind, "parse_error")
  eq(ast.errors[1].line, 1)
end

parse_tests["bare (non-comment) sort groups by is still an unknown directive"] = function()
  local ast = qp.parse("group by filename\nsort groups by priority")
  MiniTest.expect.equality(#ast.errors >= 1, true)
  eq(ast.errors[1].kind, "parse_error")
  eq(#ast.sort_groups_by, 0)
end

parse_tests["sort by is unaffected by the new branch"] = function()
  local ast = qp.parse("sort by due\nsort by priority reverse")
  eq(#ast.errors, 0)
  eq(#ast.sort_groups_by, 0)
  eq(ast.sort_by[1], { key = "due", reverse = false })
  eq(ast.sort_by[2], { key = "priority", reverse = true })
end

T["parse"] = parse_tests

-- ── ordering ───────────────────────────────────────────────────────────────

local order_tests = MiniTest.new_set()

order_tests["group holding the top-priority task comes first"] = function()
  local idx = make_index({
    { task = pt("- [ ] low task 🔽"), path = "a.md" },
    { task = pt("- [ ] top task ⏫"), path = "z.md" },
  })
  local result = run("group by filename\n# nvim: sort groups by priority", idx)
  eq(names(result), { "z", "a" })
end

order_tests["reverse flips the group order"] = function()
  local idx = make_index({
    { task = pt("- [ ] low task 🔽"), path = "a.md" },
    { task = pt("- [ ] top task ⏫"), path = "z.md" },
  })
  local result = run("group by filename\n# nvim: sort groups by priority reverse", idx)
  eq(names(result), { "a", "z" })
end

order_tests["group order is independent of the task sort"] = function()
  local idx = make_index({
    { task = pt("- [ ] a-only 🔽 📅 2024-01-01"), path = "a.md" },
    { task = pt("- [ ] z-late ⏫ 📅 2024-03-01"), path = "z.md" },
    { task = pt("- [ ] z-early 📅 2024-02-01"), path = "z.md" },
  })
  local result = run("sort by due\ngroup by filename\n# nvim: sort groups by priority", idx)
  -- Groups by best priority…
  eq(names(result), { "z", "a" })
  -- …while tasks inside a group stay due-ordered.
  eq(descs(result.groups[1]), { "z-early", "z-late" })
end

order_tests["tie on the group chain falls through to the task sort chain"] = function()
  local idx = make_index({
    { task = pt("- [ ] alpha ⏫ 📅 2024-05-01"), path = "a.md" },
    { task = pt("- [ ] beta ⏫ 📅 2024-01-01"), path = "b.md" },
  })
  local result = run("sort by due\ngroup by filename\n# nvim: sort groups by priority", idx)
  -- Both groups peak at ⏫, so `sort by due` decides — not the group name.
  eq(names(result), { "b", "a" })
end

order_tests["tie on every chain falls back to alphabetical segment name"] = function()
  local idx = make_index({
    -- Index order puts "z" first, so a name-blind fallback would keep it there.
    { task = pt("- [ ] zed ⏫"), path = "z.md" },
    { task = pt("- [ ] ant ⏫"), path = "a.md" },
  })
  local result = run("group by filename\n# nvim: sort groups by priority", idx)
  eq(names(result), { "a", "z" })
end

order_tests["representative is the chain-best member, not the first one indexed"] = function()
  -- Both files peak at ⏫, so `sort by due` decides.  a.md holds the earliest
  -- due date of any top-priority task, so a.md must lead — whichever of its
  -- tasks the index emits first.
  local a_late = { task = pt("- [ ] a-late ⏫ 📅 2026-01-01"), path = "a.md" }
  local a_early = { task = pt("- [ ] a-early ⏫ 📅 2025-01-01"), path = "a.md" }
  local b_mid = { task = pt("- [ ] b-mid ⏫ 📅 2025-06-01"), path = "b.md" }
  local query = "sort by due\ngroup by filename\n# nvim: sort groups by priority"

  eq(names(run(query, make_index({ a_late, a_early, b_mid }))), { "a", "b" })
  -- Same tasks, different index emission order → same group order.
  eq(names(run(query, make_index({ a_early, a_late, b_mid }))), { "a", "b" })
  eq(names(run(query, make_index({ b_mid, a_late, a_early }))), { "a", "b" })
end

order_tests["reverse flips the order for multi-task groups too"] = function()
  -- The 'best' member is picked WITHOUT `reverse` (a.md peaks at ⏫), then
  -- `reverse` is applied once when the representatives are compared.
  local items = {
    { task = pt("- [ ] a-high ⏫"), path = "a.md" },
    { task = pt("- [ ] a-low 🔽"), path = "a.md" },
    { task = pt("- [ ] b-med 🔼"), path = "b.md" },
  }
  eq(names(run("group by filename\n# nvim: sort groups by priority", make_index(items))), { "a", "b" })
  eq(names(run("group by filename\n# nvim: sort groups by priority reverse", make_index(items))), { "b", "a" })
end

order_tests["cohort ties fall through to the task sort chain"] = function()
  -- Folder x and folder y both peak at ⏫; x's best ⏫ is due 2030 and y's is
  -- due 2040, so `sort by due` must put x first even though the first group
  -- created inside x (x / a) holds a later ⏫.
  local idx = make_index({
    { task = pt("- [ ] xa-low 🔽 📅 2020-01-01"), path = "x/a.md" },
    { task = pt("- [ ] xb ⏫ 📅 2030-01-01"), path = "x/b.md" },
    { task = pt("- [ ] xa-hi ⏫ 📅 2050-01-01"), path = "x/a.md" },
    { task = pt("- [ ] yc ⏫ 📅 2040-01-01"), path = "y/c.md" },
  })
  local result = run("sort by due\ngroup by folder\ngroup by filename\n# nvim: sort groups by priority", idx)
  eq(names(result), { "x / b", "x / a", "y / c" })
end

order_tests["multi-key group by keeps folder cohorts contiguous"] = function()
  local idx = make_index({
    { task = pt("- [ ] ax ⏫"), path = "aaa/x.md" },
    { task = pt("- [ ] ay 🔽"), path = "aaa/y.md" },
    { task = pt("- [ ] zb 🔼"), path = "zzz/b.md" },
    { task = pt("- [ ] zq 🔺"), path = "zzz/q.md" },
  })
  local result = run("group by folder\ngroup by filename\n# nvim: sort groups by priority", idx)
  -- zzz wins level 1 (it holds 🔺); inside each folder, filenames order by
  -- their own best member.
  eq(names(result), { "zzz / q", "zzz / b", "aaa / x", "aaa / y" })
end

order_tests["reverse on the second group key flips only that level"] = function()
  local idx = make_index({
    { task = pt("- [ ] ax ⏫"), path = "aaa/x.md" },
    { task = pt("- [ ] ay 🔽"), path = "aaa/y.md" },
    { task = pt("- [ ] zb 🔼"), path = "zzz/b.md" },
    { task = pt("- [ ] zq 🔺"), path = "zzz/q.md" },
  })
  local result = run("group by folder\ngroup by filename reverse\n# nvim: sort groups by priority", idx)
  eq(names(result), { "zzz / b", "zzz / q", "aaa / y", "aaa / x" })
end

order_tests["reverse on the first group key flips only that level"] = function()
  local idx = make_index({
    { task = pt("- [ ] ax ⏫"), path = "aaa/x.md" },
    { task = pt("- [ ] ay 🔽"), path = "aaa/y.md" },
    { task = pt("- [ ] zb 🔼"), path = "zzz/b.md" },
    { task = pt("- [ ] zq 🔺"), path = "zzz/q.md" },
  })
  local result = run("group by folder reverse\ngroup by filename\n# nvim: sort groups by priority", idx)
  eq(names(result), { "aaa / x", "aaa / y", "zzz / q", "zzz / b" })
end

order_tests["a group name containing ' / ' stays one segment"] = function()
  -- `heading` values legitimately contain the same " / " that joins levels, so
  -- ordering must walk the segment arrays, never re-split the joined name.
  local function with_heading(line, heading)
    local t = pt(line)
    t.heading = heading
    return t
  end
  local idx = make_index({
    { task = with_heading("- [ ] alpha 🔼", "## Alpha"), path = "n3.md" },
    { task = with_heading("- [ ] build-hi ⏫", "## Design / Build"), path = "n1.md" },
    { task = with_heading("- [ ] build-lo 🔽", "## Design / Build"), path = "n2.md" },
  })
  local result = run("group by heading\ngroup by filename\n# nvim: sort groups by priority", idx)
  eq(names(result), {
    "## Design / Build / n1",
    "## Design / Build / n2",
    "## Alpha / n3",
  })
end

order_tests["parse_error from a bad directive suppresses all results"] = function()
  local idx = make_index({
    { task = pt("- [ ] anything ⏫"), path = "a.md" },
  })
  local result = run("group by filename\n# nvim: sort groups by nope", idx)
  eq(result.total, 0)
  eq(#result.groups, 0)
  MiniTest.expect.equality(#result.errors >= 1, true)
end

order_tests["header_summary reports the group ordering"] = function()
  local idx = make_index({})
  local result = run("group by filename\n# nvim: sort groups by priority", idx)
  -- Ascending is the default and stays unmarked.
  MiniTest.expect.equality(result.header_summary:find("groups sorted by priority", 1, true) ~= nil, true)
  eq(result.header_summary:find("groups sorted by priority asc", 1, true), nil)

  result = run("group by filename\n# nvim: sort groups by priority reverse", idx)
  MiniTest.expect.equality(result.header_summary:find("groups sorted by priority desc", 1, true) ~= nil, true)
end

order_tests["header_summary omits group ordering when not requested"] = function()
  local idx = make_index({})
  local result = run("group by filename", idx)
  eq(result.header_summary:find("groups sorted by"), nil)
end

T["order"] = order_tests

-- ── regression: default path is untouched ──────────────────────────────────

local default_tests = MiniTest.new_set()

default_tests["no directive: groups stay alphabetical"] = function()
  local idx = make_index({
    { task = pt("- [ ] zed ⏫"), path = "z.md" },
    { task = pt("- [ ] ant 🔽"), path = "a.md" },
  })
  local result = run("group by filename", idx)
  eq(names(result), { "a", "z" })
end

default_tests["no directive: group by X reverse still reverses"] = function()
  local idx = make_index({
    { task = pt("- [ ] ant 🔽"), path = "a.md" },
    { task = pt("- [ ] zed ⏫"), path = "z.md" },
  })
  local result = run("group by filename reverse", idx)
  eq(names(result), { "z", "a" })
end

default_tests["no directive: multi-key reverse keeps first-key-only semantics"] = function()
  -- Without the directive, `reverse` on the FIRST key flips the whole flat
  -- alphabetical list — the historical behaviour, deliberately unlike the
  -- per-level reverse the directive enables.
  local idx = make_index({
    { task = pt("- [ ] ax ⏫"), path = "aaa/x.md" },
    { task = pt("- [ ] ay 🔽"), path = "aaa/y.md" },
    { task = pt("- [ ] zb 🔼"), path = "zzz/b.md" },
    { task = pt("- [ ] zq 🔺"), path = "zzz/q.md" },
  })
  local result = run("group by folder reverse\ngroup by filename", idx)
  eq(names(result), { "zzz / q", "zzz / b", "aaa / y", "aaa / x" })
end

default_tests["no directive: ungrouped query still yields one unnamed group"] = function()
  local idx = make_index({
    { task = pt("- [ ] one"), path = "a.md" },
    { task = pt("- [ ] two"), path = "b.md" },
  })
  local result = run("not done", idx)
  eq(#result.groups, 1)
  eq(result.groups[1].name, "")
  eq(result.total, 2)
end

T["default"] = default_tests

return T
