-- lua/obsidian-tasks/cmp/values.lua
-- Per-field value completions for blink.cmp.
--
-- Called when the cursor is inside a field value position on a task line.
-- Delegates to source.lua which routes between fields.lua (description
-- position) and this module (field-value position).
--
-- ctx shape expected by M.completions:
--   ctx.line        string   full text of the current line
--   ctx.cursor_col  integer  0-indexed cursor byte column

local M = {}

local fields = require("obsidian-tasks.task.fields")

-- ── constants ─────────────────────────────────────────────────────────────────

--- blink.cmp / LSP completion item kind numbers.
--- https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#completionItemKind
local KIND_VALUE = 12 -- Value
local KIND_TEXT = 1 -- Text (used for date NL phrases and recurrence patterns)

-- Dataview inline-field start pattern: "[key:: " (captures key).
local DV_KEY_PAT = "%[([%w_]+)::%s*"

-- ── NL date suggestion list ───────────────────────────────────────────────────

--- Static natural-language date phrases offered for all date fields.
--- @type string[]
local NL_DATE_PHRASES = {
  "today",
  "tomorrow",
  "next monday",
  "next tuesday",
  "next wednesday",
  "next thursday",
  "next friday",
  "next saturday",
  "next sunday",
  "next week",
  "in 1 day",
  "in 2 days",
  "in 3 days",
  "in 7 days",
  "in 14 days",
  "in 30 days",
}

-- ── recurrence patterns ───────────────────────────────────────────────────────

--- Static recurrence patterns for the 🔁 field.
--- @type string[]
local RECURRENCE_PATTERNS = {
  "every day",
  "every week",
  "every month",
  "every year",
  "every weekday",
  "every 2 days",
  "every 3 days",
  "every 2 weeks",
  "every 3 weeks",
  "every 2 months",
  "every 3 months",
}

-- ── on_completion values ──────────────────────────────────────────────────────

--- Valid values for the 🏁 on_completion field.
--- Source: obsidian-tasks TS plugin (OnCompletion.ts).
--- @type string[]
local ON_COMPLETION_VALUES = {
  "delete",
  "keep",
}

-- ── in-field detection ────────────────────────────────────────────────────────

--- Detect which field (if any) the cursor is inside.
---
--- Scans the task-body prefix up to cursor_col for field markers (emoji or
--- dataview `[key::`) and returns the field entry for the LAST marker found.
--- For dataview markers, only "unclosed" markers (no `]` before the cursor)
--- are considered active.
---
--- @param  line       string   full text of the task line
--- @param  cursor_col integer  0-indexed cursor byte column
--- @return table|nil  field entry from task/fields.lua, or nil
local function detect_field(line, cursor_col)
  -- Find where the task body starts (text after "- [ ] ").
  local body_start = line:match("^%s*[-*+] %[.%] ?()")
  if not body_start then
    return nil
  end

  -- Prefix: from body_start through the byte at cursor_col.
  -- cursor_col is 0-indexed; as a 1-indexed Lua end it selects exactly the
  -- cursor byte.
  local body_prefix = line:sub(body_start, cursor_col)

  local last_field = nil
  local last_pos = 0

  -- ── emoji markers ─────────────────────────────────────────────────────────
  for emoji_char, field_entry in pairs(fields.by_emoji) do
    local start = 1
    while start <= #body_prefix do
      local s, e = body_prefix:find(emoji_char, start, true)
      if not s then
        break
      end
      if s > last_pos then
        last_pos = s
        last_field = field_entry
      end
      start = e + 1
    end
  end

  -- ── dataview markers (unclosed only) ──────────────────────────────────────
  -- A dataview field is "active" only when its closing `]` has not yet
  -- appeared before the cursor (cursor is still inside the value).
  local dv_start = 1
  while dv_start <= #body_prefix do
    local s, e, key = body_prefix:find(DV_KEY_PAT, dv_start)
    if not s then
      break
    end
    local field_entry = fields.by_dataview[key]
    if field_entry then
      local close_pos = body_prefix:find("]", e + 1, true)
      if not close_pos and s > last_pos then
        last_pos = s
        last_field = field_entry
      end
    end
    dv_start = e + 1
  end

  return last_field
end

