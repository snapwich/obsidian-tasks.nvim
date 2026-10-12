-- tests/unit/test_global_filter_insert.lua
-- Plan D6 (group-top insert, step 1): every task line that a dashboard insert
-- writes to its source note must carry the global filter in its DESCRIPTION.
-- The index drops a task whose description lacks the global filter
-- (index/init.lua make_on_task), so without it the new task vanishes from the
-- dashboard on the next rerender.
--
-- edit_util.ensure_global_filter(line, global_filter) is pure: it puts the
-- filter at the end of the description (before the first emoji / dataview
-- field), and does nothing to a description bullet or when the filter is
-- already in the description.

local T = MiniTest.new_set()

local ensure = require("obsidian-tasks.render.edit_util").ensure_global_filter

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

T["global_filter: nil filter leaves the line unchanged"] = function()
  eq(ensure("- [ ] foo", nil), "- [ ] foo")
end

T["global_filter: empty filter leaves the line unchanged"] = function()
  eq(ensure("- [ ] foo", ""), "- [ ] foo")
end

T["global_filter: bare task gets the filter appended"] = function()
  eq(ensure("- [ ] foo", "#task"), "- [ ] foo #task")
end

T["global_filter: filter already in the description is not duplicated"] = function()
  eq(ensure("- [ ] foo #task bar", "#task"), "- [ ] foo #task bar")
end

T["global_filter: indented task keeps its indent"] = function()
  eq(ensure("    - [ ] child", "#task"), "    - [ ] child #task")
end

T["global_filter: goes before the first emoji field"] = function()
  eq(ensure("- [ ] foo 📅 2026-10-12", "#task"), "- [ ] foo #task 📅 2026-10-12")
end

T["global_filter: goes before the first dataview field"] = function()
  eq(ensure("- [ ] foo [due:: 2026-10-12]", "#task"), "- [ ] foo #task [due:: 2026-10-12]")
end

T["global_filter: filter only after a field is not in the description, so it is added"] = function()
  -- The parser's description stops at the first field, so a trailing "#task"
  -- does not satisfy the index's global-filter check.
  eq(ensure("- [ ] foo 📅 2026-10-12 #task", "#task"), "- [ ] foo #task 📅 2026-10-12 #task")
end

T["global_filter: empty description gets the filter as its description"] = function()
  eq(ensure("- [ ] ", "#task"), "- [ ] #task")
end

T["global_filter: field-only task gets the filter before the field"] = function()
  eq(ensure("- [ ] 📅 2026-10-12", "#task"), "- [ ] #task 📅 2026-10-12")
end

T["global_filter: non-default checkbox and marker are kept"] = function()
  eq(ensure("* [/] doing", "#task"), "* [/] doing #task")
end

T["global_filter: description bullet (no checkbox) is not a task — unchanged"] = function()
  eq(ensure("  - a note", "#task"), "  - a note")
end

T["global_filter: plain string match, not a Lua pattern"] = function()
  -- "a.b" as a Lua pattern would match "axb"; as a plain string it does not.
  eq(ensure("- [ ] axb", "a.b"), "- [ ] axb a.b")
  eq(ensure("- [ ] has a.b in it", "a.b"), "- [ ] has a.b in it")
end

T["global_filter: result parses with the filter in its description"] = function()
  local parse = require("obsidian-tasks.task.parse")
  for _, line in ipairs({
    "- [ ] foo",
    "- [ ] foo 📅 2026-10-12 ⏫",
    "- [ ] foo [priority:: high]",
    "- [ ] ",
  }) do
    local t = parse.parse(ensure(line, "#task"))
    eq(t ~= nil, true, "must stay a task: " .. line)
    eq(t.description:find("#task", 1, true) ~= nil, true, "filter must be in description: " .. line)
  end
end

return T
