-- tests/unit/test_query_run.lua
-- Tests for query/filter.lua, query/sort.lua, query/group.lua,
-- query/hide.lua, and query/run.lua.
--
-- Unit tests use synthetic task objects created via task/parse.lua.
-- Integration tests use a stub index seeded from fixture vault files.

local T = MiniTest.new_set()

local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")
local sort_mod = require("obsidian-tasks.query.sort")
local group_mod = require("obsidian-tasks.query.group")
local hide_mod = require("obsidian-tasks.query.hide")
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

-- ── filter.lua unit tests ──────────────────────────────────────────────────

local filter_tests = MiniTest.new_set()

--- Compile a single-line filter and test it against a task + path.
local function matches(filter_line, task, path)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, path or "/vault/note.md")
end

-- Status filters --

filter_tests["done: matches task with x status symbol"] = function()
  local t = pt("- [x] Finished task ✅ 2024-01-01")
  eq(matches("done", t), true)
end

filter_tests["done: does not match open task"] = function()
  local t = pt("- [ ] Open task")
  eq(matches("done", t), false)
end

filter_tests["not done: matches open task"] = function()
  local t = pt("- [ ] Open task")
  eq(matches("not done", t), true)
end

filter_tests["not done: does not match done task"] = function()
  local t = pt("- [x] Done task ✅ 2024-01-01")
  eq(matches("not done", t), false)
end

filter_tests["status.name is Todo: matches space symbol"] = function()
  local t = pt("- [ ] My task")
  eq(matches("status.name is Todo", t), true)
end

filter_tests["status.name is Done: matches x symbol"] = function()
  local t = pt("- [x] Done ✅ 2024-01-01")
  eq(matches("status.name is Done", t), true)
end

filter_tests["status.type is TODO: matches space symbol"] = function()
  local t = pt("- [ ] Open task")
  eq(matches("status.type is TODO", t), true)
end

filter_tests["status.type is DONE: matches x symbol"] = function()
  local t = pt("- [x] Done task ✅ 2024-01-01")
  eq(matches("status.type is DONE", t), true)
end

-- Recurring filters --

filter_tests["is recurring: true when recurrence field set"] = function()
  local t = pt("- [ ] Recurring task 🔁 every day")
  eq(matches("is recurring", t), true)
end

filter_tests["is recurring: false when no recurrence"] = function()
  local t = pt("- [ ] Plain task")
  eq(matches("is recurring", t), false)
end

filter_tests["is not recurring: true when no recurrence field"] = function()
  local t = pt("- [ ] Plain task")
  eq(matches("is not recurring", t), true)
end

filter_tests["is not recurring: false when recurrence set"] = function()
  local t = pt("- [ ] Recurring 🔁 every week")
  eq(matches("is not recurring", t), false)
end

-- Priority filters --

filter_tests["priority is highest: matches 🔺"] = function()
  local t = pt("- [ ] High priority task 🔺")
  eq(matches("priority is highest", t), true)
end

filter_tests["priority is high: matches ⏫"] = function()
  local t = pt("- [ ] High task ⏫")
  eq(matches("priority is high", t), true)
end

filter_tests["priority is none: matches task with no priority"] = function()
  local t = pt("- [ ] No priority task")
  eq(matches("priority is none", t), true)
end

filter_tests["priority above low: matches medium priority"] = function()
  local t = pt("- [ ] Medium task 🔼")
  eq(matches("priority above low", t), true)
end

filter_tests["priority above low: does not match low priority"] = function()
  local t = pt("- [ ] Low task 🔽")
  eq(matches("priority above low", t), false)
end

filter_tests["priority below medium: matches low priority"] = function()
  local t = pt("- [ ] Low task 🔽")
  eq(matches("priority below medium", t), true)
end

filter_tests["priority below medium: does not match high priority"] = function()
  local t = pt("- [ ] High task ⏫")
  eq(matches("priority below medium", t), false)
end

filter_tests["priority not is low: matches medium"] = function()
  local t = pt("- [ ] Medium task 🔼")
  eq(matches("priority not is low", t), true)
end

filter_tests["priority not is low: false for low"] = function()
  local t = pt("- [ ] Low task 🔽")
  eq(matches("priority not is low", t), false)
end

-- Date filters --

filter_tests["has due date: true when due set"] = function()
  local t = pt("- [ ] Task with due 📅 2024-01-15")
  eq(matches("has due date", t), true)
end

filter_tests["has due date: false when no due"] = function()
  local t = pt("- [ ] Task without due")
  eq(matches("has due date", t), false)
end

filter_tests["no due date: true when no due"] = function()
  local t = pt("- [ ] No due task")
  eq(matches("no due date", t), true)
end

filter_tests["no due date: false when due set"] = function()
  local t = pt("- [ ] Task 📅 2024-01-15")
  eq(matches("no due date", t), false)
end

filter_tests["due before 2099-01-01: matches past due date"] = function()
  local t = pt("- [ ] Task 📅 2024-01-15")
  eq(matches("due before 2099-01-01", t), true)
end

filter_tests["due before 2024-01-01: false for later due date"] = function()
  local t = pt("- [ ] Task 📅 2024-06-01")
  eq(matches("due before 2024-01-01", t), false)
end

filter_tests["due after 2020-01-01: matches 2024 date"] = function()
  local t = pt("- [ ] Task 📅 2024-01-15")
  eq(matches("due after 2020-01-01", t), true)
end

