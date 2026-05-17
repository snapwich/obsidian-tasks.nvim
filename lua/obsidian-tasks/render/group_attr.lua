-- lua/obsidian-tasks/render/group_attr.lua
-- P9: inject group-defining attributes into a new task line on INSERT.
--
-- When a task is inserted into a grouped query region, this helper appends the
-- attribute(s) that define the target group so the new task "belongs" to the
-- group it was pasted into.
--
-- Supported group types (per locked decision Q5):
--   tag       → append #tagname if not already present.
--   priority  → append emoji or dataview field for the group's priority level.
--   status    → set the checkbox symbol to the group's status symbol.
--
-- Unsupported group types (no auto-add — position handles membership):
--   file / folder / heading / path / root / backlink / date fields / etc.
--
-- group_context shape (one entry per group_by level):
--   { { by = "tag",      value = "someday"     },   -- bare tag name (no #)
--     { by = "priority", value = "high"        },   -- level name
--     { by = "status",   value = "In Progress" }, } -- status name
--
-- task_origin mirrors task._origin from P2 parse:
--   { [field_key] = "emoji"|"dataview", ... }
-- Used to decide whether to emit emoji (⏫) or dataview ([priority:: high])
-- form for the injected attribute.  A nil/empty origin defaults to emoji.

local M = {}

-- ── Priority helpers ──────────────────────────────────────────────────────────

--- Canonical priority level name → emoji character.
--- @type table<string, string>
local PRIORITY_EMOJIS = {
  highest = "🔺",
  high = "⏫",
  medium = "🔼",
  low = "🔽",
  lowest = "⏬",
}

--- All known priority emoji characters (used for "already present" detection).
--- @type string[]
local ALL_PRIORITY_EMOJIS = { "🔺", "⏫", "🔼", "🔽", "⏬" }

--- Return true when *line* already carries a priority attribute (emoji or dataview).
--- @param line string
--- @return boolean
local function has_priority(line)
  for _, emoji in ipairs(ALL_PRIORITY_EMOJIS) do
    if line:find(emoji, 1, true) then
      return true
    end
  end
  -- Dataview form: [priority:: ...]
  if line:find("%[priority::") then
    return true
  end
  return false
end

-- ── Checkbox helpers ──────────────────────────────────────────────────────────

--- Return the current checkbox symbol (single char) from *line*, or nil.
--- Matches the leading `- [X]` / `* [X]` / `+ [X]` pattern.
--- @param line string
--- @return string|nil
local function get_checkbox(line)
  return line:match("^%s*[-*+]%s%[(.)]")
end

--- Return *line* with its checkbox symbol replaced by *new_symbol*.
--- Only the first checkbox occurrence (at the start of the line) is changed.
--- @param line       string
--- @param new_symbol string  single character
--- @return string
local function set_checkbox(line, new_symbol)
  -- Capture everything up to and including the opening '[', skip the current
  -- symbol, and capture the closing ']'; rebuild with new_symbol in between.
  return (line:gsub("^(%s*[-*+]%s%[).(%])", "%1" .. new_symbol .. "%2", 1))
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Inject group-defining attributes into a new task line based on the
--- group context it is being inserted into.
---
--- For each level in *group_context*:
---   tag      → append `#value` if not already present.
---   priority → append emoji or dataview field (respects task_origin).
---              No-op when the line already carries any priority attribute.
---   status   → rewrite the checkbox to the group's status symbol.
---              No-op when the checkbox already matches.
---   others   → no-op (file/folder/heading handled by source position).
---
--- @param new_task_line string   task line after wikilink strip + date normalisation
--- @param group_context table    list of { by=string, value=string } per group level
--- @param task_origin   table|nil _origin table from the anchor task, or nil
--- @return string  the (potentially modified) task line
function M.inject_group_attributes(new_task_line, group_context, task_origin)
  if not group_context or #group_context == 0 then
    return new_task_line
  end

  local line = new_task_line

  for _, ctx in ipairs(group_context) do
    local by = ctx.by
    local value = ctx.value

    if by == "tag" then
      -- Append #tag if not already present anywhere in the line.
      local tag_with_hash = "#" .. value
      if not line:find(tag_with_hash, 1, true) then
        line = line .. " " .. tag_with_hash
      end
    elseif by == "priority" then
      -- Only inject when no priority attribute is present.
      if not has_priority(line) then
        local use_dataview = task_origin and task_origin["priority"] == "dataview"
        if use_dataview then
          line = line .. " [priority:: " .. value .. "]"
        else
          local emoji = PRIORITY_EMOJIS[value]
          if emoji then
            line = line .. " " .. emoji
          end
        end
      end
    elseif by == "status" then
      -- Look up the status symbol by name and rewrite the checkbox if needed.
      local status_mod = require("obsidian-tasks.task.status")
      local status_entry = status_mod.by_name[value]
      if status_entry then
        local new_symbol = status_entry.symbol
        local current_symbol = get_checkbox(line)
        if current_symbol ~= new_symbol then
          line = set_checkbox(line, new_symbol)
        end
      end
    end
    -- Other group types (file, folder, heading, path, …): no auto-add.
  end

  return line
end

return M
