-- lua/obsidian-tasks/render/layout.lua
-- Pure function: QueryResult → list of render-line records.
--
-- Each record has shape:
--   { kind, text, src_path, src_line, src_hash, source_text_hash, indent }
--
-- kind ∈ 'group_header' | 'task' | 'footer' | 'error'
--
-- Only 'task' records carry src_path / src_line / src_hash / source_text_hash.
-- All other kinds set those to nil.
--
-- src_hash          — sha256[:16] of the RENDERED task text (includes wikilink
--                     when backlinks are visible).  Stored in draw.lua em_map.
--                     Currently computed but not read by any live caller
--                     (reserved for future stale-render detection).
-- source_text_hash  — sha256[:16] of the task text BEFORE the wikilink is
--                     appended.  Matches the verbatim source-file line content
--                     (including all fields, even those hidden by hide flags).
--                     Currently computed but not read by any live caller
--                     (reserved for future stale-jump content-match scanning).

local M = {}

local serialize_mod = require("obsidian-tasks.task.serialize")

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

--- Compute a stable 16-hex-char hash for a string.
--- @param text string
--- @return string  16 hex characters
local function src_hash(text)
  local full = vim.fn.sha256(text)
  return full:sub(1, 16)
end

--- Strip fields from a Task (shallow copy of fields table) according to
--- hide_flags.  Returns a modified task copy — does NOT mutate the original.
--- @param task  table  Task returned by parse.lua
--- @param hide  table  hide_flags from QueryResult
--- @return table  modified task copy
local function apply_hide_flags(task, hide)
  -- Map from hide_flag key → task.fields key(s) to nil out.
  -- Also handle tags separately.
  local FIELD_MAP = {
    priority = { "priority" },
    due_date = { "due" },
    scheduled_date = { "scheduled" },
    start_date = { "start" },
    done_date = { "done" },
    created_date = { "created" },
    cancelled_date = { "cancelled" },
    recurrence_rule = { "recurrence" },
    id = { "id" },
    depends_on = { "depends_on" },
    on_completion = { "on_completion" },
  }

  -- Shallow-copy fields so we don't mutate the original task.
  local new_fields = {}
  for k, v in pairs(task.fields) do
    new_fields[k] = v
  end

  -- Shallow-copy _origin as well.
  local new_origin = {}
  for k, v in pairs(task._origin or {}) do
    new_origin[k] = v
  end

  -- Apply field hides.
  for flag, keys in pairs(FIELD_MAP) do
    if hide[flag] then
      for _, k in ipairs(keys) do
        new_fields[k] = nil
        new_origin[k] = nil
      end
    end
  end

  -- Tags: zero them out if hide.tags.
  local new_tags = task.tags
  if hide.tags then
    new_tags = {}
  end

  return {
    indent = task.indent,
    marker = task.marker,
    status_symbol = task.status_symbol,
    description = task.description,
    fields = new_fields,
    tags = new_tags,
    _origin = new_origin,
  }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the ordered list of render-line records from a QueryResult.
---
--- @param query_result table  QueryResult as returned by query/run.lua
--- @param opts?        table  optional opts (currently unused; reserved)
--- @return table[]  ordered list of render-line records
function M.layout(query_result, opts)
  opts = opts or {}
  local hide = query_result.hide_flags or {}
  local lines = {}

  local total = query_result.total or 0

  -- ── 1. Error lines ─────────────────────────────────────────────────────────
  for _, err in ipairs(query_result.errors or {}) do
    local err_text = "▼ " .. (err.kind or "error") .. ": " .. (err.msg or "unknown error")
    lines[#lines + 1] = {
      kind = "error",
      text = err_text,
      src_path = nil,
      src_line = nil,
      src_hash = nil,
      indent = "",
    }
  end

  -- ── 2. Groups (group_header + task lines) ─────────────────────────────────
  local has_groups = #(query_result.groups or {}) > 0
  local multi_group = has_groups and (#query_result.groups > 1 or query_result.groups[1].name ~= "")

  for _, group in ipairs(query_result.groups or {}) do
    -- Group header: only emit when there is a named group.
    if group.name and group.name ~= "" then
      lines[#lines + 1] = {
        kind = "group_header",
        text = "## " .. group.name,
        src_path = nil,
        src_line = nil,
        src_hash = nil,
        indent = "",
      }
    elseif multi_group then
      -- Unnamed group in a multi-group context still gets a header.
      lines[#lines + 1] = {
        kind = "group_header",
        text = "## (no group)",
        src_path = nil,
        src_line = nil,
        src_hash = nil,
        indent = "",
      }
    end

    -- Task lines.
    for _, task in ipairs(group.tasks or {}) do
      -- Apply hide flags to a copy of the task.
      local visible_task = apply_hide_flags(task, hide)

      -- Serialize using preserve format (keeps original emoji/dataview style).
      local task_text = serialize_mod.serialize(visible_task, { format = "preserve" })

      -- source_text_hash must match the unmodified source-file line so that
      -- keymap.lua content-match scan can locate the task regardless of which
      -- fields are hidden.  Use task.raw_line (the verbatim original text
      -- preserved by parse.lua) rather than task_text (post-hide-flags
      -- serialized text, which omits hidden fields and therefore diverges from
      -- the source file when any field-hide flag is active).
      -- Fall back to task_text only for synthesized tasks that lack raw_line.
      local source_text_hash = task.raw_line and src_hash(task.raw_line) or src_hash(task_text)

      -- Append wikilink backlink unless hidden.
      -- src_path is set by the render orchestrator on each task before calling layout.
      -- If absent (e.g. in tests or when orchestrator hasn't populated it), skip the wikilink.
      local path = task._src_path
      if path and not hide.backlinks then
        local basename = vim.fn.fnamemodify(path, ":t:r")
        task_text = task_text .. " [[" .. basename .. "]]"
      end

      -- src_hash is the hash of the final RENDERED text (with wikilink when
      -- present).  edit.lua diff uses this to detect in-place edits in the
      -- render buffer, where task lines DO include the wikilink.
      local hash = src_hash(task_text)

      lines[#lines + 1] = {
        kind = "task",
        text = task_text,
        src_path = path,
        src_line = task._src_line,
        src_hash = hash,
        source_text_hash = source_text_hash,
        indent = task.indent or "",
      }
    end
  end

  -- ── 3. Footer ─────────────────────────────────────────────────────────────
  local footer_parts = {}

  -- Sort description.
  local ast_sort = query_result._ast_sort -- may be nil if orchestrator doesn't set it
  if ast_sort and #ast_sort > 0 then
    local sort_strs = {}
    for _, s in ipairs(ast_sort) do
      sort_strs[#sort_strs + 1] = s.key .. " " .. (s.reverse and "desc" or "asc")
    end
    footer_parts[#footer_parts + 1] = "sorted: " .. table.concat(sort_strs, ", ")
  end

  -- Limit.
  local limit = query_result.limit
  if limit then
    footer_parts[#footer_parts + 1] = "limit " .. limit
  end

  -- Total results count (omit when task_count hidden).
  if not hide.task_count then
    local count_str = total == 1 and "1 result" or (total .. " results")
    footer_parts[#footer_parts + 1] = count_str
  end

  local footer_text
  if #footer_parts > 0 then
    footer_text = "─ " .. table.concat(footer_parts, " │ ") .. " ─"
  else
    footer_text = "─"
  end

  lines[#lines + 1] = {
    kind = "footer",
    text = footer_text,
    src_path = nil,
    src_line = nil,
    src_hash = nil,
    indent = "",
  }

  return lines
end

return M