filter_tests["due on 2024-01-15: matches exact date"] = function()
  local t = pt("- [ ] Task 📅 2024-01-15")
  eq(matches("due on 2024-01-15", t), true)
end

filter_tests["due on 2024-01-15: false for different date"] = function()
  local t = pt("- [ ] Task 📅 2024-01-16")
  eq(matches("due on 2024-01-15", t), false)
end

filter_tests["due before X: false when task has no due date (filter-fail)"] = function()
  local t = pt("- [ ] No due task")
  -- run-time error: task has no due date → treated as filter-fail
  eq(matches("due before 2099-01-01", t), false)
end

filter_tests["has scheduled date: true when scheduled set"] = function()
  local t = pt("- [ ] Scheduled task ⏳ 2024-02-01")
  eq(matches("has scheduled date", t), true)
end

filter_tests["has start date: true when start set"] = function()
  local t = pt("- [ ] Started 🛫 2024-03-01")
  eq(matches("has start date", t), true)
end

filter_tests["date_invalid: true when date is not ISO"] = function()
  local t = pt("- [ ] Broken date")
  -- Manually set a broken date field
  t.fields.due = "not-a-date"
  local ast = qp.parse("due date is invalid")
  local pred = filter_mod.compile_all(ast.filters)
  eq(pred(t, "/vault/note.md"), true)
end

filter_tests["date_invalid: false when date is valid ISO"] = function()
  local t = pt("- [ ] Task 📅 2024-01-15")
  local ast = qp.parse("due date is invalid")
  local pred = filter_mod.compile_all(ast.filters)
  eq(pred(t, "/vault/note.md"), false)
end

-- Text field filters --

filter_tests["path includes: matches when path contains value"] = function()
  local t = pt("- [ ] My task")
  eq(matches("path includes vault", t, "/home/user/vault/note.md"), true)
end

filter_tests["path includes: false when path does not contain value"] = function()
  local t = pt("- [ ] My task")
  eq(matches("path includes archive", t, "/home/user/vault/note.md"), false)
end

filter_tests["path does not include: true when path lacks value"] = function()
  local t = pt("- [ ] My task")
  eq(matches("path does not include archive", t, "/home/user/vault/note.md"), true)
end

filter_tests["description includes: matches substring"] = function()
  local t = pt("- [ ] Buy milk and eggs")
  eq(matches("description includes milk", t), true)
end

filter_tests["description includes: case insensitive"] = function()
  local t = pt("- [ ] Buy Milk Today")
  eq(matches("description includes milk", t), true)
end

filter_tests["description does not include: true when absent"] = function()
  local t = pt("- [ ] Buy bread")
  eq(matches("description does not include milk", t), true)
end

filter_tests["filename includes: matches file basename"] = function()
  local t = pt("- [ ] My task")
  eq(matches("filename includes note.md", t, "/vault/note.md"), true)
end

filter_tests["folder includes: matches directory portion"] = function()
  local t = pt("- [ ] My task")
  eq(matches("folder includes inbox", t, "/vault/inbox/note.md"), true)
end

filter_tests["root includes: matches first subfolder in vault"] = function()
  local t = pt("- [ ] My task")
  -- vault-relative `sub/note.md` → root = "sub"
  eq(matches("root includes sub", t, "sub/note.md"), true)
end

filter_tests["root includes: false when file directly in vault (no subfolder)"] = function()
  local t = pt("- [ ] My task")
  -- vault-relative `note.md` → root = "" → does not include "sub"
  eq(matches("root includes sub", t, "note.md"), false)
end

filter_tests["root includes: nested path returns first subfolder only"] = function()
  local t = pt("- [ ] My task")
  -- vault-relative `a/b/note.md` → root = "a", not "b"
  eq(matches("root includes a", t, "a/b/note.md"), true)
  eq(matches("root includes b", t, "a/b/note.md"), false)
end

-- Tag filters --

filter_tests["tag includes: matches tag substring"] = function()
  local t = pt("- [ ] My task #work/project")
  eq(matches("tag includes #work", t), true)
end

filter_tests["tag includes: false when no matching tag"] = function()
  local t = pt("- [ ] My task #personal")
  eq(matches("tag includes #work", t), false)
end

filter_tests["has tag: true when task has at least one tag"] = function()
  local t = pt("- [ ] Tagged task #foo")
  eq(matches("has tag", t), true)
end

filter_tests["has tag: false when task has no tags"] = function()
  local t = pt("- [ ] No tags task")
  eq(matches("has tag", t), false)
end

filter_tests["no tag: true when task has no tags"] = function()
  local t = pt("- [ ] Untagged task")
  eq(matches("no tag", t), true)
end

filter_tests["no tag: false when task has tags"] = function()
  local t = pt("- [ ] Task #foo")
  eq(matches("no tag", t), false)
end

filter_tests["tag does not include: true when tag absent"] = function()
  local t = pt("- [ ] Task #personal")
  eq(matches("tag does not include #work", t), true)
end

filter_tests["tag does not include: false when tag present"] = function()
  local t = pt("- [ ] Task #work")
  eq(matches("tag does not include #work", t), false)
end

-- Misc filters --

filter_tests["exclude sub-items: true for top-level task"] = function()
  local t = pt("- [ ] Top level task")
  eq(matches("exclude sub-items", t), true)
end

filter_tests["exclude sub-items: false for indented task"] = function()
  local t = pt("  - [ ] Indented task")
  eq(matches("exclude sub-items", t), false)
end

filter_tests["random: always true"] = function()
  local t = pt("- [ ] Any task")
  eq(matches("random", t), true)
end

