-- lua/obsidian-tasks/cmp/fields.lua
-- Field-icon completion items for blink.cmp.
--
-- Called from cmp/source.get_completions when the cursor is in description
-- position (no field emoji or dataview key appears in the body text before
-- the cursor on the current line).
--
-- ctx shape expected by M.completions:
--   ctx.line        string   full text of the current line
--   ctx.cursor_col  integer  0-indexed cursor byte column
--   ctx.max_tags    integer? cap on tag suggestions (default 20)

local M = {}

local fields = require("obsidian-tasks.task.fields")

-- ── constants ─────────────────────────────────────────────────────────────────

--- Default maximum number of tag suggestions returned.
local DEFAULT_MAX_TAGS = 20

--- blink.cmp / LSP completion item kind numbers.
--- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionItemKind
local KIND_FIELD = 5 -- Field / Property
local KIND_KEYWORD = 14 -- Keyword (used for #tags)

-- Dataview inline-field start: "[key::"
local DV_START_PAT = "%[[%w_]+::"

-- ── position and format detection ────────────────────────────────────────────

--- Return true when the cursor is in the task body but BEFORE any field marker
--- (emoji or dataview `[key::`) appears in the text.
---
--- @param line       string   full text of the task line
--- @param cursor_col integer  0-indexed cursor byte column (exclusive end for sub)
--- @return boolean
local function in_description_position(line, cursor_col)
  -- Find where the task body starts (text after "- [ ] ").
  local body_start = line:match("^%s*[-*+] %[.%] ?()")
  if not body_start then
    return false
  end

  -- Body text up to (but not including) the byte at cursor_col.
  -- cursor_col is 0-indexed so it serves as the inclusive 1-indexed end.
  local body_prefix = line:sub(body_start, cursor_col)

  -- Any field emoji in the prefix → cursor is inside a field value.
  for emoji_char in pairs(fields.by_emoji) do
    if body_prefix:find(emoji_char, 1, true) then
      return false
    end
  end

  -- Any UNCLOSED dataview key start in the prefix → cursor is inside a field value.
  -- A closed field (its `]` appears before the cursor) does not count as active;
  -- the cursor could be positioned after a completed field ready to add another.
  local dv_pos = 1
  while dv_pos <= #body_prefix do
    local s, e = body_prefix:find(DV_START_PAT, dv_pos)
    if not s then
      break
    end
    local close_pos = body_prefix:find("]", e + 1, true)
    if not close_pos then
      -- Unclosed dataview field — cursor is still inside this field's value.
      return false
    end
    dv_pos = e + 1
  end

  return true
end

--- Return true when *line* already contains at least one complete dataview
--- inline-field (e.g. `[due:: 2026-01-01]`).  Used to infer the preferred
--- format for new field suggestions.
---
--- @param line string
--- @return boolean
local function has_dataview_field(line)
  return line:match(DV_START_PAT) ~= nil
end

-- ── field item builders ───────────────────────────────────────────────────────

--- Human-readable label for each field key.
--- @type table<string, string>
local FIELD_LABELS = {
  due = "due date",
  scheduled = "scheduled",
  start = "start",
  done = "done",
  cancelled = "cancelled",
  created = "created",
  priority = "priority",
  recurrence = "recurrence",
  id = "id",
  depends_on = "depends on",
  on_completion = "on completion",
}

--- Priority levels in descending order of importance.
--- @type table[]   each entry: { level = string, emoji = string }
local PRIORITY_ORDER = {
  { level = "highest", emoji = "🔺" },
  { level = "high", emoji = "⏫" },
  { level = "medium", emoji = "🔼" },
  { level = "low", emoji = "🔽" },
  { level = "lowest", emoji = "⏬" },
}

--- Build field-icon completion items using emoji format.
--- Each item's insertText is `<emoji> ` (emoji + trailing space).
---
--- @return table[]
local function emoji_items()
  local items = {}

  -- Non-priority fields.
  for _, field in ipairs(fields.fields) do
    if field.key ~= "priority" then
      local label = FIELD_LABELS[field.key] or field.key
      items[#items + 1] = {
        label = field.emoji .. " " .. label,
        insertText = field.emoji .. " ",
        kind = KIND_FIELD,
        detail = label,
        source_name = "obsidian-tasks",
      }
    end
  end

  -- Priority: one item per level (each emoji encodes the level).
  for _, p in ipairs(PRIORITY_ORDER) do
    items[#items + 1] = {
      label = p.emoji .. " " .. p.level .. " priority",
      insertText = p.emoji .. " ",
      kind = KIND_FIELD,
      detail = p.level .. " priority",
      source_name = "obsidian-tasks",
    }
  end

  return items
end

--- Build field-icon completion items using dataview inline-field format.
--- Each item's insertText is `[<key>:: ]` (cursor ends after closing bracket).
---
--- @return table[]
local function dataview_items()
  local items = {}

  -- Non-priority fields.
  for _, field in ipairs(fields.fields) do
    if field.key ~= "priority" then
      local label = FIELD_LABELS[field.key] or field.key
      local insert = "[" .. field.dataview .. ":: ]"
      items[#items + 1] = {
        label = insert,
        insertText = insert,
        kind = KIND_FIELD,
        detail = label,
        source_name = "obsidian-tasks",
      }
    end
  end

  -- Priority: single dataview item (level chosen via values.lua).
  items[#items + 1] = {
    label = "[priority:: ]",
    insertText = "[priority:: ]",
    kind = KIND_FIELD,
    detail = "priority",
    source_name = "obsidian-tasks",
  }

  return items
end

-- ── tag item builder ──────────────────────────────────────────────────────────

--- Collect the top *max_tags* tags from the task index, sorted by frequency.
---
--- Silently returns an empty list if the index is not available.
---
--- @param max_tags integer  maximum number of tags to return
--- @return table[]          completion items
local function tag_items(max_tags)
  local ok, index = pcall(require, "obsidian-tasks.index")
  if not ok then
    return {}
  end

  -- Count occurrences of each tag across all indexed tasks.
  local freq = {}
  local iter = index.tasks_in(nil)
  local task = iter()
  while task do
    if task.tags then
      for _, tag in ipairs(task.tags) do
        freq[tag] = (freq[tag] or 0) + 1
      end
    end
    task = iter()
  end

  -- Sort by frequency descending, then alphabetically for stability.
  local sorted = {}
  for tag, count in pairs(freq) do
    sorted[#sorted + 1] = { tag = tag, count = count }
  end
  table.sort(sorted, function(a, b)
    if a.count ~= b.count then
      return a.count > b.count
    end
    return a.tag < b.tag
  end)

  -- Take top N and produce completion items.
  local items = {}
  for i = 1, math.min(max_tags, #sorted) do
    local entry = sorted[i]
    items[#items + 1] = {
      label = entry.tag,
      insertText = entry.tag,
      kind = KIND_KEYWORD,
      detail = "tag (" .. entry.count .. "×)",
      source_name = "obsidian-tasks",
    }
  end

  return items
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Return field-icon (and tag) completion items for the given context.
---
--- Returns an empty list when the cursor is not in description position.
---
--- @param  ctx table
---   .line        string   full text of the current line
---   .cursor_col  integer  0-indexed cursor byte column
---   .max_tags    integer? maximum tag suggestions (default 20)
--- @return table[]  blink-compatible completion items
function M.completions(ctx)
  local line = ctx.line or ""
  local cursor_col = ctx.cursor_col or 0
  local max_tags = ctx.max_tags or DEFAULT_MAX_TAGS

  -- Emit items only when cursor is in description position.
  if not in_description_position(line, cursor_col) then
    return {}
  end

  -- Choose format: dataview when line already has a dataview field, else emoji.
  local use_dataview = has_dataview_field(line)
  local items = use_dataview and dataview_items() or emoji_items()

  -- Append tag suggestions.
  local tags = tag_items(max_tags)
  for _, item in ipairs(tags) do
    items[#items + 1] = item
  end

  return items
end

return M
