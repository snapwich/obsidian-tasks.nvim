-- tests/unit/test_query_parse.lua
-- Unit tests for query/parse.lua — full filter/sort/group/hide/limit grammar.

local T = MiniTest.new_set()
local qp = require("obsidian-tasks.query.parse")

-- ── helpers ────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Parse a single-line query and return the AST.
local function parse(line)
  return qp.parse(line)
end

--- Parse a single-line query and return the first filter node.
local function filter1(line)
  local ast = parse(line)
  return ast.filters[1]
end

--- Leaf node: assert `filter1(line).filter` equals `expected_filter`.
local function leaf(line, expected_filter)
  local node = filter1(line)
  MiniTest.expect.equality(node ~= nil, true)
  eq(node.kind, "leaf")
  eq(node.filter, expected_filter)
end

--- Assert first error in AST.
local function err1(line, expected_kind)
  local ast = parse(line)
  MiniTest.expect.equality(#ast.errors >= 1, true)
  eq(ast.errors[1].kind, expected_kind)
end

-- ── empty / blank / comment lines ─────────────────────────────────────────

T["empty: empty string → empty AST"] = function()
  local ast = parse("")
  eq(#ast.filters, 0)
  eq(#ast.sort_by, 0)
  eq(#ast.group_by, 0)
  eq(ast.limit, nil)
  eq(#ast.hide, 0)
  eq(#ast.errors, 0)
end

T["empty: nil input → empty AST"] = function()
  local ast = qp.parse(nil)
  eq(#ast.filters, 0)
  eq(#ast.errors, 0)
end

T["comment: line starting with # is skipped"] = function()
  local ast = parse("# this is a comment")
  eq(#ast.filters, 0)
  eq(#ast.errors, 0)
end

T["comment: blank line is skipped"] = function()
  local ast = parse("\n\n")
  eq(#ast.filters, 0)
  eq(#ast.errors, 0)
end

T["comment: mixed comments and filters"] = function()
  local ast = parse("# comment\nnot done\n# another comment")
  eq(#ast.filters, 1)
  eq(ast.filters[1].kind, "leaf")
  eq(ast.filters[1].filter.type, "not_done")
end

-- ── status filters ─────────────────────────────────────────────────────────

T["filter: done"] = function()
  leaf("done", { type = "done" })
end

T["filter: not done"] = function()
  leaf("not done", { type = "not_done" })
end

T["filter: status.name is Todo"] = function()
  leaf("status.name is Todo", { type = "status_name", operator = "is", value = "Todo" })
end

T["filter: status.name is In Progress (preserves case)"] = function()
  leaf("status.name is In Progress", { type = "status_name", operator = "is", value = "In Progress" })
end

T["filter: status.type is TODO"] = function()
  leaf("status.type is TODO", { type = "status_type", operator = "is", value = "TODO" })
end

T["filter: status.type normalised to upper-case"] = function()
  leaf("status.type is done", { type = "status_type", operator = "is", value = "DONE" })
end

-- ── recurring filters ──────────────────────────────────────────────────────

T["filter: is recurring"] = function()
  leaf("is recurring", { type = "is_recurring" })
end

T["filter: is not recurring"] = function()
  leaf("is not recurring", { type = "is_not_recurring" })
end

-- ── priority filters ───────────────────────────────────────────────────────

T["filter: priority is highest"] = function()
  leaf("priority is highest", { type = "priority", operator = "is", value = "highest" })
end

T["filter: priority is high"] = function()
  leaf("priority is high", { type = "priority", operator = "is", value = "high" })
end

T["filter: priority is medium"] = function()
  leaf("priority is medium", { type = "priority", operator = "is", value = "medium" })
end

T["filter: priority is low"] = function()
  leaf("priority is low", { type = "priority", operator = "is", value = "low" })
end

T["filter: priority is lowest"] = function()
  leaf("priority is lowest", { type = "priority", operator = "is", value = "lowest" })
end

T["filter: priority is none"] = function()
  leaf("priority is none", { type = "priority", operator = "is", value = "none" })
end

T["filter: priority above high"] = function()
  leaf("priority above high", { type = "priority", operator = "above", value = "high" })
end

T["filter: priority below medium"] = function()
  leaf("priority below medium", { type = "priority", operator = "below", value = "medium" })
end

T["filter: priority not is low"] = function()
  leaf("priority not is low", { type = "priority", operator = "not_is", value = "low" })
end

T["filter: priority is invalid level → parse_error"] = function()
  err1("priority is ultramax", "parse_error")
end

-- ── date filters: all fields × all operators ──────────────────────────────

local date_fields = { "due", "scheduled", "start", "created", "done", "cancelled", "happens" }
local date_ops = { "before", "after", "on", "in" }

for _, field in ipairs(date_fields) do
  for _, op in ipairs(date_ops) do
    local line = field .. " " .. op .. " 2024-01-15"
    T["filter: date " .. field .. " " .. op] = function()
      leaf(line, { type = "date", field = field, operator = op, value = "2024-01-15" })
    end
  end
end

T["filter: due before today → resolves to ISO date"] = function()
  local expected_today = os.date("%Y-%m-%d")
  leaf("due before today", { type = "date", field = "due", operator = "before", value = expected_today })
end

T["filter: due after tomorrow → resolves to ISO date"] = function()
  local t = os.date("*t") --[[@as osdate]]
  t.hour = 0
  t.min = 0
  t.sec = 0
  t.day = t.day + 1
  local expected_tomorrow = os.date("%Y-%m-%d", os.time(t))
  leaf("due after tomorrow", { type = "date", field = "due", operator = "after", value = expected_tomorrow })
end

T["filter: has due date"] = function()
  leaf("has due date", { type = "has_date", field = "due" })
end

T["filter: no due date"] = function()
  leaf("no due date", { type = "no_date", field = "due" })
end

T["filter: due date is invalid"] = function()
  leaf("due date is invalid", { type = "date_invalid", field = "due" })
end

T["filter: has scheduled date"] = function()
  leaf("has scheduled date", { type = "has_date", field = "scheduled" })
end

T["filter: no cancelled date"] = function()
  leaf("no cancelled date", { type = "no_date", field = "cancelled" })
end

T["filter: happens date is invalid"] = function()
  leaf("happens date is invalid", { type = "date_invalid", field = "happens" })
end

-- ── text field filters ────────────────────────────────────────────────────

local text_fields = {
  { kw = "path", canon = "path" },
  { kw = "folder", canon = "folder" },
  { kw = "root", canon = "root" },
  { kw = "backlink", canon = "backlink" },
  { kw = "filename", canon = "filename" },
  { kw = "description", canon = "description" },
  { kw = "heading", canon = "heading" },
  { kw = "recurrence", canon = "recurrence" },
  { kw = "id", canon = "id" },
}

for _, tf in ipairs(text_fields) do
  T["filter: " .. tf.kw .. " includes"] = function()
    leaf(tf.kw .. " includes foo", { type = "text", field = tf.canon, operator = "includes", value = "foo" })
  end
  T["filter: " .. tf.kw .. " does not include"] = function()
    leaf(
      tf.kw .. " does not include bar",
      { type = "text", field = tf.canon, operator = "does_not_include", value = "bar" }
    )
  end
  T["filter: " .. tf.kw .. " regex matches"] = function()
    leaf(
      tf.kw .. " regex matches /^foo/",
      { type = "text", field = tf.canon, operator = "regex_matches", value = "/^foo/" }
    )
  end
  T["filter: " .. tf.kw .. " regex does not match"] = function()
    leaf(
      tf.kw .. " regex does not match /bar$/",
      { type = "text", field = tf.canon, operator = "regex_does_not_match", value = "/bar$/" }
    )
  end
end

-- ── plural keyword variants ───────────────────────────────────────────────

T["filter: plural 'paths includes' → path field"] = function()
  leaf("paths includes foo/bar", { type = "text", field = "path", operator = "includes", value = "foo/bar" })
end

T["filter: plural 'filenames include' → filename field (plural verb)"] = function()
  leaf("filenames include note.md", { type = "text", field = "filename", operator = "includes", value = "note.md" })
end

T["filter: plural 'backlinks include' → backlink field"] = function()
  leaf("backlinks include [[note]]", { type = "text", field = "backlink", operator = "includes", value = "[[note]]" })
end

T["filter: plural 'folders include' → folder field"] = function()
  leaf("folders include inbox", { type = "text", field = "folder", operator = "includes", value = "inbox" })
end

T["filter: plural 'descriptions include' → description field"] = function()
  leaf(
    "descriptions include buy milk",
    { type = "text", field = "description", operator = "includes", value = "buy milk" }
  )
end

T["filter: plural 'headings include' → heading field"] = function()
  leaf("headings include Tasks", { type = "text", field = "heading", operator = "includes", value = "Tasks" })
end

-- ── tag filters ───────────────────────────────────────────────────────────

T["filter: tag includes #work"] = function()
  leaf("tag includes #work", { type = "tag", operator = "includes", value = "#work" })
end

T["filter: tags include #work (plural noun)"] = function()
  leaf("tags include #work", { type = "tag", operator = "includes", value = "#work" })
end

T["filter: tags includes #work (plural noun + singular verb)"] = function()
  leaf("tags includes #work", { type = "tag", operator = "includes", value = "#work" })
end

T["filter: tag does not include #work"] = function()
  leaf("tag does not include #work", { type = "tag", operator = "does_not_include", value = "#work" })
end

T["filter: tags do not include #work"] = function()
  leaf("tags do not include #work", { type = "tag", operator = "does_not_include", value = "#work" })
end

T["filter: has tag"] = function()
  leaf("has tag", { type = "tag", operator = "has" })
end

T["filter: no tag"] = function()
  leaf("no tag", { type = "tag", operator = "no" })
end

-- ── misc filters ──────────────────────────────────────────────────────────

T["filter: exclude sub-items"] = function()
  leaf("exclude sub-items", { type = "exclude_sub_items" })
end

T["filter: urgency above 2.5"] = function()
  leaf("urgency above 2.5", { type = "urgency", operator = "above", value = 2.5 })
end

T["filter: urgency below 1.0"] = function()
  leaf("urgency below 1.0", { type = "urgency", operator = "below", value = 1.0 })
end

T["filter: random"] = function()
  leaf("random", { type = "random" })
end

-- ── sort by ───────────────────────────────────────────────────────────────

local all_sort_keys = {
  "status",
  "priority",
  "due",
  "scheduled",
  "start",
  "done",
  "created",
  "cancelled",
  "happens",
  "path",
  "folder",
  "root",
  "backlink",
  "description",
  "heading",
  "filename",
  "tags",
  "urgency",
  "recurrence",
  "recurring",
  "id",
  "blocking",
}

for _, key in ipairs(all_sort_keys) do
  T["sort: sort by " .. key] = function()
    local ast = parse("sort by " .. key)
    eq(#ast.sort_by, 1)
    eq(ast.sort_by[1], { key = key, reverse = false })
  end
  T["sort: sort by reverse " .. key] = function()
    local ast = parse("sort by reverse " .. key)
    eq(#ast.sort_by, 1)
    eq(ast.sort_by[1], { key = key, reverse = true })
  end
end

T["sort: multiple sort directives accumulate in order"] = function()
  local ast = parse("sort by due\nsort by priority\nsort by reverse status")
  eq(#ast.sort_by, 3)
  eq(ast.sort_by[1], { key = "due", reverse = false })
  eq(ast.sort_by[2], { key = "priority", reverse = false })
  eq(ast.sort_by[3], { key = "status", reverse = true })
end

T["sort: unknown sort key → parse_error"] = function()
  err1("sort by nope", "parse_error")
end

-- ── group by ──────────────────────────────────────────────────────────────

local all_group_keys = {
  "status",
  "priority",
  "due",
  "scheduled",
  "start",
  "done",
  "created",
  "cancelled",
  "happens",
  "path",
  "folder",
  "root",
  "backlink",
  "heading",
  "filename",
  "tags",
  "urgency",
  "recurrence",
  "recurring",
  "id",
}

for _, key in ipairs(all_group_keys) do
  T["group: group by " .. key] = function()
    local ast = parse("group by " .. key)
    eq(#ast.group_by, 1)
    eq(ast.group_by[1], { key = key, reverse = false })
  end
  T["group: group by reverse " .. key] = function()
    local ast = parse("group by reverse " .. key)
    eq(#ast.group_by, 1)
    eq(ast.group_by[1], { key = key, reverse = true })
  end
end

T["group: 'description' is not a valid group key → parse_error"] = function()
  err1("group by description", "parse_error")
end

T["group: 'blocking' is not a valid group key → parse_error"] = function()
  err1("group by blocking", "parse_error")
end

T["group: multiple group directives accumulate"] = function()
  local ast = parse("group by status\ngroup by reverse due")
  eq(#ast.group_by, 2)
  eq(ast.group_by[1], { key = "status", reverse = false })
  eq(ast.group_by[2], { key = "due", reverse = true })
end

-- ── hide subkeys ──────────────────────────────────────────────────────────

local all_hide_keys = {
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

for _, subkey in ipairs(all_hide_keys) do
  T["hide: hide " .. subkey] = function()
    local ast = parse("hide " .. subkey)
    eq(#ast.hide, 1)
    eq(ast.hide[1], subkey)
  end
end

T["hide: multiple hide directives accumulate"] = function()
  local ast = parse("hide priority\nhide due date\nhide tags")
  eq(#ast.hide, 3)
  eq(ast.hide[1], "priority")
  eq(ast.hide[2], "due date")
  eq(ast.hide[3], "tags")
end

T["hide: unknown subkey → parse_error"] = function()
  err1("hide unknown-field", "parse_error")
end

-- ── limit ─────────────────────────────────────────────────────────────────

T["limit: limit 10"] = function()
  local ast = parse("limit 10")
  eq(ast.limit, 10)
end

T["limit: limit 0"] = function()
  local ast = parse("limit 0")
  eq(ast.limit, 0)
end

T["limit: limit 100"] = function()
  local ast = parse("limit 100")
  eq(ast.limit, 100)
end

T["limit: second limit overwrites first"] = function()
  local ast = parse("limit 5\nlimit 20")
  eq(ast.limit, 20)
end

-- ── boolean combinations ──────────────────────────────────────────────────

T["boolean: (not done and has due date) → and node"] = function()
  local node = filter1("(not done and has due date)")
  MiniTest.expect.equality(node ~= nil, true)
  eq(node.kind, "and")
  eq(#node.children, 2)
  eq(node.children[1].kind, "leaf")
  eq(node.children[1].filter.type, "not_done")
  eq(node.children[2].kind, "leaf")
  eq(node.children[2].filter.type, "has_date")
  eq(node.children[2].filter.field, "due")
end

T["boolean: (done or is recurring) → or node"] = function()
  local node = filter1("(done or is recurring)")
  MiniTest.expect.equality(node ~= nil, true)
  eq(node.kind, "or")
  eq(#node.children, 2)
  eq(node.children[1].filter.type, "done")
  eq(node.children[2].filter.type, "is_recurring")
end

T["boolean: not (done) → not node"] = function()
  local node = filter1("not (done)")
  MiniTest.expect.equality(node ~= nil, true)
  eq(node.kind, "not")
  eq(#node.children, 1)
  eq(node.children[1].kind, "leaf")
  eq(node.children[1].filter.type, "done")
end

T["boolean: not (is recurring) → not node"] = function()
  local node = filter1("not (is recurring)")
  eq(node.kind, "not")
  eq(node.children[1].filter.type, "is_recurring")
end

T["boolean: nested — ((not done and has due date) or random)"] = function()
  local node = filter1("((not done and has due date) or random)")
  eq(node.kind, "or")
  eq(node.children[1].kind, "and")
  eq(node.children[2].kind, "leaf")
  eq(node.children[2].filter.type, "random")
end

T["boolean: deeply nested not (not (done))"] = function()
  local node = filter1("not (not (done))")
  eq(node.kind, "not")
  eq(node.children[1].kind, "not")
  eq(node.children[1].children[1].filter.type, "done")
end

T["boolean: and with date filter as right child"] = function()
  local node = filter1("(not done and due before 2024-12-31)")
  eq(node.kind, "and")
  eq(node.children[2].filter, { type = "date", field = "due", operator = "before", value = "2024-12-31" })
end

T["boolean: multiple filter lines accumulate independently"] = function()
  local ast = parse("not done\nhas due date")
  eq(#ast.filters, 2)
  eq(ast.filters[1].filter.type, "not_done")
  eq(ast.filters[2].filter.type, "has_date")
end

-- ── structured errors ─────────────────────────────────────────────────────

T["error: filter by function → unsupported kind"] = function()
  local ast = parse("filter by function task.urgency > 5")
  eq(#ast.errors, 1)
  eq(ast.errors[1].kind, "unsupported")
  eq(ast.errors[1].msg, "Scripting filters not supported in nvim")
  eq(ast.errors[1].line, 1)
end

T["error: filter by function → parsing continues after error"] = function()
  local ast = parse("filter by function task.urgency > 5\nnot done")
  eq(#ast.errors, 1)
  eq(#ast.filters, 1)
  eq(ast.filters[1].filter.type, "not_done")
end

T["error: is blocked → v2_feature kind"] = function()
  local ast = parse("is blocked")
  eq(#ast.errors, 1)
  eq(ast.errors[1].kind, "v2_feature")
  eq(ast.errors[1].msg, "Dependency filters are a v2 feature")
end

T["error: is not blocked → v2_feature kind"] = function()
  err1("is not blocked", "v2_feature")
end

T["error: is blocking → v2_feature kind"] = function()
  err1("is blocking", "v2_feature")
end

T["error: is not blocking → v2_feature kind"] = function()
  err1("is not blocking", "v2_feature")
end

T["error: blocked by includes → v2_feature kind"] = function()
  err1("blocked by includes xyz", "v2_feature")
end

T["error: unknown keyword → parse_error kind"] = function()
  local ast = parse("completely unknown thing")
  eq(#ast.errors, 1)
  eq(ast.errors[1].kind, "parse_error")
  MiniTest.expect.equality(ast.errors[1].msg:find("completely unknown thing") ~= nil, true)
end

T["error: unknown keyword records line number"] = function()
  local ast = parse("# comment\nnot done\nbad keyword here")
  eq(#ast.errors, 1)
  eq(ast.errors[1].line, 3)
end

T["error: multiple errors accumulate without aborting"] = function()
  local ast = parse("filter by function foo\nis blocked\nbad line\nnot done")
  eq(#ast.errors, 3)
  eq(#ast.filters, 1)
  eq(ast.filters[1].filter.type, "not_done")
end

-- ── full multi-line query ──────────────────────────────────────────────────

T["full query: multi-directive query parses all fields"] = function()
  local query = table.concat({
    "# Show active tasks",
    "not done",
    "has due date",
    "sort by due",
    "sort by reverse priority",
    "group by status",
    "hide priority",
    "hide recurrence rule",
    "limit 25",
  }, "\n")
  local ast = parse(query)

  -- 2 filters
  eq(#ast.filters, 2)
  eq(ast.filters[1].filter.type, "not_done")
  eq(ast.filters[2].filter.type, "has_date")

  -- 2 sort directives
  eq(#ast.sort_by, 2)
  eq(ast.sort_by[1], { key = "due", reverse = false })
  eq(ast.sort_by[2], { key = "priority", reverse = true })

  -- 1 group directive
  eq(#ast.group_by, 1)
  eq(ast.group_by[1], { key = "status", reverse = false })

  -- 2 hide subkeys
  eq(#ast.hide, 2)
  eq(ast.hide[1], "priority")
  eq(ast.hide[2], "recurrence rule")

  -- limit
  eq(ast.limit, 25)

  -- no errors
  eq(#ast.errors, 0)
end

T["full query: tags + date + boolean"] = function()
  local query = table.concat({
    "tags include #work",
    "(not done or is recurring)",
    "due before 2025-01-01",
    "sort by urgency",
    "limit 50",
  }, "\n")
  local ast = parse(query)

  eq(#ast.filters, 3)
  eq(ast.filters[1].filter, { type = "tag", operator = "includes", value = "#work" })
  eq(ast.filters[2].kind, "or")
  eq(ast.filters[3].filter, { type = "date", field = "due", operator = "before", value = "2025-01-01" })
  eq(ast.sort_by[1], { key = "urgency", reverse = false })
  eq(ast.limit, 50)
end

-- ── value preservation (original case) ────────────────────────────────────

T["value: path includes preserves original-case value"] = function()
  local node = filter1("path includes Work/Projects")
  eq(node.filter.value, "Work/Projects")
end

T["value: description includes preserves spaces and case"] = function()
  local node = filter1("description includes Buy Milk Today")
  eq(node.filter.value, "Buy Milk Today")
end

T["value: regex value preserved verbatim"] = function()
  local node = filter1("path regex matches /(?i)work/")
  eq(node.filter.value, "/(?i)work/")
end

T["value: tag value preserves # prefix"] = function()
  local node = filter1("tag includes #project/sub")
  eq(node.filter.value, "#project/sub")
end

-- ── date field 'done' vs status 'done' ────────────────────────────────────

T["done: plain 'done' is status filter, not date"] = function()
  leaf("done", { type = "done" })
end

T["done: 'done before 2024-01-01' is date filter"] = function()
  leaf("done before 2024-01-01", { type = "date", field = "done", operator = "before", value = "2024-01-01" })
end

T["done: 'has done date' is date filter"] = function()
  leaf("has done date", { type = "has_date", field = "done" })
end

T["done: 'no done date' is date filter"] = function()
  leaf("no done date", { type = "no_date", field = "done" })
end

return T
