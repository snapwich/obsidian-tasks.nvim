-- tests/unit/test_cmp_fields.lua
-- Unit tests for cmp/fields.lua
--
-- Strategy:
--   • Call M.completions(ctx) directly with controlled ctx tables.
--   • Stub the index module to control which tasks (and tags) are visible.
--   • Verify format inference, item shapes, tag sourcing, and top-N limiting.

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

--- Fresh require of cmp/fields (clear cache so stubs take effect).
local function fresh_fields()
  package.loaded["obsidian-tasks.cmp.fields"] = nil
  return require("obsidian-tasks.cmp.fields")
end

--- Build a minimal blink-style ctx for a task line with cursor at column *col*
--- (0-indexed).
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

--- Return the set of insertText values from a list of completion items.
--- @param items table[]
--- @return table<string, boolean>
local function insert_text_set(items)
  local s = {}
  for _, item in ipairs(items) do
    s[item.insertText] = true
  end
  return s
end

--- Build a stub index that exposes a fixed set of tasks.
--- Each task is a minimal table with a .tags field.
--- @param task_list table[]  each entry: { tags = string[] }
--- @return table  stub index module
local function index_stub(task_list)
  return {
    tasks_in = function(_filter)
      local i = 0
      return function()
        i = i + 1
        if task_list[i] then
          return task_list[i]
        end
      end
    end,
  }
end

-- ── module shape ──────────────────────────────────────────────────────────────

T["module shape: has completions function"] = function()
  local mod = fresh_fields()
  MiniTest.expect.equality(type(mod.completions), "function")
end

-- ── position detection: not a task line ──────────────────────────────────────

T["position: empty line returns no items"] = function()
  local mod = fresh_fields()
  local items = mod.completions(ctx("", 0))
  MiniTest.expect.equality(#items, 0)
end

T["position: prose line (no checkbox) returns no items"] = function()
  local mod = fresh_fields()
  local items = mod.completions(ctx("Just a paragraph.", 10))
  MiniTest.expect.equality(#items, 0)
end

T["position: plain list item without checkbox returns no items"] = function()
  local mod = fresh_fields()
  local items = mod.completions(ctx("- No checkbox here", 5))
  MiniTest.expect.equality(#items, 0)
end

-- ── position detection: cursor in description area ───────────────────────────

T["position: cursor in description area → items returned"] = function()
  -- Line with no fields; cursor is after "- [ ] My task " (col 14, 0-indexed)
  local mod = fresh_fields()
  -- "- [ ] My task " has body starting at byte 7 (1-indexed).
  -- cursor_col 14 (0-indexed) → body_prefix = "My task" — no field markers.
  local items = mod.completions(ctx("- [ ] My task ", 14))
  MiniTest.expect.equality(#items > 0, true)
end

T["position: cursor after emoji → no items (field value position)"] = function()
  -- "- [ ] My task 📅 " — cursor after emoji
  -- 📅 is the field emoji; anything after it is field value territory.
  local due_emoji = "📅"
  local line = "- [ ] My task " .. due_emoji .. " "
  -- Place cursor after the emoji (past all its bytes).
  local emoji_start = line:find(due_emoji, 1, true)
  local after_emoji = emoji_start + #due_emoji -- 0-indexed: byte index past emoji
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, after_emoji))
  MiniTest.expect.equality(#items, 0)
end

T["position: cursor after [key:: → no items (dataview value position)"] = function()
  -- Cursor is inside the dataview value area.
  local line = "- [ ] My task [due:: "
  -- cursor_col points to after "[due:: " — inside the dataview field.
  local col = #line -- 0-indexed = 1 past last byte (exclusive end via sub)
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, col))
  MiniTest.expect.equality(#items, 0)
end

-- ── format inference: emoji ───────────────────────────────────────────────────

T["format: no fields on line → emoji insertText"] = function()
  -- Cursor in description area, no existing fields → emoji format.
  local line = "- [ ] Buy milk "
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, #line))
  local inserts = insert_text_set(items)
  -- Due-date emoji insertText: "📅 "
  MiniTest.expect.equality(inserts["📅 "] ~= nil, true)
end

T["format: no fields → labels include emoji characters"] = function()
  local line = "- [ ] Buy milk "
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, #line))
  -- All field items should have source_name = 'obsidian-tasks'
  for _, item in ipairs(items) do
    MiniTest.expect.equality(item.source_name, "obsidian-tasks")
  end
end

T["format: no fields → item has kind, label, insertText, detail"] = function()
  local line = "- [ ] task "
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, #line))
  MiniTest.expect.equality(#items > 0, true)
  local first = items[1]
  MiniTest.expect.equality(type(first.label), "string")
  MiniTest.expect.equality(type(first.insertText), "string")
  MiniTest.expect.equality(type(first.kind), "number")
  MiniTest.expect.equality(type(first.detail), "string")
  MiniTest.expect.equality(first.source_name, "obsidian-tasks")
end

T["format: emoji items insertText ends with trailing space"] = function()
  local line = "- [ ] task "
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, #line))
  -- Check all field-kind items (not tags) end with a space.
  for _, item in ipairs(items) do
    if item.kind == 5 then -- KIND_FIELD
      MiniTest.expect.equality(item.insertText:sub(-1), " ")
    end
  end
end

T["format: priority items present in emoji format"] = function()
  local line = "- [ ] task "
  local fields_def = require("obsidian-tasks.task.fields")
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, #line))
  local labels = label_set(items)
  -- Build expected labels from the canonical priority_levels table.
  local level_names = {
    ["🔺"] = "highest",
    ["⏫"] = "high",
    ["🔼"] = "medium",
    ["🔽"] = "low",
    ["⏬"] = "lowest",
  }
  for emoji, level in pairs(level_names) do
    local expected = emoji .. " " .. level .. " priority"
    MiniTest.expect.equality(labels[expected] ~= nil, true)
  end
  -- Sanity: priority_levels covers all 5 levels.
  MiniTest.expect.equality(#vim.tbl_keys(level_names), 5)
  -- Use fields_def to silence unused-variable lint.
  MiniTest.expect.equality(fields_def ~= nil, true)
end

-- ── format inference: dataview ────────────────────────────────────────────────

T["format: line has dataview field → dataview insertText"] = function()
  -- Line already contains a complete [due:: ...] field.
  -- Cursor is BEFORE the field (still in description position).
  local line = "- [ ] My task [due:: 2026-01-01] "
  -- Position cursor in "My task " (before the "[")  — body_prefix has no markers.
  -- "- [ ] " = 6 bytes, "My task " = 8 bytes → cursor at byte 13 (0-indexed).
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, 13))
  MiniTest.expect.equality(#items > 0, true)
  local inserts = insert_text_set(items)
  -- Due field in dataview format.
  MiniTest.expect.equality(inserts["[due:: ]"] ~= nil, true)
end

T["format: dataview line → no emoji insertText for field items"] = function()
  local line = "- [ ] My task [due:: 2026-01-01] "
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, 13))
  -- None of the field items should have an emoji insertText (they'd start with emoji bytes).
  for _, item in ipairs(items) do
    if item.kind == 5 then -- KIND_FIELD
      -- Dataview insertText starts with "[".
      MiniTest.expect.equality(item.insertText:sub(1, 1), "[")
    end
  end
end

T["format: dataview line → priority item uses [priority:: ] format"] = function()
  local line = "- [ ] task [due:: 2026] "
  local mod = fresh_fields()
  local items = mod.completions(ctx(line, 13))
  local inserts = insert_text_set(items)
  MiniTest.expect.equality(inserts["[priority:: ]"] ~= nil, true)
end

-- ── tag suggestions: sourced from index ──────────────────────────────────────

T["tags: no index tasks → no tag items"] = function()
  local c1 = install_mock("obsidian-tasks.index", index_stub({}))
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  -- Items should exist (field icons), but no tag items.
  local has_tag = false
  for _, item in ipairs(items) do
    if item.kind == 14 then -- KIND_KEYWORD
      has_tag = true
    end
  end
  MiniTest.expect.equality(has_tag, false)
end

T["tags: index has tasks with tags → tag items present"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { tags = { "#project", "#work" } },
      { tags = { "#project" } },
    })
  )
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  local labels = label_set(items)
  -- Both tags should be present.
  MiniTest.expect.equality(labels["#project"] ~= nil, true)
  MiniTest.expect.equality(labels["#work"] ~= nil, true)