-- Boolean combinators --

filter_tests["and: both true → true"] = function()
  local t = pt("- [ ] Task with due 📅 2024-01-15")
  eq(matches("(not done and has due date)", t), true)
end

filter_tests["and: one false → false"] = function()
  local t = pt("- [x] Done with due 📅 2024-01-15 ✅ 2024-01-10")
  eq(matches("(not done and has due date)", t), false)
end

filter_tests["or: either true → true"] = function()
  local t = pt("- [ ] Open no due")
  eq(matches("(not done or has due date)", t), true)
end

filter_tests["or: first true second false → true"] = function()
  local t = pt("- [x] Done no due ✅ 2024-01-10")
  -- done=true, has due date=false → OR → true
  eq(matches("(done or has due date)", t), true)
end

filter_tests["or: both false → false"] = function()
  -- open task, no due date → done=false, has due date=false → OR → false
  local t = pt("- [ ] Open no due")
  eq(matches("(done or has due date)", t), false)
end

filter_tests["not: negates match"] = function()
  local t = pt("- [x] Done ✅ 2024-01-10")
  eq(matches("not (done)", t), false)
end

filter_tests["compile_all: empty node list → always true"] = function()
  local t = pt("- [ ] Any task")
  local pred = filter_mod.compile_all({})
  eq(pred(t, "/vault/note.md"), true)
end

T["filter"] = filter_tests

-- ── sort.lua unit tests ────────────────────────────────────────────────────

local sort_tests = MiniTest.new_set()

--- Wrap items for sort (run.lua assigns _idx, we do it here for tests).
local function wrap(items)
  local wrapped = {}
  for i, item in ipairs(items) do
    wrapped[i] = { task = item.task, path = item.path or "/vault/note.md", _idx = i }
  end
  return wrapped
end

sort_tests["sort by due asc: earlier dates first"] = function()
  local items = wrap({
    { task = pt("- [ ] Task B 📅 2024-03-01") },
    { task = pt("- [ ] Task A 📅 2024-01-01") },
    { task = pt("- [ ] Task C 📅 2024-06-01") },
  })
  local cmp = sort_mod.make_comparator({ { key = "due", reverse = false } })
  table.sort(items, cmp)
  -- Compare by due date field (description is "Task A"/"Task B"/"Task C" — emoji stripped)
  eq(items[1].task.fields.due, "2024-01-01")
  eq(items[2].task.fields.due, "2024-03-01")
  eq(items[3].task.fields.due, "2024-06-01")
end

sort_tests["sort by due desc: later dates first (reverse)"] = function()
  local items = wrap({
    { task = pt("- [ ] Task A 📅 2024-01-01") },
    { task = pt("- [ ] Task B 📅 2024-03-01") },
    { task = pt("- [ ] Task C 📅 2024-06-01") },
  })
  local cmp = sort_mod.make_comparator({ { key = "due", reverse = true } })
  table.sort(items, cmp)
  eq(items[1].task.fields.due, "2024-06-01")
  eq(items[2].task.fields.due, "2024-03-01")
  eq(items[3].task.fields.due, "2024-01-01")
end

sort_tests["sort by priority desc (default): highest first"] = function()
  local items = wrap({
    { task = pt("- [ ] Low task 🔽") },
    { task = pt("- [ ] High task 🔺") },
    { task = pt("- [ ] Medium task 🔼") },
  })
  local cmp = sort_mod.make_comparator({ { key = "priority", reverse = false } })
  table.sort(items, cmp)
  -- highest priority first (6 > 4 > 3)
  eq(items[1].task.fields.priority, "highest")
  eq(items[2].task.fields.priority, "medium")
  eq(items[3].task.fields.priority, "low")
end

sort_tests["sort by priority reverse: lowest first"] = function()
  local items = wrap({
    { task = pt("- [ ] High task ⏫") },
    { task = pt("- [ ] Low task 🔽") },
  })
  local cmp = sort_mod.make_comparator({ { key = "priority", reverse = true } })
  table.sort(items, cmp)
  eq(items[1].task.fields.priority, "low")
  eq(items[2].task.fields.priority, "high")
end

sort_tests["sort by description asc: alphabetical"] = function()
  local items = wrap({
    { task = pt("- [ ] Banana task") },
    { task = pt("- [ ] Apple task") },
    { task = pt("- [ ] Cherry task") },
  })
  local cmp = sort_mod.make_comparator({ { key = "description", reverse = false } })
  table.sort(items, cmp)
  -- lower-cased comparison: apple < banana < cherry
  MiniTest.expect.equality(items[1].task.description:lower():sub(1, 5), "apple")
  MiniTest.expect.equality(items[2].task.description:lower():sub(1, 6), "banana")
  MiniTest.expect.equality(items[3].task.description:lower():sub(1, 6), "cherry")
end

sort_tests["sort by path asc: alphabetical by path"] = function()
  local items = wrap({
    { task = pt("- [ ] Task"), path = "/vault/z.md" },
    { task = pt("- [ ] Task"), path = "/vault/a.md" },
    { task = pt("- [ ] Task"), path = "/vault/m.md" },
  })
  local cmp = sort_mod.make_comparator({ { key = "path", reverse = false } })
  table.sort(items, cmp)
  eq(items[1].path, "/vault/a.md")
  eq(items[2].path, "/vault/m.md")
  eq(items[3].path, "/vault/z.md")
end

