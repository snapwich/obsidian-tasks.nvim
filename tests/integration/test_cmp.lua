-- tests/integration/test_cmp.lua
-- Integration tests: full cmp pipeline (source → fields/values → date_nl).
--
-- Uses a minimal stub "blink runtime": get_completions is invoked synchronously
-- with a deterministic context table.  The index module is also stubbed so tag
-- and id suggestions are predictable across runs.
--
-- Context shape follows blink.cmp's own ctx contract:
--   ctx.line       string           full text of the current line
--   ctx.cursor     {row, col}       1-indexed row, 0-indexed byte col
-- source.lua adapts this via ctx.cursor[2] → adapted.cursor_col.
--
-- Scenarios:
--   1. No-field position  → all field icons + tags from stubbed index
--   2. After 📅           → date suggestions include today/tomorrow/next monday
--   3. After 🔁 every     → recurrence patterns include every day/week/month
--   4. Typed 'next friday'→ first item is ISO date; simulated execute OK
--   5. Dataview line      → field icons switch to dataview format

local T = MiniTest.new_set()

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Swap package.loaded[name] for mock; return cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Fresh-require the source (and wipe dependent module caches so stubs apply).
local function fresh_source()
  package.loaded["obsidian-tasks.cmp.source"] = nil
  package.loaded["obsidian-tasks.cmp.fields"] = nil
  package.loaded["obsidian-tasks.cmp.values"] = nil
  return require("obsidian-tasks.cmp.source")
end

--- Build a stub index that yields tasks from task_list.
--- Each entry is a minimal task table, e.g. { tags = { "work" } }.
--- @param task_list table[]
--- @return table  stub index module
local function make_index_stub(task_list)
  return {
    tasks_in = function(_filter)
      local i = 0
      return function()
        i = i + 1
        return task_list[i]
      end
    end,
  }
end

