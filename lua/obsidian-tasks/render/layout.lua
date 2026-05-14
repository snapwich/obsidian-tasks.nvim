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
local group_mod = require("obsidian-tasks.query.group")
local status_mod = require("obsidian-tasks.task.status")

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
--- @param opts?        table  optional opts:
---                              opts.lingers       — list of linger entries
---                                                   { task, src_path, src_line,
---                                                     source_text_hash }
---                              opts.group_by      — ast.group_by (used to resolve
---                                                   each linger to its group(s))
---                              opts.dim_completed — sink + dim live tasks whose
---                                                   status is Done/Cancelled
--- @return table[]  ordered list of render-line records
function M.layout(query_result, opts)
  opts = opts or {}
  local hide = query_result.hide_flags or {}
  local lines = {}

  local lingers = opts.lingers or {}
  local group_by = opts.group_by or {}
  local dim_completed = opts.dim_completed ~= false

  -- Pre-resolve each linger to its set of group names (empty string when no
  -- group_by — matches the unnamed group used by query_run for ungrouped
  -- results).  Index by group name for cheap lookup during the layout walk.
  local lingers_by_group = {}
  for _, ent in ipairs(lingers) do
    local names = group_mod.resolve(ent.task, ent.src_path, group_by)
    for _, name in ipairs(names) do
      lingers_by_group[name] = lingers_by_group[name] or {}
      table.insert(lingers_by_group[name], ent)
    end
  end

  local total = query_result.total or 0

  -- ── 0. Explanation line (when `explain` keyword is in the query) ────────
  if query_result.explain then
    local exp_text = "ℹ explain: "
      .. (query_result.header_summary ~= "" and query_result.header_summary or "(no filters)")
    lines[#lines + 1] = {
      kind = "explain",
      text = exp_text,
      src_path = nil,
      src_line = nil,
      src_hash = nil,
      indent = "",
    }
  end

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
  -- Track which linger group-names get drained by the live-groups pass so any
  -- leftover lingers (whose previous group has no live members) can be emitted
  -- as ghost groups at the end.
  local consumed_linger_groups = {}

  local live_groups = query_result.groups or {}
  -- Ghost groups: linger group-names that are NOT present in the live groups.
  -- Sorted alphabetically for stable rendering.
  local ghost_names = {}
  do
    local live_set = {}
    for _, g in ipairs(live_groups) do
      live_set[g.name or ""] = true
    end
    for name in pairs(lingers_by_group) do
      if not live_set[name] then
        ghost_names[#ghost_names + 1] = name
      end
    end
    table.sort(ghost_names, function(a, b)
      return vim.stricmp(a, b) < 0
    end)
  end

  local has_groups = #live_groups > 0 or #ghost_names > 0
  local total_groups = #live_groups + #ghost_names
  local first_live_name = live_groups[1] and live_groups[1].name or nil
  local multi_group = has_groups and (total_groups > 1 or (first_live_name ~= nil and first_live_name ~= ""))

  --- Append linger task records that resolve to *group_name*.
  --- @param group_name string
  local function append_lingers_for(group_name)
    local entries = lingers_by_group[group_name]
    if not entries then
      return
    end
    consumed_linger_groups[group_name] = true
    for _, ent in ipairs(entries) do
      local visible_task = apply_hide_flags(ent.task, hide)
      local task_text = serialize_mod.serialize(visible_task, { format = "preserve" })
      local source_text_hash = ent.task.raw_line and src_hash(ent.task.raw_line) or src_hash(task_text)
      local path = ent.src_path or ent.task._src_path
      if path and not hide.backlinks then
        local basename = vim.fn.fnamemodify(path, ":t:r")
        task_text = task_text .. " [[" .. basename .. "]]"
      end
      local hash = src_hash(task_text)
      lines[#lines + 1] = {
        kind = "task",
        text = task_text,
        src_path = path,
        src_line = ent.src_line or ent.task._src_line,
        src_hash = hash,
        source_text_hash = source_text_hash,
        indent = ent.task.indent or "",
        -- Lingered rows are always dimmed; `linger` retains the state-tracking
        -- bit so render/init.lua + tests can distinguish them from live-completed.
        linger = true,
        dim = true,
      }
    end
  end

  --- Partition a group's task list into [non_completed..., completed...] while
  --- preserving the input order within each tier.  No-op (returns the input
  --- unchanged) when dim_completed is false.
  --- @param tasks table[]
  --- @return table[]
  local function partition_completed(tasks)
    if not dim_completed then
      return tasks
    end
    local active, done = {}, {}
    for _, t in ipairs(tasks) do
      if status_mod.is_completed(t.status_symbol) then
        done[#done + 1] = t
      else
        active[#active + 1] = t
      end
    end
    if #done == 0 then
      return tasks
    end
    -- Concatenate active first, then completed.
    for _, t in ipairs(done) do
      active[#active + 1] = t
    end
    return active
  end

  for _, group in ipairs(live_groups) do
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

    -- Task lines.  Completed-status tasks are sunk to the bottom of the
    -- group (after the active ones) when dim_completed is on.
    for _, task in ipairs(partition_completed(group.tasks or {})) do
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
        -- Mark completed-live rows as dim so draw applies the linger highlight.
        dim = dim_completed and status_mod.is_completed(task.status_symbol) or nil,
      }
    end

    -- Lingered tasks for this group (after live members, in completion order).
    append_lingers_for(group.name or "")
  end

  -- Ghost groups: emit a header and the linger rows for each name that had no
  -- corresponding live group in the current result set.
  for _, name in ipairs(ghost_names) do
    if not consumed_linger_groups[name] then
      if name ~= "" then
        lines[#lines + 1] = {
          kind = "group_header",
          text = "## " .. name,
          src_path = nil,
          src_line = nil,
          src_hash = nil,
          indent = "",
        }
      elseif multi_group then
        lines[#lines + 1] = {
          kind = "group_header",
          text = "## (no group)",
          src_path = nil,
          src_line = nil,
          src_hash = nil,
          indent = "",
        }
      end
      append_lingers_for(name)
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
