-- lua/obsidian-tasks/render/edit_util.lua
-- Shared text-shaping helpers for the dashboard flush pipeline.
--
-- Extracted mechanically from render/edit.lua so the orchestrator (edit.lua),
-- the batch/write phase (edit_apply.lua), and the INSERT-reconciliation phase
-- (edit_insert.lua) share one implementation.  Behavior is byte-identical to
-- the former edit.lua locals.

local M = {}

--- Strip the wikilink suffix ' [[<target>]]' from *text* when it matches the
--- *target* layout appended at render time ('basename' or 'basename|alias').
--- *target* is nil when the row was rendered without a suffix (no source path,
--- or a `hide backlinks` query), in which case *text* is returned unchanged.
---
--- Delegates to render/wikilink.strip_expected_suffix so the flush path and the
--- public helper share a single implementation (unit tests for strip_expected_suffix
--- therefore cover the code that actually runs during flush).
---
--- @param text   string
--- @param target string|nil  rendered wikilink target (meta.wikilink_target)
--- @return string
function M.strip_wikilink_suffix(text, target)
  if not target or target == "" then
    return text
  end
  return require("obsidian-tasks.render.wikilink").strip_expected_suffix(text, target)
end

--- Q2 date normalization: replace natural-language date values with ISO dates.
---
--- Parses *text* as a task.  For each date field whose value failed ISO
--- validation (stored in task._raw_fields), attempts to convert the value via
--- cmp/date_nl.lua.  If successful, promotes the value to task.fields and
--- re-serializes the task.  Returns *text* unchanged when no normalization is
--- needed (including when parse returns nil, e.g. for a bare description).
---
--- Re-serialization preserves the per-field format (emoji vs dataview) via
--- format="preserve".  Field ORDER in the output follows FIELD_ORDER (the
--- canonical order from serialize.lua) — this is an acceptable side effect of
--- parse-and-reserialize; the locked Q2 decision explicitly permits value
--- normalization while accepting that structural re-ordering is a by-product
--- when NL dates are present.
---
--- @param text string
--- @return string
function M.normalize_date_fields(text)
  local task_parse = require("obsidian-tasks.task.parse")
  local task_serialize = require("obsidian-tasks.task.serialize")
  local date_nl = require("obsidian-tasks.cmp.date_nl")
  local fields_mod = require("obsidian-tasks.task.fields")

  local task = task_parse.parse(text)
  if not task then
    return text
  end

  local raw_fields = task._raw_fields or {}
  local normalized = false

  for _, f in ipairs(fields_mod.fields) do
    if f.kind == "date" then
      local raw_val = raw_fields[f.key]
      if raw_val ~= nil then
        local iso = date_nl.parse(raw_val)
        if iso then
          -- Promote from invalid → valid
          task.fields[f.key] = iso
          task._raw_fields[f.key] = nil
          if task._errors then
            task._errors[f.key] = nil
          end
          if task._invalid_ranges then
            task._invalid_ranges[f.key] = nil
          end
          normalized = true
        end
      end
    end
  end

  if not normalized then
    return text
  end

  -- Re-serialize preserving emoji/dataview format per field.
  return task_serialize.serialize(task)
end

--- Count the leading whitespace characters in *line*.
--- @param line string
--- @return integer
function M.indent_of(line)
  if not line then
    return 0
  end
  local s = line:match("^(%s*)")
  return s and #s or 0
end

--- Compute the re-added structural prefix for a REPAIR_AND_MUTATE row and
--- return the repaired text plus the number of characters inserted at the start.
---
--- @param text string  the write_text after wikilink stripping
--- @return string repaired_text, integer prefix_inserted
function M.repair_prefix(text)
  local has_bullet = text:match("^%s*[-*+]%s") ~= nil
  local has_checkbox = text:match("%[.%]") ~= nil

  if has_bullet and has_checkbox then
    -- Already well-formed: idempotent no-op.
    return text, 0
  elseif not has_bullet and not has_checkbox then
    -- Neither present: prepend the full "- [ ] " prefix.
    return "- [ ] " .. text, 6
  elseif not has_checkbox then
    -- Has bullet but no checkbox: insert "[ ] " right after the bullet + space.
    local after_bullet = text:match("^%s*[-*+]%s()")
    if after_bullet then
      return text:sub(1, after_bullet - 1) .. "[ ] " .. text:sub(after_bullet), 4
    end
    -- Fallback (shouldn't happen given has_bullet is true).
    return "- [ ] " .. text, 6
  else
    -- Has checkbox but no bullet: prepend "- ".
    return "- " .. text, 2
  end
end

return M
