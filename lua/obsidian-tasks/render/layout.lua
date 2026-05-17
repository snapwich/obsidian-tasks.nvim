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

  -- Shallow-copy _origin, _raw_fields, _errors as well.  _raw_fields and
  -- _errors are populated by the lenient parser when a field value fails
  -- validation (e.g. `📅 someday`); the serializer falls back to _raw_fields
  -- so invalid values still round-trip, and downstream renderers highlight
  -- their byte ranges via serialize_with_meta.  Dropping them here would
  -- silently strip invalid fields from the rendered output.
  local new_origin = {}
  for k, v in pairs(task._origin or {}) do
    new_origin[k] = v
  end
  local new_raw_fields = {}
  for k, v in pairs(task._raw_fields or {}) do
    new_raw_fields[k] = v
  end
  local new_errors = {}
  for k, v in pairs(task._errors or {}) do
    new_errors[k] = v
  end

  -- Apply field hides: nil out both parsed values AND raw/error metadata so
  -- a `hide due_date` clause hides invalid due fields too (otherwise the
  -- invalid value would still render).
  for flag, keys in pairs(FIELD_MAP) do
    if hide[flag] then
      for _, k in ipairs(keys) do
        new_fields[k] = nil
        new_origin[k] = nil
        new_raw_fields[k] = nil
        new_errors[k] = nil
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
    raw_line = task.raw_line,
    _origin = new_origin,
    _raw_fields = new_raw_fields,
    _errors = new_errors,
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
  --
  -- Two resolution paths:
  --  (1) New shape: linger entries carry ent.prior_group_name + (optionally)
  --      ent.prior_index_within_group already-keyed to a specific group from
  --      the prior render.  Use them directly — one entry, one group.
  --  (2) Legacy shape: no prior_group_name → resolve via group_mod.  May
  --      resolve to multiple group names (group-by-tags expansion); the same
  --      linger entry appears in each bucket and lands at the bottom of each
  --      group (no prior_index → unindexed fallback path in emit_group_body).
  local lingers_by_group = {}
  for _, ent in ipairs(lingers) do
    if ent.prior_group_name ~= nil then
      local name = ent.prior_group_name
      lingers_by_group[name] = lingers_by_group[name] or {}
      table.insert(lingers_by_group[name], ent)
    else
      local names = group_mod.resolve(ent.task, ent.src_path, group_by)
      for _, name in ipairs(names) do
        lingers_by_group[name] = lingers_by_group[name] or {}
        table.insert(lingers_by_group[name], ent)
      end
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

  --- Build a render record for a lingered task in *group_name* at
  --- *group_index* (0-based position within the rendered group body).
  --- @param ent        table
  --- @param group_name string
  --- @param group_index integer
  --- @return table
  local function build_linger_line(ent, group_name, group_index)
    local visible_task = apply_hide_flags(ent.task, hide)
    local ser = serialize_mod.serialize_with_meta(visible_task, { format = "preserve" })
    local task_text = ser.text
    local invalid_ranges = ser.invalid_ranges
    local source_text_hash = ent.task.raw_line and src_hash(ent.task.raw_line) or src_hash(task_text)
    local path = ent.src_path or ent.task._src_path
    if path and not hide.backlinks then
      local basename = vim.fn.fnamemodify(path, ":t:r")
      task_text = task_text .. " [[" .. basename .. "]]"
    end
    local hash = src_hash(task_text)
    return {
      kind = "task",
      text = task_text,
      src_path = path,
      src_line = ent.src_line or ent.task._src_line,
      src_hash = hash,
      source_text_hash = source_text_hash,
      -- source_text is the VERBATIM source-file line content (preserved by
      -- parse.lua as task.raw_line).  draw.lua uses this as managed.task_text
      -- so the drift check compares like-for-like: the canonicalized render
      -- often reorders fields per FIELD_ORDER, which would falsely trigger
      -- drift against a source whose field order differs.
      source_text = ent.task.raw_line,
      indent = ent.task.indent or "",
      group_name = group_name,
      group_index = group_index,
      invalid_ranges = (invalid_ranges and #invalid_ranges > 0) and invalid_ranges or nil,
      -- Lingered rows are always dimmed; `linger` retains the state-tracking
      -- bit so render/init.lua + tests can distinguish them from live-completed.
      linger = true,
      dim = true,
    }
  end

  --- Build a render record for a live task in *group_name* at *group_index*.
  --- @param task        table
  --- @param group_name  string
  --- @param group_index integer
  --- @return table
  local function build_live_line(task, group_name, group_index)
    local visible_task = apply_hide_flags(task, hide)
    local ser = serialize_mod.serialize_with_meta(visible_task, { format = "preserve" })
    local task_text = ser.text
    local invalid_ranges = ser.invalid_ranges
    local source_text_hash = task.raw_line and src_hash(task.raw_line) or src_hash(task_text)
    local path = task._src_path
    if path and not hide.backlinks then
      local basename = vim.fn.fnamemodify(path, ":t:r")
      task_text = task_text .. " [[" .. basename .. "]]"
    end
    local hash = src_hash(task_text)
    return {
      kind = "task",
      text = task_text,
      src_path = path,
      src_line = task._src_line,
      src_hash = hash,
      source_text_hash = source_text_hash,
      -- VERBATIM source-file line (preserved by parse.lua as task.raw_line).
      -- See build_linger_line for why this matters (drift check correctness).
      source_text = task.raw_line,
      indent = task.indent or "",
      group_name = group_name,
      group_index = group_index,
      invalid_ranges = (invalid_ranges and #invalid_ranges > 0) and invalid_ranges or nil,
      -- Mark completed-live rows as dim so draw applies the linger highlight.
      dim = dim_completed and status_mod.is_completed(task.status_symbol) or nil,
    }
  end

  --- Emit a group's body (task rows + lingered rows) into the *lines* output.
  --- Interleaves lingers at their prior_index_within_group, dedups live tasks
  --- against active lingers (per-block-query: linger wins, live suppressed).
  ---
  --- @param group_name      string  current group name (may be "")
  --- @param live_tasks      table[]  partitioned live task list for this group
  --- @param linger_entries  table[]|nil  linger entries pre-bucketed for this group
  local function emit_group_body(group_name, live_tasks, linger_entries)
    linger_entries = linger_entries or {}
    consumed_linger_groups[group_name] = true

    -- Build dedup key set from active lingers in this group.
    local linger_keys = {}
    for _, ent in ipairs(linger_entries) do
      local path = ent.src_path or (ent.task and ent.task._src_path) or ""
      local line_nr = ent.src_line or (ent.task and ent.task._src_line) or 0
      linger_keys[path .. ":" .. tostring(line_nr)] = true
    end

    -- Filter live tasks: drop those whose (src_path, src_line) matches an active
    -- linger entry in this group (Q8 dedup: linger wins within same query).
    local filtered_live = {}
    for _, task in ipairs(live_tasks) do
      local key = (task._src_path or "") .. ":" .. tostring(task._src_line or 0)
      if not linger_keys[key] then
        filtered_live[#filtered_live + 1] = task
      end
    end

    -- Partition linger entries: indexed (have prior_index_within_group) get
    -- spliced at their captured position; unindexed (legacy / no prior render
    -- context) fall back to appending at the end of the group.
    local indexed, unindexed = {}, {}
    for _, ent in ipairs(linger_entries) do
      if ent.prior_index_within_group ~= nil then
        indexed[#indexed + 1] = ent
      else
        unindexed[#unindexed + 1] = ent
      end
    end
    table.sort(indexed, function(a, b)
      return a.prior_index_within_group < b.prior_index_within_group
    end)

    -- Interleave: walk filtered_live with running output_idx.  Before emitting
    -- each live task, drain indexed lingers whose prior_index ≤ output_idx
    -- (linger holds its prior slot; live task gets bumped one position).
    local output_idx = 0
    local linger_i = 1
    for _, task in ipairs(filtered_live) do
      while linger_i <= #indexed and indexed[linger_i].prior_index_within_group <= output_idx do
        lines[#lines + 1] = build_linger_line(indexed[linger_i], group_name, output_idx)
        linger_i = linger_i + 1
        output_idx = output_idx + 1
      end
      lines[#lines + 1] = build_live_line(task, group_name, output_idx)
      output_idx = output_idx + 1
    end

    -- Remaining indexed lingers whose prior_index exceeded the live count.
    while linger_i <= #indexed do
      lines[#lines + 1] = build_linger_line(indexed[linger_i], group_name, output_idx)
      linger_i = linger_i + 1
      output_idx = output_idx + 1
    end

    -- Unindexed (legacy fallback) lingers appended at end.
    for _, ent in ipairs(unindexed) do
      lines[#lines + 1] = build_linger_line(ent, group_name, output_idx)
      output_idx = output_idx + 1
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
    local group_name = group.name or ""
    -- Group header: only emit when there is a named group.
    if group_name ~= "" then
      lines[#lines + 1] = {
        kind = "group_header",
        text = "## " .. group_name,
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

    -- Interleaved emission: live tasks partitioned by completion, lingers
    -- spliced at prior_index_within_group, dedup of live tasks that match
    -- active lingers in this group.
    emit_group_body(group_name, partition_completed(group.tasks or {}), lingers_by_group[group_name])
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
      emit_group_body(name, {}, lingers_by_group[name])
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