sort_tests["sort by root: first subfolder used, not last"] = function()
  -- Vault-relative paths: root is the first directory above the filename.
  local items = wrap({
    { task = pt("- [ ] Task"), path = "b/deep/note.md" },
    { task = pt("- [ ] Task"), path = "a/deep/note.md" },
    { task = pt("- [ ] Task"), path = "note.md" },
  })
  local cmp = sort_mod.make_comparator({ { key = "root", reverse = false } })
  table.sort(items, cmp)
  -- "" (no subfolder) < "a" < "b" lexicographically
  eq(items[1].path, "note.md") -- root = ""
  eq(items[2].path, "a/deep/note.md") -- root = "a"
  eq(items[3].path, "b/deep/note.md") -- root = "b"
end

sort_tests["no sort directives: stable (original idx order)"] = function()
  local items = wrap({
    { task = pt("- [ ] Third") },
    { task = pt("- [ ] First") },
    { task = pt("- [ ] Second") },
  })
  -- Assign specific _idx values to test stability
  items[1]._idx = 3
  items[2]._idx = 1
  items[3]._idx = 2
  local cmp = sort_mod.make_comparator({})
  table.sort(items, cmp)
  eq(items[1]._idx, 1)
  eq(items[2]._idx, 2)
  eq(items[3]._idx, 3)
end

sort_tests["multi-key sort: primary then secondary"] = function()
  -- All tasks same priority → secondary sort by due
  local items = wrap({
    { task = pt("- [ ] Task B ⏫ 📅 2024-03-01") },
    { task = pt("- [ ] Task A ⏫ 📅 2024-01-01") },
    { task = pt("- [ ] Task C 🔽 📅 2024-06-01") },
  })
  local cmp = sort_mod.make_comparator({
    { key = "priority", reverse = false },
    { key = "due", reverse = false },
  })
  table.sort(items, cmp)
  -- C has low priority → sorts after high (⏫)
  -- A and B are both high → sorted by due: A (01) before B (03)
  eq(items[1].task.fields.priority, "high") -- Task A
  eq(items[2].task.fields.priority, "high") -- Task B
  eq(items[3].task.fields.priority, "low") -- Task C
  eq(items[1].task.fields.due, "2024-01-01")
  eq(items[2].task.fields.due, "2024-03-01")
end

sort_tests["tasks with no due date sort after tasks with due date"] = function()
  local items = wrap({
    { task = pt("- [ ] No due") },
    { task = pt("- [ ] Has due 📅 2024-01-01") },
  })
  local cmp = sort_mod.make_comparator({ { key = "due", reverse = false } })
  table.sort(items, cmp)
  -- "9999-99-99" sentinel for missing date → sorts last
  eq(items[1].task.fields.due, "2024-01-01")
  eq(items[2].task.fields.due, nil)
end

T["sort"] = sort_tests

-- ── group.lua unit tests ───────────────────────────────────────────────────

local group_tests = MiniTest.new_set()

group_tests["no group_by: single empty-name group"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "/vault/note.md", {})
  eq(#names, 1)
  eq(names[1], "")
end

group_tests["group by status: returns status name"] = function()
  local t = pt("- [ ] Todo task")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "status", reverse = false } })
  eq(#names, 1)
  eq(names[1], "Todo")
end

group_tests["group by status: done task → Done group"] = function()
  local t = pt("- [x] Done task ✅ 2024-01-10")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "status", reverse = false } })
  eq(names[1], "Done")
end

group_tests["group by priority: highest task → Priority 1: Highest"] = function()
  local t = pt("- [ ] High task 🔺")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "priority", reverse = false } })
  eq(names[1], "Priority 1: Highest")
end

group_tests["group by priority: no priority → Priority 4: None"] = function()
  local t = pt("- [ ] Plain task")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "priority", reverse = false } })
  eq(names[1], "Priority 4: None")
end

group_tests["group by due: returns date string"] = function()
  local t = pt("- [ ] Task 📅 2024-01-15")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "due", reverse = false } })
  eq(names[1], "2024-01-15")
end

group_tests["group by due: no due → 'No date'"] = function()
  local t = pt("- [ ] Task without due")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "due", reverse = false } })
  eq(names[1], "No date")
end

group_tests["group by path: returns full path"] = function()
  local t = pt("- [ ] Task")
  local path = "/home/user/vault/projects/note.md"
  local names = group_mod.resolve(t, path, { { key = "path", reverse = false } })
  eq(names[1], path)
end

