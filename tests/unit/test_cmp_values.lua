-- tests/unit/test_cmp_values.lua
-- Unit tests for cmp/values.lua
--
-- Strategy:
--   • Call M.completions(ctx) directly with controlled ctx tables.
--   • Stub the index module to control which tasks (and ids) are visible.
--   • Verify per-field provider output: date, recurrence, depends_on, id,
--     on_completion, priority.

local T = MiniTest.new_set()

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Swap package.loaded[name]; returns cleanup fn.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Fresh require of cmp/values (clear cache so stubs take effect).
local function fresh_values()
  package.loaded["obsidian-tasks.cmp.values"] = nil
  return require("obsidian-tasks.cmp.values")
end

--- Build a minimal blink-style ctx for a task line with cursor at byte column
--- *col* (0-indexed).
--- @param line string
--- @param col  integer  0-indexed cursor column
--- @return table
local function ctx(line, col)
  return { line = line, cursor_col = col }
end

--- Return the set of labels from a list of completion items.
--- @param items table[]
--- @return table<string, boolean>
local function label_set(items)
  local s = {}
  for _, item in ipairs(items) do
    s[item.label] = true
  end
  return s
end

--- Build a stub index that exposes a fixed list of tasks.
--- Each task entry should have a .fields table (may be nil).
--- @param task_list table[]
--- @return table  stub index module
local function index_stub(task_list)
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

-- Byte positions within "- [ ] task " (11 chars, 0-indexed):
--   body starts at byte 7 (1-indexed), i.e. "task " begins at offset 6.
-- A cursor at col 11 (0-indexed) is past "task " → description area.
-- Cursor AFTER a specific emoji → inside that field's value.

-- Helper: build a task line with an emoji field marker and return the cursor
-- column positioned right after the emoji + one space (i.e. inside the value).
local function after_emoji(emoji)
  local line = "- [ ] task " .. emoji .. " "
  -- cursor after emoji and space: byte offset = #line (0-indexed = position past last char)
  return line, #line
end

-- Helper: build a task line with a dataview field and return cursor inside value.
local function after_dv(key)
  local line = "- [ ] task [" .. key .. ":: "
  return line, #line
end

-- ── module shape ──────────────────────────────────────────────────────────────

T["module shape: has completions function"] = function()
  local mod = fresh_values()
  MiniTest.expect.equality(type(mod.completions), "function")
end

-- ── not a task line ───────────────────────────────────────────────────────────

T["not task line: empty line returns empty table"] = function()
  local mod = fresh_values()
  local items = mod.completions(ctx("", 0))
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 0)
end

T["not task line: prose line returns empty table"] = function()
  local mod = fresh_values()
  local items = mod.completions(ctx("Some prose text.", 10))
  MiniTest.expect.equality(#items, 0)
end

-- ── cursor in description area (no field active) ──────────────────────────────

T["description area: returns empty table"] = function()
  -- Cursor inside "task " before any emoji → not in a field value.
  local mod = fresh_values()
  local items = mod.completions(ctx("- [ ] task ", 11))
  MiniTest.expect.equality(#items, 0)
end

-- ── date fields ───────────────────────────────────────────────────────────────

T["date field: due emoji → NL items returned"] = function()
  local line, col = after_emoji("📅")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  -- Verify "today" and "tomorrow" are present.
  local labels = label_set(items)
  MiniTest.expect.equality(labels["today"] ~= nil, true)
  MiniTest.expect.equality(labels["tomorrow"] ~= nil, true)
end

T["date field: scheduled emoji (⏳) → NL items returned"] = function()
  local line, col = after_emoji("⏳")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["today"] ~= nil, true)
end

T["date field: start emoji (🛫) → NL items returned"] = function()
  local line, col = after_emoji("🛫")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
end

T["date field: done emoji (✅) → NL items returned"] = function()
  local line, col = after_emoji("✅")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
end

T["date field: cancelled emoji (❌) → NL items returned"] = function()
  local line, col = after_emoji("❌")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
end

T["date field: created emoji (➕) → NL items returned"] = function()
  local line, col = after_emoji("➕")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
end

T["date field: items include next-day phrases"] = function()
  local line, col = after_emoji("📅")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  local labels = label_set(items)
  MiniTest.expect.equality(labels["next monday"] ~= nil, true)
  MiniTest.expect.equality(labels["next week"] ~= nil, true)
  MiniTest.expect.equality(labels["in 7 days"] ~= nil, true)
end

T["date field: items have correct shape"] = function()
  local line, col = after_emoji("📅")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local first = items[1]
  MiniTest.expect.equality(type(first.label), "string")
  MiniTest.expect.equality(type(first.insertText), "string")
  MiniTest.expect.equality(type(first.kind), "number")
  MiniTest.expect.equality(type(first.detail), "string")
  MiniTest.expect.equality(first.source_name, "obsidian-tasks")
end

T["date field: dataview due field → NL items returned"] = function()
  local line, col = after_dv("due")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["today"] ~= nil, true)
