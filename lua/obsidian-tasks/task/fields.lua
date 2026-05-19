-- lua/obsidian-tasks/task/fields.lua
-- Single source of truth for all v1 field definitions (emoji + dataview).
--
-- Each entry:
--   key        canonical internal name
--   emoji      primary emoji character
--   alternates list of alternate emoji chars that also map to this field
--   dataview   dataview inline-field key string
--   kind       'date' | 'string' | 'priority' | 'tag-list'

local M = {}

--- Full list of v1 field definitions.
--- @type table[]
M.fields = {
  {
    key = "due",
    emoji = "📅",
    alternates = { "📆", "🗓" },
    dataview = "due",
    kind = "date",
  },
  {
    key = "scheduled",
    emoji = "⏳",
    alternates = { "⌛" },
    dataview = "scheduled",
    kind = "date",
  },
  {
    key = "start",
    emoji = "🛫",
    alternates = {},
    dataview = "start",
    kind = "date",
  },
  {
    key = "done",
    emoji = "✅",
    alternates = {},
    dataview = "completion",
    kind = "date",
  },
  -- ❌ = cancelled *date* field (not on_completion)
  {
    key = "cancelled",
    emoji = "❌",
    alternates = {},
    dataview = "cancelled",
    kind = "date",
  },
  {
    key = "created",
    emoji = "➕",
    alternates = {},
    dataview = "created",
    kind = "date",
  },
  -- priority uses its own lookup (priority_levels / priority_by_emoji)
  {
    key = "priority",
    emoji = "⏫",
    alternates = { "🔺", "🔼", "🔽", "⏬" },
    dataview = "priority",
    kind = "priority",
  },
  {
    key = "recurrence",
    emoji = "🔁",
    alternates = {},
    dataview = "repeat",
    kind = "string",
  },
  {
    key = "id",
    emoji = "🆔",
    alternates = {},
    dataview = "id",
    kind = "string",
  },
  -- ⛔ = depends_on (block list)
  {
    key = "depends_on",
    emoji = "⛔",
    alternates = {},
    dataview = "dependsOn",
    kind = "tag-list",
  },
  -- 🏁 = on_completion field (NOT cancelled date — that is ❌)
  {
    key = "on_completion",
    emoji = "🏁",
    alternates = {},
    dataview = "onCompletion",
    kind = "string",
  },
}

--- Lookup: emoji char → field entry (covers primary + alternates).
--- @type table<string, table>
M.by_emoji = {}

--- Lookup: dataview key string → field entry.
--- @type table<string, table>
M.by_dataview = {}

--- Lookup: canonical key string → field entry.
--- @type table<string, table>
M.by_key = {}

-- Build lookup tables.
for _, field in ipairs(M.fields) do
  M.by_emoji[field.emoji] = field
  for _, alt in ipairs(field.alternates) do
    M.by_emoji[alt] = field
  end
  M.by_dataview[field.dataview] = field
  M.by_key[field.key] = field
end

--- Lua pattern matching an inline #tag token — single source of truth for
--- task/parse, task/serialize and cmd/tags.
M.TAG_PAT = "#[%w%-_/]+"

--- Priority level name → emoji.
--- Matches obsidian-tasks TS DefaultTaskSerializer ordering.
--- @type table<string, string>
M.priority_levels = {
  highest = "🔺",
  high = "⏫",
  medium = "🔼",
  low = "🔽",
  lowest = "⏬",
}

--- Lookup: priority emoji → level name.
--- @type table<string, string>
M.priority_by_emoji = {}

for level, emoji in pairs(M.priority_levels) do
  M.priority_by_emoji[emoji] = level
end

return M
