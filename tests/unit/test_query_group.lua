-- tests/unit/test_query_group.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Group/{Grouper,TaskGroups,GroupingTreeNode}.test.ts
--
-- Coverage in test_query_run.lua's `group_tests` sub-set already mirrors most
-- of upstream's basic group_by behaviour.  This file adds upstream-specific
-- edge cases: empty input, tasks-in-multiple-groups expansion, nested
-- multi-key grouping, no-name fallback.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local group_mod = require("obsidian-tasks.query.group")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

-- ── Single task with multiple tags → expands into one entry per tag ──────

T["multi-tag task expands into N group names when grouping by tag"] = function()
  local t = pt("- [ ] Task #work #urgent #personal")
  local names = group_mod.resolve(t, "/v/note.md", { { key = "tags", reverse = false } })
  eq(#names, 3)
  local set = {}
  for _, n in ipairs(names) do
    set[n] = true
  end
  eq(set["#work"], true)
  eq(set["#urgent"], true)
  eq(set["#personal"], true)
end

T["no-tag task in tag grouping → 'No tags' fallback"] = function()
  local t = pt("- [ ] Untagged task")
  local names = group_mod.resolve(t, "/v/note.md", { { key = "tags", reverse = false } })
  eq(#names, 1)
  eq(names[1], "No tags")
end

-- ── No-date fallback labels ──────────────────────────────────────────────

T["group by due: no-due fallback is 'No date'"] = function()
  local t = pt("- [ ] No due task")
  local names = group_mod.resolve(t, "/v/note.md", { { key = "due", reverse = false } })
  eq(names[1], "No date")
end

T["group by scheduled: no-scheduled fallback is 'No date'"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "/v/note.md", { { key = "scheduled", reverse = false } })
  eq(names[1], "No date")
end

T["group by recurrence: no-recurrence fallback is 'None'"] = function()
  local t = pt("- [ ] One-off")
  local names = group_mod.resolve(t, "/v/note.md", { { key = "recurrence", reverse = false } })
  eq(names[1], "None")
end

-- ── Multi-key grouping with tag expansion ────────────────────────────────

T["status + tags: cartesian product of buckets and per-tag entries"] = function()
  local t = pt("- [ ] Task #a #b")
  local names = group_mod.resolve(t, "/v/note.md", {
    { key = "status", reverse = false },
    { key = "tags", reverse = false },
  })
  eq(#names, 2)
  local set = {}
  for _, n in ipairs(names) do
    set[n] = true
  end
  eq(set["Todo / #a"], true)
  eq(set["Todo / #b"], true)
end

T["priority + status: scalar × scalar yields one entry"] = function()
  local t = pt("- [ ] Task ⏫")
  local names = group_mod.resolve(t, "/v/note.md", {
    { key = "priority", reverse = false },
    { key = "status", reverse = false },
  })
  eq(#names, 1)
  eq(names[1], "Priority 2: High / Todo")
end

-- ── Empty / unknown keys ─────────────────────────────────────────────────

T["no group_by directives: single empty-string group bucket"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "/v/note.md", {})
  eq(#names, 1)
  eq(names[1], "")
end

return T
