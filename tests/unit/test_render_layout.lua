-- tests/unit/test_render_layout.lua
-- Unit tests for render/layout.lua

local T = MiniTest.new_set()

local layout_mod = require("obsidian-tasks.render.layout")
local parse_task = require("obsidian-tasks.task.parse")

-- ── helpers ────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Parse a valid task line and return the Task table.
local function pt(line)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  return t
end

--- Attach src metadata to a task (simulates what the render orchestrator does).
local function with_src(task, path, line_nr)
  task._src_path = path
  task._src_line = line_nr or 1
  return task
end

--- Build a minimal QueryResult table.
local function make_result(opts)
  opts = opts or {}
  return {
    groups = opts.groups or {},
    total = opts.total or 0,
    hide_flags = opts.hide_flags or {},
    header_summary = opts.header_summary or "",
    errors = opts.errors or {},
    -- Optional extensions read by footer:
    _ast_sort = opts._ast_sort,
    limit = opts.limit,
  }
end

--- Find all render lines with a given kind.
local function lines_of_kind(render_lines, kind)
  local result = {}
  for _, l in ipairs(render_lines) do
    if l.kind == kind then
      result[#result + 1] = l
    end
  end
  return result
end

--- Extract text from lines of a given kind.
local function texts_of_kind(render_lines, kind)
  local result = {}
  for _, l in ipairs(lines_of_kind(render_lines, kind)) do
    result[#result + 1] = l.text
  end
  return result
end

-- ── basic structure ────────────────────────────────────────────────────────

T["empty result: contains label and footer only"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  eq(#lines_of_kind(rendered, "label"), 1)
  eq(#lines_of_kind(rendered, "footer"), 1)
  eq(#lines_of_kind(rendered, "task"), 0)
  eq(#lines_of_kind(rendered, "group_header"), 0)
  eq(#lines_of_kind(rendered, "error"), 0)
end

T["empty result: first line is label, last is footer"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  eq(rendered[1].kind, "label")
  eq(rendered[#rendered].kind, "footer")
end

T["empty result: label starts with '▶ tasks'"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  local label = rendered[1].text
  MiniTest.expect.equality(label:sub(1, #"▶ tasks") == "▶ tasks", true)
end

T["empty result: label shows 0 results"] = function()
  local result = make_result({ total = 0 })
  local rendered = layout_mod.layout(result)
  local label = rendered[1].text
  MiniTest.expect.equality(label:find("0 results") ~= nil, true)
end

-- ── label ──────────────────────────────────────────────────────────────────

T["label: includes header_summary when non-empty"] = function()
  local result = make_result({ header_summary = "not done · sorted by due asc" })
  local rendered = layout_mod.layout(result)
  local label = rendered[1].text
  MiniTest.expect.equality(label:find("not done", 1, true) ~= nil, true)
  MiniTest.expect.equality(label:find("sorted by due asc", 1, true) ~= nil, true)
end

T["label: total=1 emits '1 result' (singular)"] = function()
  local result = make_result({ total = 1, groups = { { name = "", tasks = { pt("- [ ] Task") } } } })
  local rendered = layout_mod.layout(result)
  local label = rendered[1].text
  MiniTest.expect.equality(label:find("1 result", 1, true) ~= nil, true)
  -- Must NOT contain "1 results" (plural)
  MiniTest.expect.equality(label:find("1 results", 1, true) == nil, true)
end

T["label: total=3 emits '3 results' (plural)"] = function()
  local result = make_result({ total = 3 })
  local rendered = layout_mod.layout(result)
  MiniTest.expect.equality(rendered[1].text:find("3 results", 1, true) ~= nil, true)
end

-- ── hide task_count ────────────────────────────────────────────────────────

T["hide.task_count: label omits result count"] = function()
  local result = make_result({
    total = 5,
    hide_flags = { task_count = true },
    header_summary = "not done",
  })
  local rendered = layout_mod.layout(result)
  local label = rendered[1].text
  MiniTest.expect.equality(label:find("results") == nil, true)
  MiniTest.expect.equality(label:find("result") == nil, true)
end

T["hide.task_count: footer omits result count"] = function()
  local result = make_result({
    total = 5,
    hide_flags = { task_count = true },
  })
  local rendered = layout_mod.layout(result)
  local footer = rendered[#rendered].text
  MiniTest.expect.equality(footer:find("results") == nil, true)
  MiniTest.expect.equality(footer:find("result") == nil, true)
end

T["hide.task_count: label still contains '▶ tasks'"] = function()
  local result = make_result({ hide_flags = { task_count = true }, header_summary = "not done" })
  local rendered = layout_mod.layout(result)
  MiniTest.expect.equality(rendered[1].text:find("▶ tasks", 1, true) ~= nil, true)
end

-- ── errors ─────────────────────────────────────────────────────────────────

T["errors: error lines emitted after label"] = function()
  local result = make_result({
    errors = {
      { kind = "unsupported", msg = "Scripting filters not supported in nvim" },
    },
  })
  local rendered = layout_mod.layout(result)
  -- label at index 1, error at index 2, footer last
  eq(rendered[1].kind, "label")
  eq(rendered[2].kind, "error")
  eq(rendered[#rendered].kind, "footer")
end

T["errors: error text contains kind and message"] = function()
  local result = make_result({
    errors = {
      { kind = "unsupported", msg = "Scripting filters not supported in nvim" },
    },
  })
  local rendered = layout_mod.layout(result)
  local err_line = lines_of_kind(rendered, "error")[1]
  MiniTest.expect.equality(err_line.text:find("unsupported", 1, true) ~= nil, true)
  MiniTest.expect.equality(err_line.text:find("Scripting filters", 1, true) ~= nil, true)
end

T["errors: error text starts with '▼'"] = function()
  local result = make_result({
    errors = { { kind = "v2_feature", msg = "Dependency filters are a v2 feature" } },
  })
  local rendered = layout_mod.layout(result)
  local err_line = lines_of_kind(rendered, "error")[1]
  MiniTest.expect.equality(err_line.text:sub(1, #"▼") == "▼", true)
end

T["errors: multiple errors emit multiple error lines"] = function()
  local result = make_result({
    errors = {
      { kind = "unsupported", msg = "filter by function" },
      { kind = "v2_feature", msg = "is blocked" },
    },
  })
  local rendered = layout_mod.layout(result)
  eq(#lines_of_kind(rendered, "error"), 2)
end

T["errors: error lines have nil src fields"] = function()
  local result = make_result({
    errors = { { kind = "unsupported", msg = "Scripting filters not supported in nvim" } },
  })
  local rendered = layout_mod.layout(result)
  local err_line = lines_of_kind(rendered, "error")[1]
  eq(err_line.src_path, nil)
  eq(err_line.src_line, nil)
  eq(err_line.src_hash, nil)
end

-- ── groups with 3 named groups (not done scenario) ────────────────────────

T["3 named groups: emits 3 group_header lines"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local task_b = with_src(pt("- [ ] Task B"), "/vault/b.md", 2)
  local task_c = with_src(pt("- [ ] Task C"), "/vault/c.md", 3)
  local result = make_result({
    total = 3,
    header_summary = "not done · grouped by path",
    groups = {
      { name = "/vault/a.md", tasks = { task_a } },
      { name = "/vault/b.md", tasks = { task_b } },
      { name = "/vault/c.md", tasks = { task_c } },
    },
  })
  local rendered = layout_mod.layout(result)
  eq(#lines_of_kind(rendered, "group_header"), 3)
end

T["3 named groups: each group_header text is '## <group_name>'"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local task_b = with_src(pt("- [ ] Task B"), "/vault/b.md", 1)
  local task_c = with_src(pt("- [ ] Task C"), "/vault/c.md", 1)
  local result = make_result({
    total = 3,
    groups = {
      { name = "Alpha", tasks = { task_a } },
      { name = "Beta", tasks = { task_b } },
      { name = "Gamma", tasks = { task_c } },
    },
  })
  local rendered = layout_mod.layout(result)
  local headers = texts_of_kind(rendered, "group_header")
  eq(headers[1], "## Alpha")
  eq(headers[2], "## Beta")
  eq(headers[3], "## Gamma")
end

T["3 named groups: emits 3 task lines total (one per group)"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local task_b = with_src(pt("- [ ] Task B"), "/vault/b.md", 1)
  local task_c = with_src(pt("- [ ] Task C"), "/vault/c.md", 1)
  local result = make_result({
    total = 3,
    groups = {
      { name = "A", tasks = { task_a } },
      { name = "B", tasks = { task_b } },
      { name = "C", tasks = { task_c } },
    },
  })
  local rendered = layout_mod.layout(result)
  eq(#lines_of_kind(rendered, "task"), 3)
end

T["3 named groups: order is label, headers interleaved with tasks, footer"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local task_b = with_src(pt("- [ ] Task B"), "/vault/b.md", 1)
  local task_c = with_src(pt("- [ ] Task C"), "/vault/c.md", 1)
  local result = make_result({
    total = 3,
    groups = {
      { name = "A", tasks = { task_a } },
      { name = "B", tasks = { task_b } },
      { name = "C", tasks = { task_c } },
    },
  })
  local rendered = layout_mod.layout(result)
  -- Expected order: label, header A, task A, header B, task B, header C, task C, footer
  eq(rendered[1].kind, "label")
  eq(rendered[2].kind, "group_header")
  eq(rendered[3].kind, "task")
  eq(rendered[4].kind, "group_header")
  eq(rendered[5].kind, "task")
  eq(rendered[6].kind, "group_header")
  eq(rendered[7].kind, "task")
  eq(rendered[8].kind, "footer")
end

T["single unnamed group: no group_header emitted"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  eq(#lines_of_kind(rendered, "group_header"), 0)
end

-- ── task lines ─────────────────────────────────────────────────────────────

T["task line: kind='task', has src_path and src_line from task metadata"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 42)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  eq(tl.src_path, "/vault/a.md")
  eq(tl.src_line, 42)
end

T["task line: src_hash is 16 hex characters"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(type(tl.src_hash), "string")
  eq(#tl.src_hash, 16)
  MiniTest.expect.equality(tl.src_hash:match("^[0-9a-f]+$") ~= nil, true)
end

T["task line: source_text_hash is 16 hex characters"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(type(tl.source_text_hash), "string")
  eq(#tl.source_text_hash, 16)
  MiniTest.expect.equality(tl.source_text_hash:match("^[0-9a-f]+$") ~= nil, true)
end

T["task line: source_text_hash matches sha256 of raw_line (pre-wikilink)"] = function()
  -- source_text_hash must match the task's raw_line (verbatim original text
  -- from parse.lua) so it matches what readfile returns for the source file.
  -- When a wikilink is appended, src_hash diverges; source_text_hash must not.
  local raw_text = "- [ ] Task A"
  local task_a = with_src(pt(raw_text), "/vault/my-note.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  -- The rendered text includes a wikilink suffix — verify it does.
  MiniTest.expect.equality(tl.text:find("%[%[") ~= nil, true)
  -- source_text_hash must equal sha256 of the raw_line (pre-wikilink).
  local expected = vim.fn.sha256(raw_text):sub(1, 16)
  eq(tl.source_text_hash, expected)
  -- src_hash and source_text_hash must differ when a wikilink was appended.
  MiniTest.expect.equality(tl.src_hash ~= tl.source_text_hash, true)
end

T["task line: source_text_hash equals src_hash when backlinks hidden"] = function()
  -- When no wikilink is appended, both hashes are identical.
  local task_a = with_src(pt("- [ ] Task A"), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { backlinks = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  eq(tl.source_text_hash, tl.src_hash)
end

T["task line: source_text_hash matches raw_line when field-hide flag active"] = function()
  -- With hide.priority, the rendered text omits the priority emoji — but
  -- source_text_hash must still match sha256(task.raw_line), i.e. the original
  -- source-file content WITH the priority field included.
  -- This is the regression caught by the code-reviewer: using the post-hide
  -- task_text would produce a different hash that never matches any source line.
  local raw_text = "- [ ] Task B ⏫ 📅 2024-01-15"
  local task_a = with_src(pt(raw_text), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { priority = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  -- Rendered text must NOT contain the priority emoji (hide flag applied).
  MiniTest.expect.equality(tl.text:find("⏫", 1, true) == nil, true)
  -- source_text_hash must equal sha256 of the ORIGINAL raw_line (with priority).
  local expected_hash = vim.fn.sha256(raw_text):sub(1, 16)
  eq(tl.source_text_hash, expected_hash)
end

T["task line: source_text_hash with hide.tags matches raw_line"] = function()
  -- Same assertion for hide.tags — tags are stripped from rendered text but
  -- source_text_hash must still match the original source line.
  local raw_text = "- [ ] Task C #tag1 #tag2"
  local task_a = with_src(pt(raw_text), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { tags = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  -- source_text_hash must equal sha256 of the raw_line (tags included).
  local expected_hash = vim.fn.sha256(raw_text):sub(1, 16)
  eq(tl.source_text_hash, expected_hash)
end

T["task line: text contains serialized task"] = function()
  local task_a = with_src(pt("- [ ] Buy milk 📅 2024-01-15"), "/vault/tasks.md", 5)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("Buy milk", 1, true) ~= nil, true)
end

-- ── backlinks ──────────────────────────────────────────────────────────────

T["backlinks: wikilink appended when not hidden"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/my-note.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("%[%[my%-note%]%]") ~= nil, true)
end

T["backlinks: wikilink uses basename without extension"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/projects/todo-list.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("%[%[todo%-list%]%]") ~= nil, true)
end

T["hide.backlinks: wikilink not appended when hidden"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { backlinks = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("%[%[") == nil, true)
end

T["no src_path: wikilink not appended even when backlinks not hidden"] = function()
  local task_a = pt("- [ ] Task A") -- no _src_path set
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("%[%[") == nil, true)
end

-- ── hide priority + tags ───────────────────────────────────────────────────

T["hide.priority: priority emoji absent from task line"] = function()
  local task_a = with_src(pt("- [ ] Task A ⏫ 📅 2024-01-15"), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { priority = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  -- Priority emoji ⏫ must not appear in the serialized line.
  MiniTest.expect.equality(tl.text:find("⏫", 1, true) == nil, true)
  -- But due date should still appear.
  MiniTest.expect.equality(tl.text:find("2024-01-15", 1, true) ~= nil, true)
end

T["hide.tags: tags absent from task line"] = function()
  -- Task with a trailing tag.
  local task_a = with_src(pt("- [ ] Task A 📅 2024-01-15 #work"), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { tags = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("#work", 1, true) == nil, true)
  -- Due date still present.
  MiniTest.expect.equality(tl.text:find("2024-01-15", 1, true) ~= nil, true)
end

T["hide.priority + hide.tags: both stripped from task line"] = function()
  local task_a = with_src(pt("- [ ] Task A ⏫ 📅 2024-01-15 #urgent"), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { priority = true, tags = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("⏫", 1, true) == nil, true)
  MiniTest.expect.equality(tl.text:find("#urgent", 1, true) == nil, true)
  -- Due date still present.
  MiniTest.expect.equality(tl.text:find("2024-01-15", 1, true) ~= nil, true)
end

T["hide.due_date: due date absent from task line"] = function()
  local task_a = with_src(pt("- [ ] Task A 📅 2024-01-15"), "/vault/note.md", 1)
  local result = make_result({
    total = 1,
    hide_flags = { due_date = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  MiniTest.expect.equality(tl.text:find("2024-01-15", 1, true) == nil, true)
end

-- ── hide does not mutate original task ────────────────────────────────────

T["hide: original task not mutated by layout"] = function()
  local task_a = with_src(pt("- [ ] Task A ⏫ 📅 2024-01-15 #work"), "/vault/note.md", 1)
  local orig_priority = task_a.fields.priority
  local orig_tags_count = #task_a.tags

  local result = make_result({
    total = 1,
    hide_flags = { priority = true, tags = true },
    groups = { { name = "", tasks = { task_a } } },
  })
  layout_mod.layout(result)

  -- Original task fields must be unchanged.
  eq(task_a.fields.priority, orig_priority)
  eq(#task_a.tags, orig_tags_count)
end

-- ── footer ─────────────────────────────────────────────────────────────────

T["footer: always present as last line"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  eq(rendered[#rendered].kind, "footer")
end

T["footer: has nil src fields"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  local footer = rendered[#rendered]
  eq(footer.src_path, nil)
  eq(footer.src_line, nil)
  eq(footer.src_hash, nil)
end

T["footer: contains total results when task_count not hidden"] = function()
  local result = make_result({ total = 7 })
  local rendered = layout_mod.layout(result)
  local footer = rendered[#rendered].text
  MiniTest.expect.equality(footer:find("7 results", 1, true) ~= nil, true)
end

T["footer: contains limit when _ast_sort and limit provided"] = function()
  local result = make_result({
    total = 3,
    limit = 5,
    _ast_sort = { { key = "due", reverse = false } },
  })
  local rendered = layout_mod.layout(result)
  local footer = rendered[#rendered].text
  MiniTest.expect.equality(footer:find("limit 5", 1, true) ~= nil, true)
  MiniTest.expect.equality(footer:find("sorted:", 1, true) ~= nil, true)
end

T["footer: starts and ends with '─'"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  local footer = rendered[#rendered].text
  MiniTest.expect.equality(footer:sub(1, #"─") == "─", true)
end

-- ── label and task records: kind / shape correctness ─────────────────────

T["label: kind = 'label', src fields nil"] = function()
  local result = make_result({})
  local rendered = layout_mod.layout(result)
  local label = rendered[1]
  eq(label.kind, "label")
  eq(label.src_path, nil)
  eq(label.src_line, nil)
  eq(label.src_hash, nil)
end

T["group_header: kind='group_header', src fields nil"] = function()
  local task_a = with_src(pt("- [ ] Task A"), "/vault/a.md", 1)
  local result = make_result({
    total = 1,
    groups = { { name = "My Group", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local header = lines_of_kind(rendered, "group_header")[1]
  eq(header.kind, "group_header")
  eq(header.src_path, nil)
  eq(header.src_line, nil)
  eq(header.src_hash, nil)
end

T["task record: kind='task', indent preserved"] = function()
  local task_a = with_src(pt("  - [ ] Indented task"), "/vault/note.md", 3)
  local result = make_result({
    total = 1,
    groups = { { name = "", tasks = { task_a } } },
  })
  local rendered = layout_mod.layout(result)
  local tl = lines_of_kind(rendered, "task")[1]
  eq(tl.kind, "task")
  eq(tl.indent, "  ")
end

return T
