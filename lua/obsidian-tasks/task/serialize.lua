-- lua/obsidian-tasks/task/serialize.lua
-- Serialize a Task table back into a markdown task line.

local M = {}

local fields_mod = require("obsidian-tasks.task.fields")

-- Build key → field_def lookup (fields_mod only exposes by_emoji / by_dataview).
local by_key = {}
for _, f in ipairs(fields_mod.fields) do
  by_key[f.key] = f
end

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
--- Returns nil if value is nil or unknown.
--- @param key string
--- @param value string
--- @return string|nil
local function emit_emoji(key, value)
  if value == nil then
    return nil
  end
  local fd = by_key[key]
  if not fd then
    return nil
  end
  if key == "priority" then
    return fields_mod.priority_levels[value]
  end
  return fd.emoji .. " " .. value
end

--- Emit one field token in dataview format: `[dv_key:: value]`.
--- Returns nil if value is nil or unknown.
--- @param key string
--- @param value string
--- @return string|nil
local function emit_dataview(key, value)
  if value == nil then
    return nil
  end
  local fd = by_key[key]
  if not fd then
    return nil
  end
  return "[" .. fd.dataview .. ":: " .. value .. "]"
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

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
  opts = opts or {}
  local format = opts.format or "preserve"

  -- ── field tokens in canonical order ────────────────────────────────────────
  local field_tokens = {}
  for _, key in ipairs(FIELD_ORDER) do
    local value = task.fields[key]
    if value ~= nil then
      local fmt = format
      if fmt == "preserve" then
        fmt = task._origin[key] or "emoji"
      end
      local token
      if fmt == "emoji" then
        token = emit_emoji(key, value)
      else
        token = emit_dataview(key, value)
      end
      if token then
        table.insert(field_tokens, token)
      end
    end
  end

  -- ── trailing tags: in task.tags but not substring of task.description ──────
  -- Tags embedded in the description are already present in task.description.
  -- Tags that appear only after field markers (trailing) need to be re-appended.
  local desc = task.description or ""
  local trailing_tags = {}
  for _, tag in ipairs(task.tags or {}) do
    if not desc:find(tag, 1, true) then
      table.insert(trailing_tags, tag)
    end
  end

  -- ── assemble ───────────────────────────────────────────────────────────────
  local line = task.indent .. task.marker .. " [" .. task.status_symbol .. "]"

  local body_parts = {}
  if desc ~= "" then
    table.insert(body_parts, desc)
  end
  for _, tok in ipairs(field_tokens) do
    table.insert(body_parts, tok)
  end
  for _, tag in ipairs(trailing_tags) do
    table.insert(body_parts, tag)
  end

  if #body_parts > 0 then
    line = line .. " " .. table.concat(body_parts, " ")
  end

  return line
end

return M