end

T["date field: dataview scheduled field → NL items returned"] = function()
  local line, col = after_dv("scheduled")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
end

T["date field: typed 'today' → ISO date prepended"] = function()
  -- Cursor is after emoji and "today" has been typed.
  local emoji = "📅"
  local line = "- [ ] task " .. emoji .. " today"
  local col = #line
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  -- First item should be a parsed ISO date (today's date).
  local today_iso = os.date("%Y-%m-%d")
  MiniTest.expect.equality(items[1].label, today_iso)
  MiniTest.expect.equality(items[1].insertText, today_iso)
end

T["date field: typed ISO date → ISO item prepended"] = function()
  local emoji = "📅"
  local iso_date = "2026-06-15"
  local line = "- [ ] task " .. emoji .. " " .. iso_date
  local col = #line
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  -- First item should be the ISO date itself (date_nl parses it back).
  MiniTest.expect.equality(items[1].label, iso_date)
end

T["date field: typed unparseable text → no ISO item prepended"] = function()
  local emoji = "📅"
  local line = "- [ ] task " .. emoji .. " nextweek"
  local col = #line
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  -- NL items should still be present; no prepended item.
  local labels = label_set(items)
  MiniTest.expect.equality(labels["today"] ~= nil, true)
  -- "nextweek" is not a valid NL phrase so no ISO item from it.
  -- Items[1] should be "today" (first NL phrase).
  MiniTest.expect.equality(items[1].label, "today")
end

-- ── dataview field closed before cursor ──────────────────────────────────────

T["date field: closed dataview field → returns empty"] = function()
  -- Cursor is AFTER the closing ] → not inside any field.
  local line = "- [ ] task [due:: 2026-01-01] "
  local col = #line -- cursor after closing ] and space
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 0)
end

-- ── priority field ────────────────────────────────────────────────────────────

T["priority field: high priority emoji → returns empty"] = function()
  local line, col = after_emoji("⏫")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 0)
end

T["priority field: highest priority emoji (🔺) → returns empty"] = function()
  local line, col = after_emoji("🔺")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 0)
end

T["priority field: lowest priority emoji (⏬) → returns empty"] = function()
  local line, col = after_emoji("⏬")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 0)
end

-- ── recurrence field ──────────────────────────────────────────────────────────

T["recurrence field: emoji (🔁) → recurrence patterns returned"] = function()
  local line, col = after_emoji("🔁")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["every day"] ~= nil, true)
  MiniTest.expect.equality(labels["every week"] ~= nil, true)
  MiniTest.expect.equality(labels["every month"] ~= nil, true)
  MiniTest.expect.equality(labels["every year"] ~= nil, true)
  MiniTest.expect.equality(labels["every weekday"] ~= nil, true)
end

T["recurrence field: contains multi-N patterns"] = function()
  local line, col = after_emoji("🔁")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  local labels = label_set(items)
  MiniTest.expect.equality(labels["every 2 days"] ~= nil, true)
  MiniTest.expect.equality(labels["every 2 weeks"] ~= nil, true)
  MiniTest.expect.equality(labels["every 2 months"] ~= nil, true)
end