group_tests["group by filename: returns filename without extension"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "/vault/my_note.md", { { key = "filename", reverse = false } })
  eq(#names, 1)
  eq(names[1], "my_note")
end

group_tests["group by backlink: returns filename without extension"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "/vault/my_note.md", { { key = "backlink", reverse = false } })
  eq(#names, 1)
  eq(names[1], "my_note")
end

group_tests["group by folder: returns directory part"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "/vault/inbox/note.md", { { key = "folder", reverse = false } })
  eq(names[1], "/vault/inbox")
end

group_tests["group by tags: task with one tag → one group"] = function()
  local t = pt("- [ ] Task #work")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "tags", reverse = false } })
  eq(#names, 1)
  eq(names[1], "#work")
end

group_tests["group by tags: task with two tags → two groups"] = function()
  local t = pt("- [ ] Task #work #personal")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "tags", reverse = false } })
  eq(#names, 2)
  -- Order matches tag order in parse
  local has_work = false
  local has_personal = false
  for _, n in ipairs(names) do
    if n == "#work" then
      has_work = true
    end
    if n == "#personal" then
      has_personal = true
    end
  end
  eq(has_work, true)
  eq(has_personal, true)
end

group_tests["group by tags: no tags → 'No tags'"] = function()
  local t = pt("- [ ] Untagged task")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "tags", reverse = false } })
  eq(#names, 1)
  eq(names[1], "No tags")
end

group_tests["multi-key group: status + priority joined with ' / '"] = function()
  local t = pt("- [ ] Task ⏫")
  local names = group_mod.resolve(t, "/vault/note.md", {
    { key = "status", reverse = false },
    { key = "priority", reverse = false },
  })
  eq(#names, 1)
  eq(names[1], "Todo / Priority 2: High")
end

group_tests["multi-key with tags: tags expand each combo"] = function()
  local t = pt("- [ ] Task #a #b")
  local names = group_mod.resolve(t, "/vault/note.md", {
    { key = "status", reverse = false },
    { key = "tags", reverse = false },
  })
  eq(#names, 2)
  local found_a = false
  local found_b = false
  for _, n in ipairs(names) do
    if n == "Todo / #a" then
      found_a = true
    end
    if n == "Todo / #b" then
      found_b = true
    end
  end
  eq(found_a, true)
  eq(found_b, true)
end

group_tests["group by root: first subfolder for vault-relative `sub/note.md`"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "sub/note.md", { { key = "root", reverse = false } })
  eq(#names, 1)
  eq(names[1], "sub")
end

group_tests["group by root: empty string when file directly in vault root"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "note.md", { { key = "root", reverse = false } })
  eq(#names, 1)
  eq(names[1], "")
end

group_tests["group by root: deep path returns first subfolder only"] = function()
  local t = pt("- [ ] Task")
  local names = group_mod.resolve(t, "a/b/c/note.md", { { key = "root", reverse = false } })
  eq(#names, 1)
  eq(names[1], "a")
end

group_tests["group by recurrence: returns recurrence string"] = function()
  local t = pt("- [ ] Repeating 🔁 every week")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "recurrence", reverse = false } })
  eq(names[1], "every week")
end

group_tests["group by recurrence: no recurrence → 'None'"] = function()
  local t = pt("- [ ] One-off")
  local names = group_mod.resolve(t, "/vault/note.md", { { key = "recurrence", reverse = false } })
  eq(names[1], "None")
end

T["group"] = group_tests

-- ── hide.lua unit tests ────────────────────────────────────────────────────

local hide_tests = MiniTest.new_set()

hide_tests["empty list → empty flags"] = function()
  local flags = hide_mod.make_flags({})
  eq(next(flags), nil)
end

hide_tests["hide priority → flags.priority = true"] = function()
  local flags = hide_mod.make_flags({ "priority" })
  eq(flags.priority, true)
end

hide_tests["hide due date → flags.due_date = true"] = function()
  local flags = hide_mod.make_flags({ "due date" })
  eq(flags.due_date, true)
end

hide_tests["hide tags → flags.tags = true"] = function()
  local flags = hide_mod.make_flags({ "tags" })
  eq(flags.tags, true)
end

hide_tests["hide task count → flags.task_count = true"] = function()
  local flags = hide_mod.make_flags({ "task count" })
  eq(flags.task_count, true)
end

hide_tests["multiple hides → multiple flags set"] = function()
  local flags = hide_mod.make_flags({ "priority", "due date", "tags" })
  eq(flags.priority, true)
  eq(flags.due_date, true)
  eq(flags.tags, true)
end

hide_tests["all known hide keys map to flags"] = function()
  local all_keys = {
    "priority",
    "due date",
    "scheduled date",
    "start date",
    "done date",
    "created date",
    "cancelled date",
    "recurrence rule",
    "on completion",
    "tags",
    "id",
    "depends on",
    "backlinks",
    "task count",
    "tree",
    "edit button",
    "postpone button",
  }
  local flags = hide_mod.make_flags(all_keys)
  eq(flags.priority, true)
  eq(flags.scheduled_date, true)
  eq(flags.recurrence_rule, true)
  eq(flags.edit_button, true)
  eq(flags.postpone_button, true)
end

T["hide"] = hide_tests

-- ── run.lua unit tests ─────────────────────────────────────────────────────

local run_tests = MiniTest.new_set()

-- Helper tasks
local task_open_due = pt("- [ ] Open with due 📅 2024-01-15")
local task_done = pt("- [x] Done task ✅ 2024-01-10")
local task_high = pt("- [ ] High priority ⏫ 📅 2024-02-01")
local task_low = pt("- [ ] Low priority 🔽 📅 2024-03-01")
local task_no_tag = pt("- [ ] No tag task")

local PATH_A = "/vault/a.md"
local PATH_B = "/vault/b.md"

run_tests["empty index → empty result"] = function()
  local idx = make_index({})
  local result = run("not done", idx)
  eq(result.total, 0)
  eq(#result.groups, 0)
end

run_tests["not done: filters correctly"] = function()
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
    { task = task_done, path = PATH_A },
    { task = task_high, path = PATH_A },
  })
  local result = run("not done", idx)
  eq(result.total, 2)
end

run_tests["done: only done tasks pass"] = function()
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
    { task = task_done, path = PATH_A },
  })
  local result = run("done", idx)
  eq(result.total, 1)
  eq(result.groups[1].tasks[1].status_symbol, "x")
end

