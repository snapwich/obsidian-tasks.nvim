-- lua/obsidian-tasks/task/parse.lua
-- Parse a markdown task line into a Task table.

local M = {}

local fields = require("obsidian-tasks.task.fields")

-- Task prefix pattern: indent, list marker, status symbol, remainder body.
local PREFIX_PAT = "^(%s*)([-*+]) %[(.)%] ?(.*)"

-- Tag pattern (same as obsidian-tasks TS plugin).
local TAG_PAT = "#[%w%-_/]+"

-- Dataview inline-field pattern: [key:: value]
local DV_PAT = "%[([%w_]+)::%s*([^%]]*)%]"

-- Sorted emoji list, longest byte sequences first.
-- Ensures a longer alias (e.g. multi-codepoint) is matched before a shorter one
-- that shares a byte prefix.
local emoji_list = {}
for emoji_char in pairs(fields.by_emoji) do
  table.insert(emoji_list, emoji_char)
end
table.sort(emoji_list, function(a, b)
  return #a > #b
end)

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Find all emoji + dataview field markers in *body*, sorted by start position.
--- Overlapping matches are dropped (longest / first keeps its range).
---
--- Each marker:
---   { pos, endpos, kind='emoji'|'dataview', field_entry, emoji_char?, raw_value? }
---
--- @param body string
--- @return table[]
local function find_markers(body)
  local markers = {}
  local seen_pos = {} -- pos → true; prevents duplicate starts

  -- ── emoji scan ────────────────────────────────────────────────────────────
  for _, emoji_char in ipairs(emoji_list) do
    local start = 1
    while start <= #body do
      local s, e = string.find(body, emoji_char, start, true)
      if not s then
        break
      end
      if not seen_pos[s] then
        seen_pos[s] = true
        table.insert(markers, {
          pos = s,
          endpos = e,
          kind = "emoji",
          field_entry = fields.by_emoji[emoji_char],
          emoji_char = emoji_char,
        })
      end
      start = e + 1
    end
  end

  -- ── dataview scan ─────────────────────────────────────────────────────────
  local dv_start = 1
  while dv_start <= #body do
    local s, e, key, raw_val = string.find(body, DV_PAT, dv_start)
    if not s then
      break
    end
    local field_entry = fields.by_dataview[key]
    if field_entry then
      table.insert(markers, {
        pos = s,
        endpos = e,
        kind = "dataview",
        field_entry = field_entry,
        raw_value = raw_val,
      })
    end
    dv_start = e + 1
  end

  -- ── sort by position ──────────────────────────────────────────────────────
  table.sort(markers, function(a, b)
    return a.pos < b.pos
  end)

  -- ── remove overlapping markers (keep the one that starts earliest) ────────
  local filtered = {}
  local last_end = 0
  for _, m in ipairs(markers) do
    if m.pos > last_end then
      table.insert(filtered, m)
      last_end = m.endpos
    end
  end

  return filtered
end

--- Strip all #tag tokens from *s* and return the trimmed result.
--- @param s string
--- @return string
local function strip_tags(s)
  return vim.trim((s:gsub(TAG_PAT, "")))
end

--- Collect all #tag tokens present in *s*.
--- @param s string
--- @return string[]
local function collect_tags(s)
  local result = {}
  for tag in s:gmatch(TAG_PAT) do
    table.insert(result, tag)
  end
  return result
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Parse a markdown task line.
---
--- Returns a Task table on success, or nil if *line* is not a task line.
---
--- Task shape:
--- ```
--- {
---   status_symbol,        -- single char inside [ ]
---   indent,               -- leading whitespace string
---   marker,               -- '-' | '*' | '+'
---   description,          -- human text before first field (tags kept as-is)
---   fields = {
---     due, scheduled, start, done, cancelled, created,  -- ISO strings or nil
---     priority,            -- 'highest'|'high'|'medium'|'low'|'lowest' or nil
---     recurrence,          -- raw string or nil
---     id, depends_on, on_completion,                     -- raw strings or nil
---   },
---   tags,                 -- list of '#tag' strings found anywhere on the line
---   raw_line,             -- original input unchanged
---   _origin,              -- { field_key = 'emoji'|'dataview', ... }
--- }
--- ```
---
--- @param line string
--- @return table|nil
function M.parse(line)
  local indent, list_marker, status_sym, body = line:match(PREFIX_PAT)
  if not indent then
    return nil
  end

  body = body or ""

  local task = {
    status_symbol = status_sym,
    indent = indent,
    marker = list_marker,
    description = "",
    fields = {
      due = nil,
      scheduled = nil,
      start = nil,
      done = nil,
      cancelled = nil,
      created = nil,
      priority = nil,
      recurrence = nil,
      id = nil,
      depends_on = nil,
      on_completion = nil,
    },
    tags = {},
    raw_line = line,
    _origin = {},
  }

  local markers = find_markers(body)

  -- Description: text before the first field marker.
  -- Embedded tags inside the description are kept as-is in description text.
  local desc_end = markers[1] and (markers[1].pos - 1) or #body
  task.description = vim.trim(body:sub(1, desc_end))

  -- Tags: collect from the entire body (description + field regions).
  task.tags = collect_tags(body)

  -- Process markers to populate task.fields.
  for i, m in ipairs(markers) do
    local fkey = m.field_entry.key

    if m.kind == "dataview" then
      local value = vim.trim(m.raw_value)
      task.fields[fkey] = value ~= "" and value or nil
      task._origin[fkey] = "dataview"
    elseif m.kind == "emoji" then
      if fkey == "priority" then
        -- Priority emoji encodes the level directly; no trailing value token.
        task.fields.priority = fields.priority_by_emoji[m.emoji_char]
        task._origin.priority = "emoji"
      else
        -- Value extends from after this emoji to the start of the next marker.
        local val_start = m.endpos + 1
        local val_end = markers[i + 1] and (markers[i + 1].pos - 1) or #body
        local raw_region = body:sub(val_start, val_end)
        -- Strip any #tag tokens that trail within this region.
        local value = strip_tags(raw_region)
        task.fields[fkey] = value ~= "" and value or nil
        task._origin[fkey] = "emoji"
      end
    end
  end

  return task
end

return M