--- Extract the text the user has typed after the last field marker up to the
--- cursor.  Used to attempt a freeform ISO-date parse.
---
--- @param  line       string
--- @param  cursor_col integer  0-indexed cursor byte column
--- @return string              trimmed typed text (empty string when not in a field)
local function typed_value(line, cursor_col)
  local body_start = line:match("^%s*[-*+] %[.%] ?()")
  if not body_start then
    return ""
  end

  local body_prefix = line:sub(body_start, cursor_col)

  local last_marker_end = 0

  -- Find the end byte of the last emoji marker.
  for emoji_char in pairs(fields.by_emoji) do
    local start = 1
    while start <= #body_prefix do
      local s, e = body_prefix:find(emoji_char, start, true)
      if not s then
        break
      end
      if e > last_marker_end then
        last_marker_end = e
      end
      start = e + 1
    end
  end

  -- Find the end byte of the last unclosed dataview marker.
  local dv_start = 1
  while dv_start <= #body_prefix do
    local s, e, key = body_prefix:find(DV_KEY_PAT, dv_start)
    if not s then
      break
    end
    local field_entry = fields.by_dataview[key]
    if field_entry then
      local close_pos = body_prefix:find("]", e + 1, true)
      if not close_pos and e > last_marker_end then
        last_marker_end = e
      end
    end
    dv_start = e + 1
  end

  if last_marker_end == 0 then
    return ""
  end

  return vim.trim(body_prefix:sub(last_marker_end + 1))
end

-- ── value providers ───────────────────────────────────────────────────────────

--- Build date completion items.
---
--- Returns the static NL phrase list.  If the typed text can be parsed as an
--- ISO date via cmp/date_nl, an ISO item is prepended (so the user sees their
--- own input validated and completed first).
---
--- @param typed string  text typed after the field marker (may be empty)
--- @return table[]
local function date_items(typed)
  local items = {}

  -- Freeform ISO parse: if the typed text is a recognisable date, offer it first.
  if typed and typed ~= "" then
    local ok, date_nl = pcall(require, "obsidian-tasks.cmp.date_nl")
    if ok then
      local iso = date_nl.parse(typed)
      if iso then
        items[#items + 1] = {
          label = iso,
          insertText = iso,
          kind = KIND_TEXT,
          detail = "date",
          source_name = "obsidian-tasks",
        }
      end
    end
  end

  -- Static NL phrase list.
  for _, phrase in ipairs(NL_DATE_PHRASES) do
    items[#items + 1] = {
      label = phrase,
      insertText = phrase,
      kind = KIND_TEXT,
      detail = "date",
      source_name = "obsidian-tasks",
    }
  end

  return items
end

--- Build recurrence completion items from the static pattern list.
--- @return table[]
local function recurrence_items()
  local items = {}
  for _, pattern in ipairs(RECURRENCE_PATTERNS) do
    items[#items + 1] = {
      label = pattern,
      insertText = pattern,
      kind = KIND_TEXT,
      detail = "recurrence",
      source_name = "obsidian-tasks",
    }
  end
  return items
end

--- Build on_completion completion items from the static value list.
--- @return table[]
local function on_completion_items()
  local items = {}
  for _, value in ipairs(ON_COMPLETION_VALUES) do
    items[#items + 1] = {
      label = value,
      insertText = value,
      kind = KIND_VALUE,
      detail = "on completion",
      source_name = "obsidian-tasks",
    }
  end
  return items
end

--- Collect all existing task-id values from the in-memory index.
---
--- Each unique id becomes one item.  Items are sorted alphabetically for
--- stable ordering across vault snapshots.  Silently returns empty when the
--- index module is not available.
---
--- @return table[]
local function depends_on_items()
  local ok, index = pcall(require, "obsidian-tasks.index")
  if not ok then
    return {}
  end

  local seen = {}
  local sorted_ids = {}

  local iter = index.tasks_in(nil)
  local task = iter()
  while task do
    local id = task.fields and task.fields.id
    if id and id ~= "" and not seen[id] then
      seen[id] = true
      sorted_ids[#sorted_ids + 1] = id
    end
    task = iter()
  end

  table.sort(sorted_ids)

  local items = {}
  for _, id in ipairs(sorted_ids) do
    items[#items + 1] = {
      label = id,
      insertText = id,
      kind = KIND_VALUE,
      detail = "task id",
      source_name = "obsidian-tasks",
    }
  end

  return items
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Return per-field value completion items for the given context.
---
--- Returns an empty list (never nil) when:
---   • The cursor is not on a task line.
---   • The cursor is not inside a field value position.
---   • The active field has no value suggestions (priority, id).
---
--- @param  ctx table
---   .line        string   full text of the current line
---   .cursor_col  integer  0-indexed cursor byte column
--- @return table[]  blink-compatible completion items
function M.completions(ctx)
  local line = ctx.line or ""
  local cursor_col = ctx.cursor_col or 0

  local field = detect_field(line, cursor_col)
  if not field then
    return {}
  end

  local key = field.key

  if field.kind == "date" then
    local typed = typed_value(line, cursor_col)
    return date_items(typed)
  end

  if key == "priority" then
    -- Priority is encoded as a single emoji; no trailing value to complete.
    return {}
  end

  if key == "recurrence" then
    return recurrence_items()
  end

  if key == "id" then
    -- Free-string field; no suggestions.
    return {}
  end

  if key == "depends_on" then
    return depends_on_items()
  end

  if key == "on_completion" then
    return on_completion_items()
  end

  -- Unhandled field: return empty (not nil) per blink expectations.
  return {}
end

return M