run_tests["filter by function: result.errors contains unsupported"] = function()
  local idx = make_index({})
  local result = run("filter by function task.urgency > 5", idx)
  MiniTest.expect.equality(#result.errors >= 1, true)
  local found = false
  for _, e in ipairs(result.errors) do
    if e.kind == "unsupported" then
      found = true
    end
  end
  eq(found, true)
end

run_tests["is blocked: no longer a v2_feature error (first-class filter)"] = function()
  -- Was: dependency filters errored with v2_feature.  Now: real filter.
  local idx = make_index({})
  local result = run("is blocked", idx)
  eq(#result.errors, 0)
end

run_tests["limit: caps total across groups"] = function()
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
    { task = task_high, path = PATH_A },
    { task = task_low, path = PATH_A },
  })
  local result = run("not done\nlimit 2", idx)
  eq(result.total, 2)
end

run_tests["sort by priority: highest first in result"] = function()
  local idx = make_index({
    { task = task_low, path = PATH_A },
    { task = task_high, path = PATH_A },
    { task = task_open_due, path = PATH_A },
  })
  local result = run("not done\nsort by priority", idx)
  eq(result.total, 3)
  -- First task in single group should be highest priority
  local tasks = result.groups[1].tasks
  eq(tasks[1].fields.priority, "high")
end

run_tests["group by path: tasks in separate groups"] = function()
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
    { task = task_high, path = PATH_B },
    { task = task_low, path = PATH_A },
  })
  local result = run("not done\ngroup by path", idx)
  eq(#result.groups, 2)
  eq(result.total, 3)
end

run_tests["group by path: groups ordered alphabetically"] = function()
  local idx = make_index({
    { task = task_open_due, path = "/vault/z.md" },
    { task = task_high, path = "/vault/a.md" },
  })
  local result = run("not done\ngroup by path", idx)
  eq(result.groups[1].name, "/vault/a.md")
  eq(result.groups[2].name, "/vault/z.md")
end

run_tests["group by path reverse: groups in reverse alphabetical order"] = function()
  local idx = make_index({
    { task = task_open_due, path = "/vault/a.md" },
    { task = task_high, path = "/vault/z.md" },
  })
  local result = run("not done\ngroup by reverse path", idx)
  eq(result.groups[1].name, "/vault/z.md")
  eq(result.groups[2].name, "/vault/a.md")
end

run_tests["hide flags: propagated to result"] = function()
  local idx = make_index({})
  local result = run("not done\nhide priority\nhide due date", idx)
  eq(result.hide_flags.priority, true)
  eq(result.hide_flags.due_date, true)
end

run_tests["errors forwarded from ast"] = function()
  -- Use `filter by function` (still unsupported) to exercise the
  -- error-forwarding path that previously relied on `is blocked`.
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
  })
  local result = run("filter by function task.urgency > 5\nnot done", idx)
  MiniTest.expect.equality(#result.errors, 1)
  eq(result.errors[1].kind, "unsupported")
  -- The valid 'not done' filter still works
  eq(result.total, 1)
end

run_tests["parse_error: short-circuits to zero results"] = function()
  -- Regression: a typo'd directive like "has tags" (plural) used to be dropped
  -- silently from ast.filters and the rest of the query would run with one
  -- fewer filter, widening the result set. Now any parse_error suppresses all
  -- tasks while the error banner still renders.
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
    { task = task_done, path = PATH_A },
  })
  local result = run("has tags\nnot done", idx)
  eq(result.total, 0)
  eq(#result.groups, 0)
  MiniTest.expect.equality(#result.errors >= 1, true)
  local found_parse_err = false
  for _, e in ipairs(result.errors) do
    if e.kind == "parse_error" then
      found_parse_err = true
    end
  end
  eq(found_parse_err, true)
end

run_tests["parse_error: degrade-and-run kinds (unsupported) still produce tasks"] = function()
  -- Confirm that non-parse_error kinds (e.g. `unsupported` for scripting
  -- filters) don't suppress otherwise-valid filters.
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
  })
  local result = run("filter by function ...\nnot done", idx)
  eq(result.total, 1)
end

run_tests["header_summary: describes the query"] = function()
  local idx = make_index({})
  local result = run("not done\nsort by due\ngroup by path\nlimit 10", idx)
  MiniTest.expect.equality(result.header_summary:find("sorted by") ~= nil, true)
  MiniTest.expect.equality(result.header_summary:find("grouped by") ~= nil, true)
  MiniTest.expect.equality(result.header_summary:find("limit") ~= nil, true)
end

run_tests["no filters: all tasks pass"] = function()
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
    { task = task_done, path = PATH_A },
  })
  local result = run("", idx)
  eq(result.total, 2)
end