--- Build a blink-compatible context with cursor at the end of *line*.
--- source.lua reads ctx.cursor[2] for the 0-indexed byte column.
--- @param line string
--- @return table
local function ctx_at_end(line)
  return { line = line, cursor = { 1, #line } }
end

--- Invoke source:get_completions synchronously; return the response table.
--- @param source table  source instance
--- @param ctx    table  blink-style context
--- @return table        { items, is_incomplete_forward, is_incomplete_backward }
local function get_completions_sync(source, ctx)
  local result = nil
  source:get_completions(ctx, function(resp)
    result = resp
  end)
  return result
end

--- Return a set of item labels keyed by label string.
--- @param items table[]
--- @return table<string, boolean>
local function label_set(items)
  local s = {}
  for _, item in ipairs(items) do
    s[item.label] = true
  end
  return s
end

--- Return a set of insertText values keyed by insertText string.
--- @param items table[]
--- @return table<string, boolean>
local function insert_text_set(items)
  local s = {}
  for _, item in ipairs(items) do
    s[item.insertText] = true
  end
  return s
end

-- ── Scenario 1: no-field position → field icons + tags from index ─────────────

T["S1: no-field line returns field icon items"] = function()
  local tasks = {
    { tags = { "project", "work" } },
    { tags = { "project" } },
  }
  local c1 = install_mock("obsidian-tasks.index", make_index_stub(tasks))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Cursor immediately after "- [ ] task " — description position, no field yet.
  local line = "- [ ] task "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  eq(resp ~= nil, true)
  local inserts = insert_text_set(resp.items)

  -- Date field icons
  eq(inserts["📅 "] ~= nil, true)
  eq(inserts["⏳ "] ~= nil, true)
  eq(inserts["🛫 "] ~= nil, true)
  -- Priority icons (highest and high)
  eq(inserts["🔺 "] ~= nil, true)
  eq(inserts["⏫ "] ~= nil, true)
  -- Recurrence icon
  eq(inserts["🔁 "] ~= nil, true)
  -- id and depends_on icons
  eq(inserts["🆔 "] ~= nil, true)
  eq(inserts["⛔ "] ~= nil, true)

  c1()
end

T["S1: no-field line returns tags from indexed tasks"] = function()
  local tasks = {
    { tags = { "project", "work" } },
    { tags = { "project" } },
    { tags = { "research" } },
  }
  local c1 = install_mock("obsidian-tasks.index", make_index_stub(tasks))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local labels = label_set(resp.items)
  -- "project" appears 2×, "work" and "research" 1× each — all should be offered.
  eq(labels["project"] ~= nil, true)
  eq(labels["work"] ~= nil, true)
  eq(labels["research"] ~= nil, true)

  c1()
end

T["S1: response has is_incomplete flags"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  eq(type(resp.is_incomplete_forward), "boolean")
  eq(type(resp.is_incomplete_backward), "boolean")

  c1()
end

-- ── Scenario 2: after 📅 → date value suggestions ─────────────────────────────

T["S2: date field offers today, tomorrow, next monday"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Cursor right after "📅 " — typed text is empty.
  local line = "- [ ] task 📅 "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local labels = label_set(resp.items)
  eq(labels["today"] ~= nil, true)
  eq(labels["tomorrow"] ~= nil, true)
  eq(labels["next monday"] ~= nil, true)

  c1()
end

T["S2: date field offers next friday"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task 📅 "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local labels = label_set(resp.items)
  eq(labels["next friday"] ~= nil, true)

  c1()
end

T["S2: scheduled emoji also triggers date items"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task ⏳ "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local labels = label_set(resp.items)
  eq(labels["today"] ~= nil, true)
  eq(labels["tomorrow"] ~= nil, true)

  c1()
end

-- ── Scenario 3: after 🔁 every → recurrence patterns ─────────────────────────

T["S3: recurrence field offers every day, every week, every month"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Cursor after "🔁 every " — detect_field finds 🔁 → recurrence field.
  local line = "- [ ] task 🔁 every "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local labels = label_set(resp.items)
  eq(labels["every day"] ~= nil, true)
  eq(labels["every week"] ~= nil, true)
  eq(labels["every month"] ~= nil, true)

  c1()
end

T["S3: recurrence field offers every weekday and every year"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task 🔁 "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local labels = label_set(resp.items)
  eq(labels["every weekday"] ~= nil, true)
  eq(labels["every year"] ~= nil, true)

  c1()
end

-- ── Scenario 4: typed 'next friday' after 📅 → ISO date accept ───────────────

T["S4: 'next friday' typed → first item insertText is ISO date"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task 📅 next friday"
  local resp = get_completions_sync(inst, ctx_at_end(line))

  eq(#resp.items > 0, true)
  local first = resp.items[1]
  -- insertText must match YYYY-MM-DD
  eq(first.insertText:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil, true)

  c1()
end

T["S4: simulated accept → line becomes '- [ ] task 📅 <ISO date>'"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task 📅 next friday"
  local resp = get_completions_sync(inst, ctx_at_end(line))

  eq(#resp.items > 0, true)
  local iso_item = resp.items[1]

  -- Simulate blink accept: replace typed text after field marker with insertText.
  -- The prefix up to and including "📅 " is "- [ ] task 📅 ".
  local prefix = "- [ ] task 📅 "
  local accepted_line = prefix .. iso_item.insertText

  -- The accepted line must look like "- [ ] task 📅 YYYY-MM-DD"
  eq(accepted_line:match("^%- %[.%] task 📅 %d%d%d%d%-%d%d%-%d%d$") ~= nil, true)

  c1()
end

T["S4: execute pass-through calls callback without error"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task 📅 next friday"
  local blink_ctx = ctx_at_end(line)
  local resp = get_completions_sync(inst, blink_ctx)

  local iso_item = resp.items[1]
  local called = false
  inst:execute(blink_ctx, iso_item, function()
    called = true
  end, function() end)
  eq(called, true)

  c1()
end

T["S4: ISO date item has correct detail field"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task 📅 next friday"
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local first = resp.items[1]
  eq(first.detail, "date")

  c1()
end

-- ── Scenario 5: dataview line → field icons use dataview format ───────────────

T["S5: line with dataview field → suggestions use dataview format"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Line already contains a complete dataview field → infer dataview format.
  -- Cursor is after the dataview field in description area.
  local line = "- [ ] task [due:: 2026-01-01] "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  local inserts = insert_text_set(resp.items)

  -- Dataview-format items present
  eq(inserts["[scheduled:: ]"] ~= nil, true)
  eq(inserts["[start:: ]"] ~= nil, true)
  eq(inserts["[repeat:: ]"] ~= nil, true)

  -- Emoji-format items absent
  eq(inserts["⏳ "], nil)
  eq(inserts["🛫 "], nil)
  eq(inserts["🔁 "], nil)

  c1()
end

T["S5: dataview line → due field also uses dataview format"] = function()
  local c1 = install_mock("obsidian-tasks.index", make_index_stub({}))
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local line = "- [ ] task [due:: 2026-01-01] "
  local resp = get_completions_sync(inst, ctx_at_end(line))

  -- "due" field itself is present in dataview format
  local inserts = insert_text_set(resp.items)
  eq(inserts["[due:: ]"] ~= nil, true)
  eq(inserts["📅 "], nil)

  c1()
end

return T
