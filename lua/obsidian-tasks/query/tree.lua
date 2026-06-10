-- lua/obsidian-tasks/query/tree.lua
-- Induced-forest subtree assembly + dedup for `show tree`.
--
-- Turns the matched left-most tasks (post filter/sort/group/limit, as the
-- QueryResult.groups produced by query/run.lua) into an ordered list of
-- layout-ready ROWS.  This is a PURE function over the matched tasks plus a
-- per-file node accessor — it does NOT touch the buffer, render, or draw.
--
-- ── Row schema (shape-compatible / extensible with render/layout.lua) ───────
--   {
--     kind        = "task" | "bullet" | "blank",  -- node kind axis
--     depth       = integer | nil,  -- ABSOLUTE source depth (the true top-level
--                                      root is depth 0); nil for blank rows
--     src_path    = string,         -- absolute source path
--     src_line    = integer | nil,  -- 1-based source line (blanks carry it too)
--     task        = <Task> | nil,   -- present on kind=="task" rows
--     text        = string | nil,   -- present on kind=="bullet" rows (TRIMMED body)
--     bullet_marker = string | nil, -- present on kind=="bullet": literal "-"/"*"/"+"
--     bullet_indent = string | nil, -- present on kind=="bullet": raw source indent
--     bullet_source_text = string | nil, -- present on kind=="bullet": VERBATIM
--                                      on-disk line (drift/locate compare target)
--     matched     = boolean,        -- true ONLY on the matched left-most root
--     dim         = boolean | nil,  -- true ONLY on connector-ancestor rows (the
--                                      dim breadcrumb above a lit root); false/nil
--                                      on lit rows
--     fold_group  = integer,        -- id grouping every row of one LIT subtree;
--                                      0 (sentinel) on DIM ancestor rows = "always
--                                      visible, not foldable" so folding a subtree
--                                      never hides the breadcrumb above it
--     group_name  = string,         -- the run.lua group this subtree rides in
--     group_index = integer,        -- 0-based position of the ROOT within its
--                                      group's rendered roots
--   }
--
-- ── Membership (tree ON) — INDUCED FOREST ───────────────────────────────────
--   NO re-rooting.  Every row renders at its TRUE source depth (node.depth).
--   Per group, we render the induced indentation forest of all matched tasks:
--   * Each matched task that is NOT suppressed (no matched ancestor in the same
--     group) is a LIT root.  It emits LIT plus its ENTIRE descendant subtree —
--     child tasks, non-task bullets, and interspersed blank lines — all LIT, at
--     their absolute depths, regardless of whether any descendant matched.
--   * SUPPRESSION (unchanged): a matched task WITH a matched ancestor in the
--     SAME group is suppressed as a standalone root (it appears nested, lit,
--     inside that ancestor's drag instead).  Dedup keys on (path, line) per
--     group, so the same line in two files is independent and a matched root
--     in multiple groups still emits once per group.
--   * CONNECTOR ANCESTORS: for each LIT root, walk its parent_line chain up to
--     the true top-level root.  Every ancestor on that path that is not itself a
--     lit row is emitted as a DIM row (dim=true, matched=false) at its absolute
--     source depth.  An ancestor may be a task OR a non-task bullet — dim either.
--   * MERGE: ancestor rows are dedup'd per group by (src_path, line) so a parent
--     shared by two matched children appears ONCE, both children nested under it.
--   * STRUCTURE-FIRST ordering: walk the matched tasks in their existing group
--     order (run.lua already sorted them).  For each non-suppressed root, first
--     emit any of its ancestors not yet emitted this group (top-down, dim), then
--     the lit root + its drag subtree.  So an ancestor is emitted just before its
--     first (in sort order) matched descendant; later matches sharing it nest
--     under it in place.
--
-- ── Tree OFF ────────────────────────────────────────────────────────────────
--   Emits one flat row per matched task in caller order (no descendants, no
--   dedup), so callers/tests can compare a tree-off assembly against the flat
--   path.  query/run.lua keeps its own flat output byte-identical and only
--   reaches for this module when ast.tree is set.

local M = {}

--- Build the per-file lookup structures used during subtree slicing:
---   pos[line]  = index of the node at that line within `ns`
--- @param ns table[]  node list for one file
--- @return table<integer,integer>  line_num → list index
local function index_by_line(ns)
  local pos = {}
  for i, n in ipairs(ns) do
    pos[n.line_num] = i
  end
  return pos
end

--- True when the task at (path,line) has an ANCESTOR (via parent_line) that is
--- also a matched task — i.e. it should be suppressed as a standalone root.
--- @param ns          table[]                  node list for the file
--- @param pos         table<integer,integer>   line_num → index
--- @param matched_keys table<string,boolean>   set of "path:line" matched keys
--- @param path        string
--- @param line        integer                  the matched task's line
--- @return boolean
local function has_matched_ancestor(ns, pos, matched_keys, path, line)
  local node = ns[pos[line]]
  if not node then
    return false
  end
  local parent_line = node.parent_line
  while parent_line ~= nil do
    if matched_keys[path .. ":" .. tostring(parent_line)] then
      return true
    end
    local pnode = ns[pos[parent_line]]
    if not pnode then
      break
    end
    parent_line = pnode.parent_line
  end
  return false
end

--- Collect the descendant subtree of the matched root at index `root_idx`.
--- Walks forward over the line-ordered node list, gathering every node whose
--- depth is GREATER than the root's depth (its descendants), stopping at the
--- first non-blank node at depth <= root depth (a sibling/ancestor).  Interior
--- blanks (those between two collected descendants) ride along; trailing blanks
--- before the dedent do NOT.
--- @param ns       table[]
--- @param root_idx integer  index of the root node in `ns`
--- @return table[]  descendant nodes in source order (interior blanks included)
local function collect_descendants(ns, root_idx)
  local root = ns[root_idx]
  local root_depth = root.depth
  local out = {}
  local pending_blanks = {}
  for i = root_idx + 1, #ns do
    local n = ns[i]
    if n.kind == "blank" then
      -- Buffer blanks; only flush when a further descendant follows.
      pending_blanks[#pending_blanks + 1] = n
    elseif n.depth ~= nil and n.depth > root_depth then
      -- A descendant: flush the buffered interior blanks, then add it.
      for _, b in ipairs(pending_blanks) do
        out[#out + 1] = b
      end
      pending_blanks = {}
      out[#out + 1] = n
    else
      -- A sibling/ancestor (non-blank, depth <= root): subtree ends here.
      -- Buffered (trailing) blanks belong to the gap, not the subtree.
      break
    end
  end
  return out
end

--- Build a row record for a node at its ABSOLUTE source depth (node.depth).
--- @param n          table    node
--- @param path       string
--- @param matched    boolean
--- @param dim        boolean  true for connector-ancestor (breadcrumb) rows
--- @param fold_group integer  lit subtree id; 0 sentinel on dim ancestors
--- @param group_name string
--- @param group_index integer
--- @return table  row
local function make_row(n, path, matched, dim, fold_group, group_name, group_index)
  return {
    kind = n.kind,
    -- ABSOLUTE source depth — no re-rooting.  Blank rows have no depth.
    depth = n.depth,
    src_path = path,
    src_line = n.line_num,
    task = (n.kind == "task") and n.task or nil,
    text = (n.kind == "bullet") and n.text or nil,
    -- Bullet round-trip metadata: the literal source marker and raw
    -- leading-whitespace indent, threaded through so layout/edit can reconstruct
    -- the source line exactly on write-back.  nil for task/blank rows.
    bullet_marker = (n.kind == "bullet") and n.marker or nil,
    bullet_indent = (n.kind == "bullet") and n.indent or nil,
    -- The VERBATIM on-disk bullet line (node.source_line); layout uses it as the
    -- managed row's source_text/task_text so drift+locate match the EXACT disk
    -- line (mirrors how a task row uses task.raw_line).  nil for task/blank rows.
    bullet_source_text = (n.kind == "bullet") and n.source_line or nil,
    matched = matched,
    dim = dim or nil,
    fold_group = fold_group,
    group_name = group_name,
    group_index = group_index,
    -- The node's TRUE structural parent line (nil at top level).  Threaded all
    -- the way to the managed-row meta so render/edit.lua's group-attr injection
    -- gate can walk the real parent chain (parent_line), not re-derive it by
    -- nearest-row-at-depth-1 (which mis-decides across sibling subtrees that
    -- share breadcrumb depths).
    parent_line = n.parent_line,
  }
end

--- Collect the connector-ancestor nodes of the node at index `idx`, walking the
--- parent_line chain up to the true top-level root (parent_line == nil).
--- Returned TOP-DOWN (outermost ancestor first), so callers can emit them in
--- breadcrumb order just before the lit root.
--- @param ns  table[]
--- @param pos table<integer,integer>  line_num → index
--- @param idx integer  index of the lit root in `ns`
--- @return table[]  ancestor nodes, outermost first
local function collect_ancestors(ns, pos, idx)
  local chain = {}
  local node = ns[idx]
  local parent_line = node and node.parent_line or nil
  while parent_line ~= nil do
    local pnode = ns[pos[parent_line]]
    if not pnode then
      break
    end
    chain[#chain + 1] = pnode
    parent_line = pnode.parent_line
  end
  -- chain is bottom-up (nearest ancestor first); reverse to top-down.
  local out = {}
  for i = #chain, 1, -1 do
    out[#out + 1] = chain[i]
  end
  return out
end

--- Reconstruct ONE root's lit subtree as ordered rows, from a node list.
---
--- Shared between assemble() (the live tree path) and render/init.lua's linger
--- path: a matched root that LEFT THE FILTER still lives in the file's node
--- model, so its subtree can be rebuilt verbatim from `nodes` (index.nodes_for)
--- using the SAME root row + collect_descendants slice assemble uses — no
--- duplication of the slice logic.  Returns the root row first (matched/dim/
--- fold_group as given) followed by every descendant row (matched=false), all at
--- their absolute source depths.  Returns an empty list when `root_line` has no
--- node in `nodes` (e.g. the line was deleted on disk).
---
--- Connector ancestors are NOT emitted here — the caller decides framing (the
--- linger path rebuilds them via M.ancestor_rows; assemble emits ancestors
--- separately as merged breadcrumbs).
---
--- @param nodes      table[]   per-file node list (index.nodes_for(path))
--- @param path       string    absolute source path
--- @param root_line  integer   1-based source line of the subtree root
--- @param opts       table     { matched=bool, dim=bool, fold_group=int,
---                               group_name=string, group_index=int }
--- @return table[]   ordered rows (root first, then descendants); empty if absent
function M.subtree_rows(nodes, path, root_line, opts)
  opts = opts or {}
  local pos = index_by_line(nodes)
  local root_idx = pos[root_line]
  if root_idx == nil then
    return {}
  end
  local gname = opts.group_name or ""
  local gi = opts.group_index or 0
  local fg = opts.fold_group or 1
  local out = {}
  local root = nodes[root_idx]
  out[#out + 1] = make_row(root, path, opts.matched ~= false, opts.dim or false, fg, gname, gi)
  for _, dn in ipairs(collect_descendants(nodes, root_idx)) do
    out[#out + 1] = make_row(dn, path, false, opts.dim or false, fg, gname, gi)
  end
  return out
end

--- Reconstruct ONE root's connector-ancestor breadcrumb rows (top-down), the
--- linger-path complement to subtree_rows: a lingered root must keep the dim
--- breadcrumb above it (same rows assemble would emit live) so it doesn't
--- render as an orphaned indented block while it lingers.  Rows are dim,
--- matched=false, fold_group 0 (always-visible, not foldable) — identical
--- shape to assemble's live breadcrumbs.  Empty when `root_line` has no node.
---
--- @param nodes     table[]   per-file node list (index.nodes_for(path))
--- @param path      string    absolute source path
--- @param root_line integer   1-based source line of the lingered root
--- @param opts      table     { group_name=string, group_index=int }
--- @return table[]  ancestor rows, outermost first; empty if root absent
function M.ancestor_rows(nodes, path, root_line, opts)
  opts = opts or {}
  local pos = index_by_line(nodes)
  local root_idx = pos[root_line]
  if root_idx == nil then
    return {}
  end
  local out = {}
  for _, an in ipairs(collect_ancestors(nodes, pos, root_idx)) do
    out[#out + 1] = make_row(an, path, false, true, 0, opts.group_name or "", opts.group_index or 0)
  end
  return out
end

--- Assemble layout-ready rows from the matched groups.
---
--- @param groups   table[]  QueryResult.groups: { { name, tasks = {Task,...} }, ... }
---                          each Task carries _src_path / _src_line.
--- @param node_accessor fun(path: string): table[]  per-file node list accessor
---                          (e.g. require("obsidian-tasks.index").nodes_for)
--- @param opts     table    { tree = boolean }  — tree ON (membership + dedup)
---                          vs OFF (flat, one row per matched task)
--- @return table[]  ordered list of row records
function M.assemble(groups, node_accessor, opts)
  opts = opts or {}
  local rows = {}
  local fold_group = 0

  -- Cache per-file node lists + line indexes so a multi-task file is sliced
  -- without re-fetching / re-indexing for every matched task.
  local file_cache = {}
  local function file_of(path)
    local c = file_cache[path]
    if not c then
      local ns = node_accessor(path) or {}
      c = { ns = ns, pos = index_by_line(ns) }
      file_cache[path] = c
    end
    return c
  end

  -- ── Tree OFF: flat passthrough, one row per matched task ─────────────────
  if not opts.tree then
    for _, group in ipairs(groups) do
      local gname = group.name or ""
      local gi = 0
      for _, task in ipairs(group.tasks or {}) do
        fold_group = fold_group + 1
        rows[#rows + 1] = {
          kind = "task",
          depth = 0,
          src_path = task._src_path,
          src_line = task._src_line,
          task = task,
          text = nil,
          matched = true,
          fold_group = fold_group,
          group_name = gname,
          group_index = gi,
        }
        gi = gi + 1
      end
    end
    return rows
  end

  -- ── Tree ON ──────────────────────────────────────────────────────────────
  -- Pass 1: collect a PER-GROUP set of matched (path,line) keys for the
  -- ancestor-dedup test.  Dedup is scoped to each group's own matched tasks: a
  -- task is suppressed only when a matched ancestor rides in the SAME group, so
  -- a matched task whose ancestor lands in a DIFFERENT group is still emitted as
  -- its own root (never silently dropped).  group_index → matched-key set; a
  -- task duplicated within a group contributes its single key once (idempotent).
  local matched_keys_by_group = {}
  for gidx, group in ipairs(groups) do
    local keys = {}
    for _, task in ipairs(group.tasks or {}) do
      keys[task._src_path .. ":" .. tostring(task._src_line)] = true
    end
    matched_keys_by_group[gidx] = keys
  end

  -- Pass 2: emit the induced forest per group, in caller order.
  --
  -- For each non-suppressed matched root we first walk its parent_line chain to
  -- the true top-level root and emit (top-down) any ancestor not yet emitted as
  -- a LIT row this group AND not yet emitted as a DIM ancestor this group — those
  -- become DIM breadcrumb rows.  Then we emit the LIT root + its descendant drag.
  --
  -- "Lit" tracking spans the whole group (lit_keys): a row is lit if it is a
  -- non-suppressed matched root OR a descendant pulled into some root's drag.
  -- An ancestor that is itself lit (e.g. a matched parent already emitted, or a
  -- node dragged in lit by an earlier root) is NOT dimmed — it stays lit and the
  -- later child simply nests beneath it in place.
  for gidx, group in ipairs(groups) do
    local gname = group.name or ""
    local gi = 0
    local matched_keys = matched_keys_by_group[gidx]
    local lit_keys = {} -- "path:line" → true: rows emitted LIT this group
    local dim_keys = {} -- "path:line" → true: rows emitted DIM this group
    local function key(path, line)
      return path .. ":" .. tostring(line)
    end
    for _, task in ipairs(group.tasks or {}) do
      local path = task._src_path
      local line = task._src_line
      local f = file_of(path)
      local root_idx = f.pos[line]

      -- Suppress as a standalone root when a matched ancestor exists in this
      -- group; it will appear nested under that ancestor's subtree instead.
      local suppressed = has_matched_ancestor(f.ns, f.pos, matched_keys, path, line)

      if not suppressed and root_idx ~= nil then
        -- Connector ancestors (top-down): each ancestor not already lit and not
        -- already a dim breadcrumb this group becomes a DIM row, in place.
        for _, an in ipairs(collect_ancestors(f.ns, f.pos, root_idx)) do
          local ak = key(path, an.line_num)
          if not lit_keys[ak] and not dim_keys[ak] then
            dim_keys[ak] = true
            -- fold_group 0 = always-visible breadcrumb, not foldable.
            rows[#rows + 1] = make_row(an, path, false, true, 0, gname, gi)
          end
        end

        fold_group = fold_group + 1
        local root = f.ns[root_idx]
        -- Lit root row.
        lit_keys[key(path, line)] = true
        rows[#rows + 1] = make_row(root, path, true, false, fold_group, gname, gi)
        -- Descendant rows (ride along in source order).  A descendant is LIT only
        -- when it INDEPENDENTLY matches this group (its key is in the group's
        -- matched set); otherwise it is context and renders DIM.  This is the same
        -- invariant the ancestor breadcrumbs above follow: within a group, any row
        -- that does not match the group's rule is dimmed — ancestor OR descendant.
        -- (For an ungrouped tree there is a single group whose matched set is every
        -- filtered task, so a descendant that failed the filter is dimmed too.)
        for _, dn in ipairs(collect_descendants(f.ns, root_idx)) do
          local dn_dim = true
          if dn.line_num ~= nil then
            local dk = key(path, dn.line_num)
            if matched_keys[dk] then
              lit_keys[dk] = true
              dn_dim = false
            else
              dim_keys[dk] = true
            end
          end
          rows[#rows + 1] = make_row(dn, path, false, dn_dim, fold_group, gname, gi)
        end
        gi = gi + 1
      end
    end
  end

  return rows
end

return M
