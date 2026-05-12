-- lua/obsidian-tasks/query/run.lua
-- Query execution pipeline: filter → sort → group → limit → QueryResult.
--
-- QueryResult shape:
--   {
--     groups       = { { name = string, tasks = { Task, ... } }, ... },
--     total        = N,
--     hide_flags   = { priority = bool, due_date = bool, ... },
--     header_summary = 'not done · sorted by due asc · grouped by tags',
--     errors       = { { kind, msg, line }, ... },
--   }
--
-- Pipeline notes:
--   * filters: all filter nodes are ANDed together (task must match all).
--   * sort: comparator applied before grouping; within-group order is preserved.
--   * group: tasks are placed into groups based on group_by keys.
--     A task belonging to multiple groups (e.g. multiple tags) is duplicated.
--   * group order: locale-aware alphabetical via vim.stricmp; reverse honored.
--   * limit: total cap across all groups (TS behaviour).  Applied after grouping.
--   * errors: forwarded from ast.errors unchanged.

local M = {}

local filter_mod = require("obsidian-tasks.query.filter")
local sort_mod = require("obsidian-tasks.query.sort")
local group_mod = require("obsidian-tasks.query.group")
local hide_mod = require("obsidian-tasks.query.hide")

-- ── header summary builder ─────────────────────────────────────────────────────

local function header_summary(ast)
  local parts = {}

  -- Describe filters (heuristic short form).
  if #ast.filters > 0 then
    local descs = {}
    for _, node in ipairs(ast.filters) do
      if node.kind == "leaf" and node.filter then
        local ft = node.filter.type
        if ft == "not_done" then
          descs[#descs + 1] = "not done"
        elseif ft == "done" then
          descs[#descs + 1] = "done"
        elseif ft == "date" then
          descs[#descs + 1] = node.filter.field .. " " .. node.filter.operator .. " " .. (node.filter.value or "")
        else
          descs[#descs + 1] = ft
        end
      end
    end
    if #descs > 0 then
      parts[#parts + 1] = table.concat(descs, ", ")
    end
  end

  -- Describe sort.
  if #ast.sort_by > 0 then
    local sort_parts = {}
    for _, s in ipairs(ast.sort_by) do
      sort_parts[#sort_parts + 1] = s.key .. " " .. (s.reverse and "desc" or "asc")
    end
    parts[#parts + 1] = "sorted by " .. table.concat(sort_parts, ", ")
  end

  -- Describe group.
  if #ast.group_by > 0 then
    local group_parts = {}
    for _, g in ipairs(ast.group_by) do
      group_parts[#group_parts + 1] = g.key
    end
    parts[#parts + 1] = "grouped by " .. table.concat(group_parts, ", ")
  end

  -- Limit.
  if ast.limit then
    parts[#parts + 1] = "limit " .. ast.limit
  end

  return table.concat(parts, " · ")
end

-- ── public API ─────────────────────────────────────────────────────────────────

--- Execute a parsed query AST against an index.
---
--- @param ast            table   AST from query/parse.lua
--- @param index          table   index module (obsidian-tasks.index) — must expose tasks_in()
--- @param workspace_root string? absolute path prefix to scope results to a single vault
--- @return table  QueryResult
function M.run(ast, index, workspace_root)
  -- 0. Short-circuit on parse_error: a typo'd directive (e.g. "has tags" instead
  -- of "has tag") would otherwise be silently dropped from ast.filters and the
  -- surviving filters would run with a wider result set than intended. Render
  -- zero tasks under the error banner so the user sees the typo, not bogus rows.
  -- Other error kinds (`unsupported`, `v2_feature`) intentionally degrade-and-run.
  for _, err in ipairs(ast.errors or {}) do
    if err.kind == "parse_error" then
      return {
        groups = {},
        total = 0,
        hide_flags = require("obsidian-tasks.query.hide").make_flags(ast.hide),
        header_summary = "",
        errors = ast.errors,
        _ast_sort = ast.sort_by,
        limit = ast.limit,
      }
    end
  end

  local path_filter = workspace_root
    and require("obsidian-tasks.util.obsidian").workspace_path_filter(workspace_root)
    or nil
  local items = {} -- { task, path, line_num, _idx }
  local iter = index.tasks_in(path_filter)
  local idx = 0
  while true do
    local task, path, line_num = iter()
    if not task then
      break
    end
    idx = idx + 1
    items[#items + 1] = { task = task, path = path, line_num = line_num, _idx = idx }
  end

  -- 2. Filter.
  local predicate = filter_mod.compile_all(ast.filters)
  local filtered = {}
  for _, item in ipairs(items) do
    if predicate(item.task, item.path) then
      filtered[#filtered + 1] = item
    end
  end

  -- 3. Sort (globally before grouping; within-group order is preserved).
  local comparator = sort_mod.make_comparator(ast.sort_by)
  table.sort(filtered, comparator)

  -- 4. Group.
  --    If no group_by directives, all tasks go into a single unnamed group.
  local group_names_ordered = {} -- ordered list of unique group name strings
  local group_map = {} -- name → { tasks = [] }

  for _, item in ipairs(filtered) do
    -- Attach source metadata so layout.lua can build wikilinks and the resolver can jump.
    -- We stamp directly onto the task object; index entries are per-file so
    -- mutation is safe.  Duplicated tasks (multi-group) share the same path/line.
    item.task._src_path = item.path
    item.task._src_line = item.line_num
    local names = group_mod.resolve(item.task, item.path, ast.group_by)
    for _, name in ipairs(names) do
      if not group_map[name] then
        group_names_ordered[#group_names_ordered + 1] = name
        group_map[name] = { name = name, tasks = {} }
      end
      group_map[name].tasks[#group_map[name].tasks + 1] = item.task
    end
  end

  -- 5. Sort groups: locale-aware alphabetical.
  --    When group_by has a reverse flag, the *first* key's reverse governs group order.
  local group_reverse = #ast.group_by > 0 and ast.group_by[1].reverse or false
  table.sort(group_names_ordered, function(a, b)
    local cmp = vim.stricmp(a, b)
    if group_reverse then
      return cmp > 0
    end
    return cmp < 0
  end)

  -- 6. Apply limit (total cap across all groups).
  local groups = {}
  local total = 0

  if ast.limit then
    local remaining = ast.limit
    for _, name in ipairs(group_names_ordered) do
      if remaining <= 0 then
        break
      end
      local g = group_map[name]
      local slice = {}
      for i = 1, math.min(#g.tasks, remaining) do
        slice[i] = g.tasks[i]
        total = total + 1
      end
      remaining = remaining - #slice
      groups[#groups + 1] = { name = name, tasks = slice }
    end
  else
    for _, name in ipairs(group_names_ordered) do
      local g = group_map[name]
      total = total + #g.tasks
      groups[#groups + 1] = { name = name, tasks = g.tasks }
    end
  end

  -- 7. Hide flags.
  local hide_flags = hide_mod.make_flags(ast.hide)

  -- 8. Header summary.
  local summary = header_summary(ast)

  return {
    groups = groups,
    total = total,
    hide_flags = hide_flags,
    header_summary = summary,
    errors = ast.errors or {},
    -- Exposed for render/layout.lua footer formatting.
    _ast_sort = ast.sort_by,
    limit = ast.limit,
  }
end

return M