T["recurrence field: dataview repeat key → recurrence patterns returned"] = function()
  local line, col = after_dv("repeat")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["every day"] ~= nil, true)
end

T["recurrence field: items have correct shape"] = function()
  local line, col = after_emoji("🔁")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local first = items[1]
  MiniTest.expect.equality(type(first.label), "string")
  MiniTest.expect.equality(type(first.insertText), "string")
  MiniTest.expect.equality(first.source_name, "obsidian-tasks")
  MiniTest.expect.equality(type(first.detail), "string")
end

-- ── id field ──────────────────────────────────────────────────────────────────

T["id field: emoji (🆔) → returns empty"] = function()
  local line, col = after_emoji("🆔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 0)
end

T["id field: dataview id key → returns empty"] = function()
  local line, col = after_dv("id")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 0)
end

-- ── depends_on field ──────────────────────────────────────────────────────────

T["depends_on field: emoji (⛔) with index ids → returns ids"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { fields = { id = "abc123" } },
      { fields = { id = "def456" } },
    })
  )
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(#items, 2)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["abc123"] ~= nil, true)
  MiniTest.expect.equality(labels["def456"] ~= nil, true)
end

T["depends_on field: deduplicates duplicate ids"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { fields = { id = "abc123" } },
      { fields = { id = "abc123" } }, -- duplicate
      { fields = { id = "unique" } },
    })
  )
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(#items, 2)
end

T["depends_on field: tasks without id are skipped"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { fields = { id = nil } },
      { fields = {} },
      { fields = { id = "valid" } },
    })
  )
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(#items, 1)
  MiniTest.expect.equality(items[1].label, "valid")
end

T["depends_on field: empty index → returns empty table"] = function()
  local c1 = install_mock("obsidian-tasks.index", index_stub({}))
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 0)
end

T["depends_on field: index unavailable → returns empty table"] = function()
  -- Simulate index require failure.
  local c1 = install_mock("obsidian-tasks.index", nil)
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(type(items), "table")
  MiniTest.expect.equality(#items, 0)
end

T["depends_on field: ids are sorted alphabetically"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { fields = { id = "zzz" } },
      { fields = { id = "aaa" } },
      { fields = { id = "mmm" } },
    })
  )
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(#items, 3)
  MiniTest.expect.equality(items[1].label, "aaa")
  MiniTest.expect.equality(items[2].label, "mmm")
  MiniTest.expect.equality(items[3].label, "zzz")
end

T["depends_on field: items have correct shape"] = function()
  local c1 = install_mock("obsidian-tasks.index", index_stub({ { fields = { id = "task-1" } } }))
  local line, col = after_emoji("⛔")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(#items, 1)
  local item = items[1]
  MiniTest.expect.equality(item.label, "task-1")
  MiniTest.expect.equality(item.insertText, "task-1")
  MiniTest.expect.equality(type(item.kind), "number")
  MiniTest.expect.equality(item.detail, "task id")
  MiniTest.expect.equality(item.source_name, "obsidian-tasks")
end

T["depends_on field: dataview dependsOn key → returns ids"] = function()
  local c1 = install_mock("obsidian-tasks.index", index_stub({ { fields = { id = "my-id" } } }))
  local line, col = after_dv("dependsOn")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  MiniTest.expect.equality(#items, 1)
  MiniTest.expect.equality(items[1].label, "my-id")
end

-- ── on_completion field ───────────────────────────────────────────────────────

T["on_completion field: emoji (🏁) → static values returned"] = function()
  local line, col = after_emoji("🏁")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items > 0, true)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["delete"] ~= nil, true)
  MiniTest.expect.equality(labels["keep"] ~= nil, true)
end

T["on_completion field: exactly 2 items"] = function()
  local line, col = after_emoji("🏁")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 2)
end

T["on_completion field: items have correct shape"] = function()
  local line, col = after_emoji("🏁")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  for _, item in ipairs(items) do
    MiniTest.expect.equality(type(item.label), "string")
    MiniTest.expect.equality(type(item.insertText), "string")
    MiniTest.expect.equality(item.detail, "on completion")
    MiniTest.expect.equality(item.source_name, "obsidian-tasks")
  end