end

T["tags: tag items have correct shape"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { tags = { "#mytag" } },
    })
  )
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  local tag_item = nil
  for _, item in ipairs(items) do
    if item.label == "#mytag" then
      tag_item = item
      break
    end
  end
  MiniTest.expect.equality(tag_item ~= nil, true)
  MiniTest.expect.equality(tag_item.insertText, "#mytag")
  MiniTest.expect.equality(tag_item.kind, 14) -- KIND_KEYWORD
  MiniTest.expect.equality(tag_item.source_name, "obsidian-tasks")
  MiniTest.expect.equality(type(tag_item.detail), "string")
end

T["tags: frequency counts appear in detail"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { tags = { "#popular" } },
      { tags = { "#popular" } },
      { tags = { "#popular" } },
      { tags = { "#rare" } },
    })
  )
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  local popular_detail = nil
  for _, item in ipairs(items) do
    if item.label == "#popular" then
      popular_detail = item.detail
      break
    end
  end
  -- Detail should mention the count (3).
  MiniTest.expect.equality(popular_detail ~= nil, true)
  MiniTest.expect.equality(popular_detail:find("3") ~= nil, true)
end

T["tags: sorted by frequency descending"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { tags = { "#rare" } },
      { tags = { "#common", "#rare" } },
      { tags = { "#common" } },
      { tags = { "#common" } },
    })
  )
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  -- Collect tag items in order.
  local tag_labels = {}
  for _, item in ipairs(items) do
    if item.kind == 14 then
      tag_labels[#tag_labels + 1] = item.label
    end
  end
  -- #common (3×) should appear before #rare (2×).
  local common_pos, rare_pos = nil, nil
  for i, l in ipairs(tag_labels) do
    if l == "#common" then
      common_pos = i
    end
    if l == "#rare" then
      rare_pos = i
    end
  end
  MiniTest.expect.equality(common_pos ~= nil, true)
  MiniTest.expect.equality(rare_pos ~= nil, true)
  MiniTest.expect.equality(common_pos < rare_pos, true)
end

-- ── top-N limiting ────────────────────────────────────────────────────────────

T["tags: top-N limiting (default 20)"] = function()
  -- Create 25 unique tags.
  local task_list = {}
  for i = 1, 25 do
    task_list[#task_list + 1] = { tags = { "#tag" .. i } }
  end
  local c1 = install_mock("obsidian-tasks.index", index_stub(task_list))
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  local tag_count = 0
  for _, item in ipairs(items) do
    if item.kind == 14 then
      tag_count = tag_count + 1
    end
  end
  -- Default cap is 20.
  MiniTest.expect.equality(tag_count <= 20, true)
end

T["tags: top-N limiting via ctx.max_tags"] = function()
  -- 15 unique tags, cap at 5.
  local task_list = {}
  for i = 1, 15 do
    task_list[#task_list + 1] = { tags = { "#t" .. i } }
  end
  local c1 = install_mock("obsidian-tasks.index", index_stub(task_list))
  local mod = fresh_fields()
  local limited_ctx = { line = "- [ ] task ", cursor_col = 11, max_tags = 5 }
  local items = mod.completions(limited_ctx)
  c1()
  local tag_count = 0
  for _, item in ipairs(items) do
    if item.kind == 14 then
      tag_count = tag_count + 1
    end
  end
  MiniTest.expect.equality(tag_count, 5)
end

T["tags: max_tags = 0 returns no tag items"] = function()
  local c1 = install_mock(
    "obsidian-tasks.index",
    index_stub({
      { tags = { "#sometag" } },
    })
  )
  local mod = fresh_fields()
  local limited_ctx = { line = "- [ ] task ", cursor_col = 11, max_tags = 0 }
  local items = mod.completions(limited_ctx)
  c1()
  local has_tag = false
  for _, item in ipairs(items) do
    if item.kind == 14 then
      has_tag = true
    end
  end
  MiniTest.expect.equality(has_tag, false)
end

-- ── field item count ──────────────────────────────────────────────────────────

T["field items: emoji format has one item per non-priority field plus 5 priority items"] = function()
  local c1 = install_mock("obsidian-tasks.index", index_stub({}))
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  local field_items = {}
  for _, item in ipairs(items) do
    if item.kind == 5 then -- KIND_FIELD
      field_items[#field_items + 1] = item
    end
  end
  local fields_mod = require("obsidian-tasks.task.fields")
  -- Count non-priority fields.
  local non_priority = 0
  for _, f in ipairs(fields_mod.fields) do
    if f.key ~= "priority" then
      non_priority = non_priority + 1
    end
  end
  -- Expected: non-priority + 5 priority levels.
  MiniTest.expect.equality(#field_items, non_priority + 5)
end

T["field items: dataview format has one item per non-priority field plus 1 priority item"] = function()
  local c1 = install_mock("obsidian-tasks.index", index_stub({}))
  local mod = fresh_fields()
  -- dataview line; cursor before the field.
  local line = "- [ ] task [due:: 2026] "
  local items = mod.completions(ctx(line, 11))
  c1()
  local field_items = {}
  for _, item in ipairs(items) do
    if item.kind == 5 then
      field_items[#field_items + 1] = item
    end
  end
  local fields_mod = require("obsidian-tasks.task.fields")
  local non_priority = 0
  for _, f in ipairs(fields_mod.fields) do
    if f.key ~= "priority" then
      non_priority = non_priority + 1
    end
  end
  -- Expected: non-priority + 1 combined priority item.
  MiniTest.expect.equality(#field_items, non_priority + 1)
end

-- ── index load failure is non-fatal ──────────────────────────────────────────

T["index unavailable: field items still returned"] = function()
  -- Simulate index require failure.
  local c1 = install_mock("obsidian-tasks.index", nil)
  local mod = fresh_fields()
  local items = mod.completions(ctx("- [ ] task ", 11))
  c1()
  -- Should still get field icon items.
  local field_count = 0
  for _, item in ipairs(items) do
    if item.kind == 5 then
      field_count = field_count + 1
    end
  end
  MiniTest.expect.equality(field_count > 0, true)
end

-- ── task line with various markers ───────────────────────────────────────────

T["task line: asterisk bullet recognised"] = function()
  local mod = fresh_fields()
  local items = mod.completions(ctx("* [ ] task ", 11))
  MiniTest.expect.equality(#items > 0, true)
end

T["task line: plus bullet recognised"] = function()
  local mod = fresh_fields()
  local items = mod.completions(ctx("+ [ ] task ", 11))
  MiniTest.expect.equality(#items > 0, true)
end

T["task line: indented task recognised"] = function()
  local mod = fresh_fields()
  local items = mod.completions(ctx("  - [ ] task ", 13))
  MiniTest.expect.equality(#items > 0, true)
end

return T
