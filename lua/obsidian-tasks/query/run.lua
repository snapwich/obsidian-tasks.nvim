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
--     Opt-in override: `ast.sort_groups_by` (from `# nvim: sort groups by <key>`)
--     orders groups hierarchically by their best member instead.  See step 5.
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

  -- Describe group ordering (`# nvim: sort groups by <key>`).  Ascending is the
  -- default and stays unmarked ("groups sorted by priority"); only `reverse`
  -- adds a suffix ("groups sorted by priority desc").
  local sort_groups_by = ast.sort_groups_by or {}
  if #sort_groups_by > 0 then
    local group_sort_parts = {}
    for _, s in ipairs(sort_groups_by) do
      group_sort_parts[#group_sort_parts + 1] = s.reverse and (s.key .. " desc") or s.key
    end
    parts[#parts + 1] = "groups sorted by " .. table.concat(group_sort_parts, ", ")
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

  local obsidian = require("obsidian-tasks.util.obsidian")
  local path_filter = workspace_root and obsidian.workspace_path_filter(workspace_root) or nil

  -- Strip the workspace-root prefix so filter / sort / group see a
  -- vault-relative path matching Obsidian's `task.path`.  Queries like
  -- `path includes /daily` then resolve identically on the desktop vault
  -- and in our dashboards — a v1 portability requirement.  The original
  -- absolute path is preserved on `_src_path` for render/jump.
  --
  -- workspace_root may arrive as an obsidian.nvim Path object (with a
  -- :__tostring metamethod) rather than a plain string; coerce to string
  -- before any string ops.
  -- Both prefix and abs_path are normalized to forward slashes so the strip
  -- works on Windows, where rg-derived index keys are mixed-separator.
  local ws_prefix
  if workspace_root and workspace_root ~= "" then
    local root_str = obsidian.normalize(tostring(workspace_root))
    if root_str ~= "" then
      ws_prefix = root_str
      if ws_prefix:sub(-1) ~= "/" then
        ws_prefix = ws_prefix .. "/"
      end
    end
  end
  local function to_relative(abs_path)
    if not ws_prefix then
      return abs_path
    end
    local norm = obsidian.normalize(abs_path)
    if norm:sub(1, #ws_prefix) == ws_prefix then
      return norm:sub(#ws_prefix + 1)
    end
    return abs_path
  end

  local items = {} -- { task, path = vault-relative, abs_path, line_num, _idx }
  local iter = index.tasks_in(path_filter)
  local idx = 0
  while true do
    local task, abs_path, line_num = iter()
    if not task then
      break
    end
    idx = idx + 1
    items[#items + 1] = {
      task = task,
      path = to_relative(abs_path), -- used by filter/sort/group
      abs_path = abs_path, -- preserved for render/jump
      line_num = line_num,
      _idx = idx,
    }
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
  local group_map = {} -- name → { name, tasks = {}, segments, rep }

  -- `sort_groups_by` is opt-in (`# nvim: sort groups by <key>`).  When it is
  -- absent, nothing below allocates and step 5 takes the historical
  -- alphabetical path unchanged.
  local sort_groups_by = ast.sort_groups_by or {}
  local order_by_member = #sort_groups_by > 0

  -- Chain used to pick each group's best member.  It is deliberately NOT
  -- `sort_groups_by` as written:
  --
  --   * `reverse` is STRIPPED.  `reverse` reverses the order of the GROUPS, not
  --     the meaning of "best member".  Honouring it here too would pick each
  --     group's WORST member and then compare those worst members backwards —
  --     the two inversions cancel and `reverse` becomes a no-op for every group
  --     with more than one task.  Reverse is applied once, in step 5, when the
  --     representatives are compared.
  --   * `ast.sort_by` is APPENDED.  Members tied on the group chain are the
  --     common case; without this the tie would be settled by the comparator's
  --     `_idx` fallback, i.e. by index-iteration order, which step 5 would then
  --     amplify into the group order.  Selecting under the full concatenated
  --     chain keeps the representative — and hence the group order —
  --     independent of the order the index happens to emit tasks in.
  local rep_chain = nil
  if order_by_member then
    rep_chain = {}
    for _, directive in ipairs(sort_groups_by) do
      rep_chain[#rep_chain + 1] = { key = directive.key, reverse = false }
    end
    for _, directive in ipairs(ast.sort_by) do
      rep_chain[#rep_chain + 1] = directive
    end
  end

  for _, item in ipairs(filtered) do
    -- _src_path must remain ABSOLUTE — render uses it to read/write disk
    -- and to resolve buffer references.  Filter/sort/group operate on the
    -- vault-relative `item.path` set above.
    item.task._src_path = item.abs_path
    item.task._src_line = item.line_num
    for _, membership in ipairs(group_mod.resolve_detailed(item.task, item.path, ast.group_by)) do
      local g = group_map[membership.name]
      if not g then
        group_names_ordered[#group_names_ordered + 1] = membership.name
        g = { name = membership.name, tasks = {}, segments = membership.segments }
        group_map[membership.name] = g
      end
      g.tasks[#g.tasks + 1] = item.task
      -- Single linear pass per group — never sort a group's members here.
      -- `rep` is the run.lua WRAPPER (task/path/_idx/_random), which is what
      -- sort.lua's comparators read.  Replace only on a STRICT improvement
      -- under `rep_chain`, and compare with sort_mod.rank so `_idx` never
      -- decides (make_comparator would end the chain with it).
      if rep_chain and (g.rep == nil or sort_mod.rank(rep_chain, item, g.rep) < 0) then
        g.rep = item
      end
    end
  end

  -- 5. Sort groups.
  if not order_by_member then
    -- Default: locale-aware alphabetical.
    -- When group_by has a reverse flag, the *first* key's reverse governs group order.
    local group_reverse = #ast.group_by > 0 and ast.group_by[1].reverse or false
    table.sort(group_names_ordered, function(a, b)
      local cmp = vim.stricmp(a, b)
      if group_reverse then
        return cmp > 0
      end
      return cmp < 0
    end)
  else
    -- Opt-in: order groups by their best member under `sort_groups_by`.
    --
    -- Ordering is HIERARCHICAL — level 1 first, then level 2 within each level-1
    -- cohort, and so on — because the flat "## a / b" headers rely on groups
    -- sharing a prefix staying adjacent.  We walk the SEGMENT arrays returned by
    -- group.resolve_detailed rather than splitting the joined name on " / ": a
    -- segment can itself contain " / " (a `heading` group like
    -- "## Design / Build"), so a re-split would slice such groups at the wrong
    -- place and scramble their level assignment.
    --
    -- Level i cannot be ordered by each group's OWN best member: several groups
    -- may share a level-i prefix, and the header for that prefix must sit
    -- wherever its best member — over the whole cohort — belongs.  So pre-compute
    -- the best member per prefix cohort.  Prefix keys join with "\0", never
    -- " / ", for the same reason: "\0" cannot occur in a group name, so distinct
    -- prefixes stay distinct.
    local cohort_rep = {}
    for _, name in ipairs(group_names_ordered) do
      local g = group_map[name]
      local prefix = {}
      for i, seg in ipairs(g.segments) do
        prefix[i] = seg
        local key = table.concat(prefix, "\0")
        local cur = cohort_rep[key]
        -- Same chain as the per-group pass above: a cohort candidate tied on
        -- `sort_groups_by` must still be settled by `ast.sort_by`, otherwise the
        -- cohort keeps whichever group happened to be created first and step 5
        -- compares a stale representative.
        if cur == nil or sort_mod.rank(rep_chain, g.rep, cur) < 0 then
          cohort_rep[key] = g.rep
        end
      end
    end

    table.sort(group_names_ordered, function(a, b)
      local sa, sb = group_map[a].segments, group_map[b].segments
      local prefix_a, prefix_b = {}, {}
      for i = 1, math.min(#sa, #sb) do
        prefix_a[i], prefix_b[i] = sa[i], sb[i]
        if sa[i] ~= sb[i] then
          local ra = cohort_rep[table.concat(prefix_a, "\0")]
          local rb = cohort_rep[table.concat(prefix_b, "\0")]
          local r = 0
          if ra and rb then
            -- Ties are the common case (many groups share a top-priority task),
            -- so fall through to the task-level `sort by` chain before giving up.
            r = sort_mod.rank(sort_groups_by, ra, rb)
            if r == 0 then
              r = sort_mod.rank(ast.sort_by, ra, rb)
            end
          end
          if r == 0 then
            -- Same tiebreak the alphabetical path uses, but on the SEGMENT.
            r = vim.stricmp(sa[i], sb[i])
          end
          if r == 0 then
            -- Distinct segments that stricmp calls equal (case-only
            -- differences): byte-compare so the ordering stays total.
            -- table.sort is not stable and needs a strict weak ordering.
            r = sa[i] < sb[i] and -1 or 1
          end
          -- Per-level reverse: under member ordering each group_by key's own
          -- `reverse` flips ordering at ITS OWN level.  (The alphabetical path
          -- above keeps the historical first-key-only semantics.)
          if ast.group_by[i] and ast.group_by[i].reverse then
            r = -r
          end
          return r < 0
        end
      end
      -- Every shared level matched: same group (names are unique keys).
      return false
    end)
  end

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

  -- 9. Tree assembly (Phase 4 wiring).
  --
  -- The tree branch is INTENTIONALLY unmistakable: it fires ONLY when
  -- `ast.tree` is true (set by `show tree`).  When false, `tree_rows` is left
  -- nil and render/layout.lua takes the EXACT flat path it always has — the
  -- groups walk is byte-identical and never routes through tree.assemble.
  --
  -- When ON: route the matched `groups` (the left-most matched tasks, already
  -- filtered/sorted/grouped/limited above) through tree.assemble together with
  -- the index's per-file node accessor (index.nodes_for).  assemble() drags in
  -- each matched task's descendant subtree (child tasks + bullets + interspersed
  -- blanks), dedups per group, and returns ordered ROWS that layout renders as
  -- nested, foldable buffer lines.
  local tree_rows = nil
  if ast.tree then
    local tree_mod = require("obsidian-tasks.query.tree")
    tree_rows = tree_mod.assemble(groups, function(p)
      return index.nodes_for(p)
    end, { tree = true })
  end

  return {
    groups = groups,
    total = total,
    hide_flags = hide_flags,
    header_summary = summary,
    errors = ast.errors or {},
    -- Exposed for render/layout.lua footer formatting.
    _ast_sort = ast.sort_by,
    limit = ast.limit,
    -- `explain` keyword: when true, the renderer should prepend a
    -- human-readable summary of the parsed query above the result list.
    -- The summary text is already in header_summary.
    explain = ast.explain or false,
    -- Phase 4: when `show tree` is on, the assembled subtree rows.  nil in the
    -- flat (default) case — layout.lua branches on its presence, so a nil here
    -- keeps the flat render path byte-identical.
    tree_rows = tree_rows,
  }
end

return M