end

T["on_completion field: dataview onCompletion key → static values returned"] = function()
  local line, col = after_dv("onCompletion")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 2)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["delete"] ~= nil, true)
  MiniTest.expect.equality(labels["keep"] ~= nil, true)
end

-- ── multiple fields on same line ──────────────────────────────────────────────

T["multi-field: cursor after second emoji → correct field"] = function()
  -- Line: "- [ ] task 📅 2026-01-01 🔁 "
  -- Cursor is after 🔁 → recurrence field.
  local line = "- [ ] task 📅 2026-01-01 🔁 "
  local col = #line
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  -- Should return recurrence patterns, not date items.
  MiniTest.expect.equality(#items > 0, true)
  local labels = label_set(items)
  MiniTest.expect.equality(labels["every day"] ~= nil, true)
  -- Should NOT contain date phrases.
  MiniTest.expect.equality(labels["today"] ~= nil, false)
end

T["multi-field: cursor after first emoji → correct field"] = function()
  -- Line: "- [ ] task 📅 " (cursor after 📅 space, before any text)
  -- Then a second field comes later.
  local due_emoji = "📅"
  local recur_emoji = "🔁"
  -- Put cursor inside due field value region.
  local prefix = "- [ ] task " .. due_emoji .. " "
  local suffix = recur_emoji .. " every day"
  local line = prefix .. suffix
  local col = #prefix -- cursor right after "📅 "
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  -- Last field marker before cursor is 📅 → date field.
  local labels = label_set(items)
  MiniTest.expect.equality(labels["today"] ~= nil, true)
end

-- ── return type guarantees ────────────────────────────────────────────────────

T["return type: always returns table, never nil"] = function()
  local mod = fresh_values()
  -- Various positions that should all return tables (possibly empty).
  local cases = {
    ctx("", 0),
    ctx("prose", 3),
    ctx("- [ ] task ", 11),
    ctx("- [ ] task 📅 ", 14),
  }
  for _, c in ipairs(cases) do
    local items = mod.completions(c)
    MiniTest.expect.equality(type(items), "table")
  end
end

-- ── opts.date_input.suggestions ───────────────────────────────────────────────

T["date_input.suggestions: custom list is used when configured"] = function()
  -- Stub the plugin module to expose custom date suggestions.
  local c1 = install_mock("obsidian-tasks", {
    opts = {
      date_input = { suggestions = { "custom-phrase-a", "custom-phrase-b" } },
    },
  })
  local line, col = after_emoji("📅")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  local labels = label_set(items)
  MiniTest.expect.equality(labels["custom-phrase-a"] ~= nil, true)
  MiniTest.expect.equality(labels["custom-phrase-b"] ~= nil, true)
  -- Default phrases should NOT appear since the list was replaced.
  MiniTest.expect.equality(labels["next monday"] ~= nil, false)
end

T["date_input.suggestions: built-in list used when opts not set"] = function()
  -- Empty opts (plugin not configured) → fall back to NL_DATE_PHRASES.
  local c1 = install_mock("obsidian-tasks", { opts = {} })
  local line, col = after_emoji("📅")
  local mod = fresh_values()
  local items = mod.completions(ctx(line, col))
  c1()
  local labels = label_set(items)
  -- NL_DATE_PHRASES contains "today" and "tomorrow".
  MiniTest.expect.equality(labels["today"] ~= nil, true)
  MiniTest.expect.equality(labels["tomorrow"] ~= nil, true)
end

T["date_input.suggestions: custom list used for all date fields"] = function()
  local c1 = install_mock("obsidian-tasks", {
    opts = {
      date_input = { suggestions = { "only-phrase" } },
    },
  })
  local mod = fresh_values()
  -- Check scheduled (⏳) too.
  local line, col = after_emoji("⏳")
  local items = mod.completions(ctx(line, col))
  c1()
  local labels = label_set(items)
  MiniTest.expect.equality(labels["only-phrase"] ~= nil, true)
end

return T
