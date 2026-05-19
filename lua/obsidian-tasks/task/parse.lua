-- lua/obsidian-tasks/task/parse.lua
-- Parse a markdown task line into a Task table.

local M = {}

local fields = require("obsidian-tasks.task.fields")

-- Task prefix pattern: indent, list marker, status symbol, remainder body.
local PREFIX_PAT = "^(%s*)([-*+]) %[(.)%] ?(.*)"

local TAG_PAT = fields.TAG_PAT

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

--- Validate ISO date format (YYYY-MM-DD).  Accepts any month/day with 2 digits
--- between 01-12 / 01-31 (no calendar-aware day-of-month check — leap years
--- and 30-day months are accepted; this matches obsidian-tasks' lax format).
--- @param s string
--- @return boolean
local function is_valid_iso_date(s)
  if type(s) ~= "string" then
    return false
  end
  local y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return false
  end
  local mi, di = tonumber(m), tonumber(d)
  return mi >= 1 and mi <= 12 and di >= 1 and di <= 31
end

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

--- Strip trailing `[[wikilink]]` tokens from *s* and return the trimmed
--- result.  Used during emoji-value extraction so a wikilink at the tail of
--- a task line (either user-typed or render-added) isn't absorbed into the
--- last field's value (which would, e.g., make a valid `📅 2026-05-09` look
--- like an invalid `2026-05-09 [[note]]`).
--- @param s string
--- @return string
local function strip_trailing_wikilinks(s)
  while true do
    local stripped, n = s:gsub("%s*%[%[[^%]]*%]%]%s*$", "")
    if n == 0 then
      return s
    end
    s = stripped
  end
end

--- Collect all #tag tokens present in *s*.
---
--- `[[wikilink#heading]]` anchors are heading references, not tags, so
--- wikilink tokens are dropped before scanning to avoid false positives.
--- @param s string
--- @return string[]
local function collect_tags(s)
  local result = {}
  s = s:gsub("%[%[[^%]]*%]%]", "")
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
---   heading,              -- nearest ATX heading above the task's source line;
---                         --   set by the indexer (index/init.lua, index/scan.lua),
---                         --   NOT by this parser, which only ever sees one line.
---   _origin,              -- { field_key = 'emoji'|'dataview', ... }
---   _raw_fields,          -- { field_key = "raw_string" } for fields whose value
---                         --   failed validation (parsed value is nil but the
---                         --   source string is preserved so serialize can re-
---                         --   emit verbatim).
---   _errors,              -- { field_key = "human-readable reason" } for fields
---                         --   that failed validation; filters/sorts treat such
---                         --   fields as absent, renderer marks the value range
---                         --   with ObsidianTasksFieldInvalid.
---   _invalid_ranges,      -- { field_key = {byte_start, byte_end} } byte byte
---                         --   positions of the invalid value WITHIN raw_line
---                         --   (1-indexed, end-exclusive).  Used by source-row
---                         --   diagnostics: the rendered-text invalid_ranges
---                         --   reported by serialize_with_meta cover the
---                         --   rendered line, which may differ from raw_line
---                         --   in field order or content.
--- }
--- ```
---
--- @param line string
--- @return table|nil
function M.parse(line)
  -- Normalize line endings: some callers (e.g. index/scan.lua's ripgrep
  -- wrapper) hand us lines with trailing \n or \r\n still attached.  Strip
  -- so raw_line — and any string comparison against disk-read content
  -- (vim.fn.readfile / nvim_buf_get_lines, both of which strip endings) —
  -- compare correctly.  Drift detection relies on raw_line == disk_line.
  line = line:gsub("\r?\n$", "")

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
    _raw_fields = {},
    _errors = {},
    _invalid_ranges = {},
  }

  local markers = find_markers(body)

  -- Description: text before the first field marker.
  -- Embedded tags inside the description are kept as-is in description text.
  local desc_end = markers[1] and (markers[1].pos - 1) or #body
  task.description = vim.trim(body:sub(1, desc_end))

  -- Tags: collect from the entire body (description + field regions).
  task.tags = collect_tags(body)

  -- prefix_len is the byte offset from raw_line start to body start;
  -- positions in `body` translate to raw_line positions via this offset.
  local prefix_len = #line - #body

  -- Validate a parsed field value against its kind.  When validation fails,
  -- nil out task.fields[fkey] and stash the raw string under _raw_fields[fkey]
  -- with a human-readable reason in _errors[fkey] AND a byte range in
  -- _invalid_ranges[fkey] (1-indexed end-exclusive, in raw_line coordinates).
  -- Filters/sorts then treat this field as absent, the renderer marks the
  -- value range as invalid, and the serializer emits the raw verbatim.
  --- @param fkey  string
  --- @param kind  string  field_entry.kind
  --- @param value string  the trimmed value string from source
  --- @param body_off integer  1-indexed byte position of `value` in `body`
  local function set_field_value(fkey, kind, value, body_off)
    if kind == "date" then
      if is_valid_iso_date(value) then
        task.fields[fkey] = value
      else
        task.fields[fkey] = nil
        task._raw_fields[fkey] = value
        task._errors[fkey] = "invalid date (expected YYYY-MM-DD)"
        if body_off then
          task._invalid_ranges[fkey] = { prefix_len + body_off, prefix_len + body_off + #value }
        end
      end
    elseif kind == "priority" then
      -- Dataview priority: value is a level name like "high".  Emoji priority
      -- never enters this branch (handled separately below from priority_by_emoji).
      if fields.priority_levels[value] then
        task.fields[fkey] = value
      else
        task.fields[fkey] = nil
        task._raw_fields[fkey] = value
        task._errors[fkey] = "invalid priority (expected highest|high|medium|low|lowest)"
        if body_off then
          task._invalid_ranges[fkey] = { prefix_len + body_off, prefix_len + body_off + #value }
        end
      end
    else
      -- string, tag-list — no validation, pass through.
      task.fields[fkey] = value
    end
  end

  -- Process markers to populate task.fields.
  for i, m in ipairs(markers) do
    local fkey = m.field_entry.key
    local kind = m.field_entry.kind

    if m.kind == "dataview" then
      local value = vim.trim(m.raw_value)
      if value == "" then
        task.fields[fkey] = nil
      else
        -- Find the trimmed value within the bracket span to recover its
        -- byte position (the regex captures the raw inner text including
        -- leading/trailing whitespace which we trimmed for the value).
        local body_off = body:find(value, m.pos, true)
        set_field_value(fkey, kind, value, body_off)
      end
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
        -- Strip any #tag tokens that trail within this region, plus any
        -- trailing [[wikilink]] tokens — these belong to the task body, not
        -- to the field value (otherwise e.g. `📅 2026-05-09 [[note]]` would
        -- look like an invalid date).
        local value = strip_trailing_wikilinks(strip_tags(raw_region))
        if value == "" then
          task.fields[fkey] = nil
        else
          -- Locate the trimmed value's byte position within body.  The
          -- search starts at val_start; strip_tags + strip_trailing_wikilinks
          -- may have removed prefix/suffix content, so find() inside the
          -- raw_region gives us the offset.
          local off_in_region = raw_region:find(value, 1, true)
          local body_off = off_in_region and (val_start + off_in_region - 1) or nil
          set_field_value(fkey, kind, value, body_off)
        end
        task._origin[fkey] = "emoji"
      end
    end
  end

  return task
end

return M
