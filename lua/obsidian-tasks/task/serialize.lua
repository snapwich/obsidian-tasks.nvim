-- lua/obsidian-tasks/task/serialize.lua
-- Serialize a Task table back into a markdown task line.

local M = {}

local fields_mod = require("obsidian-tasks.task.fields")

-- Build key → field_def lookup (fields_mod only exposes by_emoji / by_dataview).
local by_key = {}
for _, f in ipairs(fields_mod.fields) do
  by_key[f.key] = f
end

-- Tag pattern — must stay in sync with task/parse.lua TAG_PAT.
local TAG_PAT = "#[%w%-_/]+"

-- Field emission order — matches TS DefaultTaskSerializer.
-- priority, recurrence, dates (start, scheduled, due, created, done, cancelled),
-- id, depends_on, on_completion.
local FIELD_ORDER = {
  "priority",
  "recurrence",
  "start",
  "scheduled",
  "due",
  "created",
  "done",
  "cancelled",
  "id",
  "depends_on",
  "on_completion",
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Emit one field token in emoji format.
--- Priority encodes the level as its emoji; all others: emoji + " " + value.
--- Returns the token string plus the byte range of the value WITHIN that token
--- (1-indexed, end-exclusive) so callers can highlight the value range.
--- For priority emoji the value range is the emoji itself.
--- Returns nil when value is nil or unknown.
--- @param key string
--- @param value string
--- @return string|nil, integer|nil, integer|nil
local function emit_emoji(key, value)
  if value == nil then
    return nil
  end
  local fd = by_key[key]
  if not fd then
    return nil
  end
  if key == "priority" then
    local lvl = fields_mod.priority_levels[value]
    if not lvl then
      return nil
    end
    return lvl, 1, #lvl + 1
  end
  local token = fd.emoji .. " " .. value
  local val_start = #fd.emoji + 2 -- emoji + space
  return token, val_start, val_start + #value
end

--- Emit one field token in dataview format: `[dv_key:: value]`.
--- Returns the token plus the byte range of the value WITHIN that token.
--- @param key string
--- @param value string
--- @return string|nil, integer|nil, integer|nil
local function emit_dataview(key, value)
  if value == nil then
    return nil
  end
  local fd = by_key[key]
  if not fd then
    return nil
  end
  local prefix = "[" .. fd.dataview .. ":: "
  local token = prefix .. value .. "]"
  local val_start = #prefix + 1
  return token, val_start, val_start + #value
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the {text, invalid_ranges} representation of *task*.
---
--- A field value comes from `task.fields[key]` when present; otherwise from
--- `task._raw_fields[key]` (set by parse.lua when validation failed) so that
--- invalid values round-trip verbatim through the renderer.  Fields sourced
--- from `_raw_fields` produce an entry in `invalid_ranges` indicating the
--- byte range of the value WITHIN the final serialized line (1-indexed,
--- end-exclusive) so downstream renderers can apply an invalid-field
--- highlight.
---
--- @param task table  Task returned by parse.parse()
--- @param opts? { format?: 'emoji' | 'dataview' | 'preserve' }
--- @return { text: string, invalid_ranges: { [1]: integer, [2]: integer }[] }
local function build(task, opts)
  opts = opts or {}
  local format = opts.format or "preserve"
  local raw_fields = task._raw_fields or {}

  -- ── field tokens in canonical order ────────────────────────────────────────
  local field_parts = {}
  for _, key in ipairs(FIELD_ORDER) do
    local value = task.fields[key]
    local is_invalid = false
    if value == nil and raw_fields[key] ~= nil then
      value = raw_fields[key]
      is_invalid = true
    end
    if value ~= nil then
      local fmt = format
      if fmt == "preserve" then
        fmt = task._origin[key] or "emoji"
      end
      local token, val_s, val_e
      if fmt == "emoji" then
        token, val_s, val_e = emit_emoji(key, value)
      else
        token, val_s, val_e = emit_dataview(key, value)
      end
      if token then
        field_parts[#field_parts + 1] = {
          text = token,
          invalid = is_invalid and val_s ~= nil,
          val_start = val_s,
          val_end = val_e,
        }
      end
    end
  end

  -- ── trailing tags ─────────────────────────────────────────────────────────
  local desc = task.description or ""
  local embedded = {}
  for tag in desc:gmatch(TAG_PAT) do
    embedded[tag] = (embedded[tag] or 0) + 1
  end
  local trailing_tags = {}
  for _, tag in ipairs(task.tags or {}) do
    if (embedded[tag] or 0) > 0 then
      embedded[tag] = embedded[tag] - 1
    else
      table.insert(trailing_tags, tag)
    end
  end

  -- ── assemble while tracking byte positions of invalid value ranges ────────
  local prefix = task.indent .. task.marker .. " [" .. task.status_symbol .. "]"
  local chunks = { prefix }
  local current_len = #prefix
  local invalid_ranges = {}

  local function append_part(text, invalid, val_s, val_e)
    chunks[#chunks + 1] = " "
    current_len = current_len + 1
    local token_start = current_len + 1 -- 1-indexed position of `text` in line
    chunks[#chunks + 1] = text
    current_len = current_len + #text
    if invalid and val_s then
      invalid_ranges[#invalid_ranges + 1] = {
        token_start + val_s - 1,
        token_start + val_e - 1,
      }
    end
  end

  if desc ~= "" then
    append_part(desc, false)
  end
  for _, p in ipairs(field_parts) do
    append_part(p.text, p.invalid, p.val_start, p.val_end)
  end
  for _, tag in ipairs(trailing_tags) do
    append_part(tag, false)
  end

  return { text = table.concat(chunks), invalid_ranges = invalid_ranges }
end

--- Serialize a Task table (as returned by parse.parse) into a markdown line.
---
--- opts.format controls how fields are emitted:
---   'emoji'    — all fields as emoji tokens
---   'dataview' — all fields as [key:: value] tokens
---   'preserve' — per-field: uses task._origin[key] ('emoji'|'dataview');
---                defaults to 'emoji' when _origin entry is absent.
---                This is the default.
---
--- Tags that were embedded in task.description are preserved as-is inside the
--- description text.  Tags that were trailing (after the last field in the
--- original line) are detected by their absence from task.description and
--- appended after all field tokens.
---
--- @param task table  Task returned by parse.parse()
--- @param opts? { format?: 'emoji' | 'dataview' | 'preserve' }
--- @return string
function M.serialize(task, opts)
  return build(task, opts).text
end

--- Like M.serialize, but returns `{text, invalid_ranges}`.  `invalid_ranges`
--- is a list of `{byte_start, byte_end}` tuples (1-indexed, end-exclusive)
--- marking the value bytes of each field whose value failed parse validation.
--- @param task table
--- @param opts? { format?: 'emoji' | 'dataview' | 'preserve' }
--- @return { text: string, invalid_ranges: { [1]: integer, [2]: integer }[] }
function M.serialize_with_meta(task, opts)
  return build(task, opts)
end

return M