run_tests["QueryResult.groups each have name and tasks"] = function()
  local idx = make_index({
    { task = task_open_due, path = PATH_A },
  })
  local result = run("not done\ngroup by path", idx)
  eq(#result.groups, 1)
  eq(type(result.groups[1].name), "string")
  eq(type(result.groups[1].tasks), "table")
  eq(#result.groups[1].tasks, 1)
end

run_tests["limit across groups: total cap applied across group boundaries"] = function()
  -- 3 groups each with 1 task; limit 2 → only 2 tasks total, third group absent.
  -- This exercises the cross-group decrement (remaining = remaining - #slice).
  local path_x = "/vault/x.md"
  local path_y = "/vault/y.md"
  local path_z = "/vault/z.md"
  local task_x = pt("- [ ] Task X")
  local task_y = pt("- [ ] Task Y")
  local task_z = pt("- [ ] Task Z")
  local idx = make_index({
    { task = task_x, path = path_x },
    { task = task_y, path = path_y },
    { task = task_z, path = path_z },
  })
  local result = run("group by path\nlimit 2", idx)
  -- Should have exactly 2 tasks total across all groups.
  eq(result.total, 2)
  -- The third group (path_z alphabetically) should be absent or empty.
  local found_z = false
  for _, g in ipairs(result.groups) do
    if g.name == path_z and #g.tasks > 0 then
      found_z = true
    end
  end
  eq(found_z, false)
end

run_tests["workspace_root: scopes tasks to workspace prefix"] = function()
  local vault1_task = pt("- [ ] Vault 1 task")
  local vault2_task = pt("- [ ] Vault 2 task")
  local idx = make_index({
    { task = vault1_task, path = "/vaults/notes/note.md" },
    { task = vault2_task, path = "/vaults/work-notes/work.md" },
  })
  local ast = qp.parse("not done")
  local result = run_mod.run(ast, idx, "/vaults/notes")
  eq(result.total, 1)
  eq(result.groups[1].tasks[1].description, "Vault 1 task")
end

run_tests["workspace_root: nil means no scoping (all tasks)"] = function()
  local vault1_task = pt("- [ ] Vault 1 task")
  local vault2_task = pt("- [ ] Vault 2 task")
  local idx = make_index({
    { task = vault1_task, path = "/vaults/notes/note.md" },
    { task = vault2_task, path = "/vaults/work-notes/work.md" },
  })
  local ast = qp.parse("not done")
  local result = run_mod.run(ast, idx, nil)
  eq(result.total, 2)
end

run_tests["workspace_root: trailing slash handled correctly"] = function()
  local task_in = pt("- [ ] Inside vault")
  local task_out = pt("- [ ] Outside vault")
  local idx = make_index({
    { task = task_in, path = "/vault/subdir/note.md" },
    { task = task_out, path = "/vault-other/note.md" },
  })
  local ast = qp.parse("not done")
  local result = run_mod.run(ast, idx, "/vault")
  eq(result.total, 1)
  eq(result.groups[1].tasks[1].description, "Inside vault")
end

T["run"] = run_tests

-- ── integration tests: fixture vault ──────────────────────────────────────

local int_tests = MiniTest.new_set()

local VAULT = vim.fn.fnamemodify("tests/fixtures/vault", ":p")

--- Parse all tasks from a fixture file, returning { task, path } items.
local function parse_fixture(filename)
  local path = VAULT .. filename
  local items = {}
  local f = io.open(path, "r")
  if not f then
    return items
  end
  for line in f:lines() do
    local t = parse_task.parse(line)
    if t then
      items[#items + 1] = { task = t, path = path }
    end
  end
  f:close()
  return items
end

--- Parse all tasks from fixture vault files (tasks_a.md and tasks_b.md).
--- @param global_filter string|nil  if set, only tasks whose description contains it
--- @return table[]
local function fixture_index_items(global_filter)
  local items = {}
  for _, fname in ipairs({ "tasks_a.md", "tasks_b.md" }) do
    local parsed = parse_fixture(fname)
    for _, item in ipairs(parsed) do
      if global_filter and global_filter ~= "" then
        if not item.task.description:find(global_filter, 1, true) then
          item = nil
        end
      end
      if item then
        items[#items + 1] = item
      end
    end
  end
  return items
end

int_tests["not done: correct count from fixture vault"] = function()
  -- tasks_a.md: 5 tasks total, 1 is done (Write report [x]) → 4 not-done
  -- tasks_b.md: 4 tasks total, all [ ] → 4 not-done
  -- Total not-done: 8
  local idx = make_index(fixture_index_items(nil))
  local result = run("not done", idx)
  eq(result.total, 8)
end

int_tests["done: only Write report is done"] = function()
  local idx = make_index(fixture_index_items(nil))
  local result = run("done", idx)
  eq(result.total, 1)
  local tasks = result.groups[1].tasks
  MiniTest.expect.equality(tasks[1].description:find("Write report") ~= nil, true)
end

int_tests["due before 2099-01-01, sort by priority, group by path, limit 5"] = function()
  -- Tasks with due dates from fixtures:
  --   tasks_a.md: Buy milk (due 2024-01-15, priority none)
  --   tasks_b.md: Deploy app (due 2024-03-15, priority none)
  -- Both are not-done, both pass "due before 2099-01-01"
  local idx = make_index(fixture_index_items(nil))
  local result = run("due before 2099-01-01\nsort by priority\ngroup by path\nlimit 5", idx)
  eq(result.total, 2)
  eq(#result.groups, 2)
  -- Groups are alphabetically sorted by path
  local path_a = VAULT .. "tasks_a.md"
  local path_b = VAULT .. "tasks_b.md"
  -- tasks_a.md < tasks_b.md alphabetically
  eq(result.groups[1].name, path_a)
  eq(result.groups[2].name, path_b)
  eq(#result.groups[1].tasks, 1) -- Buy milk
  eq(#result.groups[2].tasks, 1) -- Deploy app
end

int_tests["filter by function: result.errors contains unsupported [unit-like]"] = function()
  local idx = make_index(fixture_index_items(nil))
  local result = run("filter by function task.urgency > 5", idx)
  MiniTest.expect.equality(#result.errors >= 1, true)
  local found = false
  for _, e in ipairs(result.errors) do
    if e.kind == "unsupported" then
      found = true
    end
  end
  eq(found, true)
end

int_tests["is blocked: parses and runs as a real filter (no v2_feature error)"] = function()
  local idx = make_index(fixture_index_items(nil))
  local result = run("is blocked", idx)
  eq(#result.errors, 0)
  -- With the fixture vault we don't have explicit id/depends_on relations, so
  -- nothing is blocked.  The filter should run successfully with 0 results.
  eq(result.total, 0)
end

int_tests["global_filter='#task': tasks without #task excluded from query"] = function()
  -- With global_filter=#task:
  --   tasks_a.md keeps: Buy milk, Write report, Call dentist, Another task (4 with #task)
  --   tasks_b.md keeps: Fix bug, Write tests, Deploy app (3 with #task)
  --   Excluded: "Non-tagged item" (tasks_a), "Item without tag" (tasks_b)
  -- Total in index with #task: 7
  -- Of those, not-done: 6 (Write report is done)
  local idx = make_index(fixture_index_items("#task"))
  local result = run("not done", idx)
  eq(result.total, 6)
  -- Verify none of the result tasks lack #task in description
  for _, group in ipairs(result.groups) do
    for _, task in ipairs(group.tasks) do
      MiniTest.expect.equality(task.description:find("#task") ~= nil, true)
    end
  end
end

int_tests["global_filter='#task': total index size is 7"] = function()
  local items = fixture_index_items("#task")
  eq(#items, 7)
end

int_tests["path includes tasks_a: only tasks from tasks_a.md"] = function()
  local idx = make_index(fixture_index_items(nil))
  local result = run("path includes tasks_a", idx)
  -- tasks_a.md has 5 tasks
  eq(result.total, 5)
  for _, group in ipairs(result.groups) do
    for _, task in ipairs(group.tasks) do
      -- All tasks should be from tasks_a.md
      local _ = task -- just verify count
    end
  end
end

int_tests["tags include #task: only tasks tagged #task pass"] = function()
  local idx = make_index(fixture_index_items(nil))
  local result = run("tags include #task", idx)
  -- 7 tasks total have #task (4 from a, 3 from b) — but ignored_note excluded
  eq(result.total, 7)
end

int_tests["limit 3: caps total to 3 across groups"] = function()
  local idx = make_index(fixture_index_items(nil))
  local result = run("not done\nlimit 3", idx)
  eq(result.total, 3)
end

int_tests["sort by due asc: tasks ordered by due date"] = function()
  local idx = make_index(fixture_index_items("#task"))
  local result = run("has due date\nsort by due", idx)
  -- Due dates from #task tasks: Buy milk 2024-01-15, Deploy app 2024-03-15
  eq(result.total, 2)
  local tasks = result.groups[1].tasks
  eq(tasks[1].fields.due, "2024-01-15")
  eq(tasks[2].fields.due, "2024-03-15")
end

int_tests["group by priority: correct group names"] = function()
  local idx = make_index(fixture_index_items("#task"))
  local result = run("not done\ngroup by priority", idx)
  -- not-done #task tasks: Buy milk (none), Call dentist (highest), Another task (none), Fix bug (none), Write tests (none), Deploy app (none)
  -- Groups: "Priority 1: Highest" (Call dentist), "Priority 4: None" (5 others)
  local names = {}
  for _, g in ipairs(result.groups) do
    names[g.name] = #g.tasks
  end
  MiniTest.expect.equality(names["Priority 1: Highest"] ~= nil, true)
  MiniTest.expect.equality(names["Priority 4: None"] ~= nil, true)
  eq(names["Priority 1: Highest"], 1) -- Call dentist
  eq(names["Priority 4: None"], 5) -- remaining 5 not-done #task tasks
end

int_tests["workspace_root: cross-vault isolation with real fixture files"] = function()
  -- Index tasks from BOTH fixture vaults into a single mock index,
  -- simulating what happens when a user has multiple obsidian workspaces open.
  local VAULT2 = vim.fn.fnamemodify("tests/fixtures/vault2", ":p")

  local all_items = {}
  -- Parse vault1 tasks
  for _, fname in ipairs({ "tasks_a.md", "tasks_b.md" }) do
    local parsed = parse_fixture(fname)
    for _, item in ipairs(parsed) do
      all_items[#all_items + 1] = item
    end
  end
  -- Parse vault2 tasks
  local vault2_path = VAULT2 .. "work.md"
  local f = io.open(vault2_path, "r")
  assert(f, "vault2/work.md must exist")
  for line in f:lines() do
    local t = parse_task.parse(line)
    if t then
      all_items[#all_items + 1] = { task = t, path = vault2_path }
    end
  end
  f:close()

  local idx = make_index(all_items)

  -- Query scoped to vault1: must NOT include vault2 tasks
  local ast = qp.parse("not done")
  local result_v1 = run_mod.run(ast, idx, VAULT:gsub("/$", ""))
  for _, g in ipairs(result_v1.groups) do
    for _, task in ipairs(g.tasks) do
      eq(task.description:find("Deploy to production") == nil, true)
      eq(task.description:find("Review pull request") == nil, true)
    end
  end

  -- Query scoped to vault2: must NOT include vault1 tasks
  local result_v2 = run_mod.run(ast, idx, VAULT2:gsub("/$", ""))
  eq(result_v2.total, 2) -- "Deploy to production" + "Review pull request"
  for _, g in ipairs(result_v2.groups) do
    for _, task in ipairs(g.tasks) do
      eq(task.description:find("Buy milk") == nil, true)
    end
  end

  -- Unscoped: all tasks from both vaults
  local result_all = run_mod.run(ast, idx, nil)
  eq(result_all.total > result_v1.total, true)
  eq(result_all.total > result_v2.total, true)
end

T["integration"] = int_tests

return T
