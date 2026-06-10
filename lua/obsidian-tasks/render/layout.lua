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

--- Two-space-per-level indent for a tree row at ABSOLUTE source *depth*.
--- Mirrors the project's nested-list 2-space convention so the dashboard's
--- visual nesting matches the on-disk hierarchy.  depth is the TRUE source depth
--- (the top-level root is depth 0), so a top-level row gets no extra indent and
--- each level deeper adds two spaces.
--- @param depth integer|nil
--- @return string
local function tree_indent(depth)
  if not depth or depth <= 0 then
    return ""
  end
  return string.rep("  ", depth)
end

--- Build the ordered list of render-line records from a QueryResult.
---
--- @param query_result table  QueryResult as returned by query/run.lua
--- @param opts?        table  optional opts:
---                              opts.lingers       — list of linger entries
---                                                   { task, src_path, src_line,
---                                                     source_text_hash }
---                              opts.group_by      — ast.group_by (used to resolve
---                                                   each linger to its group(s))
---                              opts.dim_completed — dim live tasks whose status
---                                                   is Done/Cancelled, in place
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

  --- Resolve the `[[...]]` backlink suffix for a task whose source file is
  --- *path*.  Returns the suffix string ("" when none should be appended) and
  --- the inner wikilink text rendered (nil when no suffix is appended).
  ---
  --- The note's first frontmatter alias (via `opts.resolve_alias`, when given)
  --- is shown with `[[basename|alias]]` — the standard Obsidian aliased-link
  --- form.  The link *target* stays the real filename so it resolves both in
  --- Obsidian and to markdown LSPs (marksman et al.) that verify wikilinks;
  --- the alias is display text only.  Falls back to `[[basename]]` when the
  --- note has no alias (or its alias equals the filename).
  ---
  --- Threading the inner text back to the caller lets render/edit.lua strip
  --- exactly what was rendered during edit-flush.
  --- @param path string|nil
  --- @return string suffix
  --- @return string|nil target  inner [[...]] text ("basename" or "basename|alias")
  local function backlink_suffix(path)
    if not path or hide.backlinks then
      return "", nil
    end
    local basename = vim.fn.fnamemodify(path, ":t:r")
    local alias = opts.resolve_alias and opts.resolve_alias(path) or nil
    local target = basename
    if alias and alias ~= "" and alias ~= basename then
      target = basename .. "|" .. alias
    end
    return " [[" .. target .. "]]", target
  end

  -- Forward declarations: emit_linger (defined with the shared emit engine,
  -- below) renders a tree linger's descendant rows via these tree builders, which
  -- are defined further down.  Declaring them here makes the upvalue bind so the
  -- closure sees the real implementations at call time.
  local build_tree_task_line
  local build_tree_bullet_line
  local build_tree_blank_line

  --- Build a render record for a lingered task in *group_name* at
  --- *group_index* (0-based position within the rendered group body).
  --- @param ent        table
  --- @param group_name string
  --- @param group_index integer
  --- @return table
  local function build_linger_line(ent, group_name, group_index)
    local visible_task = apply_hide_flags(ent.task, hide)
    -- FLAT results render FLUSH-LEFT (upstream parity): a matched CHILD task is
    -- NOT shown at its source indent (that looked like a tree).  Serialize a
    -- no-indent copy so the display AND invalid_ranges are flush; the real
    -- on-disk indent is preserved in flat_source_indent for edit write-back.
    local flat_source_indent = visible_task.indent or ""
    local ser_task = visible_task
    if flat_source_indent ~= "" then
      ser_task = vim.tbl_extend("force", {}, visible_task)
      ser_task.indent = ""
    end
    local ser = serialize_mod.serialize_with_meta(ser_task, { format = "preserve" })
    local task_text = ser.text
    local invalid_ranges = ser.invalid_ranges
    local source_text_hash = ent.task.raw_line and src_hash(ent.task.raw_line) or src_hash(task_text)
    local path = ent.src_path or ent.task._src_path
    local suffix, wikilink_target = backlink_suffix(path)
    task_text = task_text .. suffix
    local hash = src_hash(task_text)
    return {
      kind = "task",
      text = task_text,
      src_path = path,
      src_line = ent.src_line or ent.task._src_line,
      src_hash = hash,
      source_text_hash = source_text_hash,
      -- Inner [[...]] text rendered above ("basename" or "basename|alias");
      -- nil when no suffix was appended.  Threaded to render/edit.lua for
      -- edit-flush strip/re-apply (see render/managed.lua meta).
      wikilink_target = wikilink_target,
      -- source_text is the VERBATIM source-file line content (preserved by
      -- parse.lua as task.raw_line).  draw.lua uses this as managed.task_text
      -- so the drift check compares like-for-like: the canonicalized render
      -- often reorders fields per FIELD_ORDER, which would falsely trigger
      -- drift against a source whose field order differs.
      source_text = ent.task.raw_line,
      indent = ent.task.indent or "",
      -- Original on-disk leading whitespace, stripped from the FLUSH display.
      -- render/edit.lua re-applies it on write-back so a matched child keeps its
      -- source nesting; "" for a top-level task (no re-apply needed).
      flat_source_indent = flat_source_indent,
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
    -- FLAT results render FLUSH-LEFT (upstream parity) — see build_linger_line.
    local flat_source_indent = visible_task.indent or ""
    local ser_task = visible_task
    if flat_source_indent ~= "" then
      ser_task = vim.tbl_extend("force", {}, visible_task)
      ser_task.indent = ""
    end
    local ser = serialize_mod.serialize_with_meta(ser_task, { format = "preserve" })
    local task_text = ser.text
    local invalid_ranges = ser.invalid_ranges
    local source_text_hash = task.raw_line and src_hash(task.raw_line) or src_hash(task_text)
    local path = task._src_path
    local suffix, wikilink_target = backlink_suffix(path)
    task_text = task_text .. suffix
    local hash = src_hash(task_text)
    return {
      kind = "task",
      text = task_text,
      -- Status symbol carried through so the render loop can classify a row as
      -- done/cancelled when computing per-subtree fold counts (folds.lua foldtext).
      status_symbol = task.status_symbol,
      src_path = path,
      src_line = task._src_line,
      src_hash = hash,
      source_text_hash = source_text_hash,
      -- Inner [[...]] text rendered above; nil when no suffix was appended.
      -- See build_linger_line / render/managed.lua.
      wikilink_target = wikilink_target,
      -- VERBATIM source-file line (preserved by parse.lua as task.raw_line).
      -- See build_linger_line for why this matters (drift check correctness).
      source_text = task.raw_line,
      indent = task.indent or "",
      -- Original on-disk indent stripped from the FLUSH display; re-applied on
      -- write-back (render/edit.lua).  "" for a top-level task.
      flat_source_indent = flat_source_indent,
      group_name = group_name,
      group_index = group_index,
      invalid_ranges = (invalid_ranges and #invalid_ranges > 0) and invalid_ranges or nil,
      -- Mark completed-live rows as dim so draw applies the linger highlight.
      dim = dim_completed and status_mod.is_completed(task.status_symbol) or nil,
    }
  end

  -- ── Shared emit engine (single source of truth for FLAT and TREE) ──────────
  -- Both render modes converge here so linger interleaving, ghost groups, the
  -- (path,line) dedup, and group-index positioning can never silently diverge
  -- between paths again.  The difference between modes is ONLY what a "unit"
  -- emits: a flat unit is one live task → one row; a tree unit is one matched
  -- ROOT → its whole subtree (root + descendant rows).  A linger emits a single
  -- dimmed row (flat) or, when the entry carries a reconstructed linger_subtree,
  -- the whole dimmed subtree block (tree).  In BOTH modes a unit / linger counts
  -- as exactly ONE index position, so prior_index_within_group splicing is
  -- identical.
  --
  -- ANY new group-emission behavior (new header rule, new linger framing, a new
  -- per-group annotation) MUST be added HERE, not in a mode-specific branch, or
  -- the parametrized flat-vs-tree harness (tests/unit/test_flat_tree_parity.lua)
  -- will fail.

  --- Emit ONE lingered entry.  A tree linger carries linger_subtree rows
  --- (reconstructed by render/init.lua via tree.subtree_rows): render the WHOLE
  --- block dimmed — the root via build_linger_line (so it keeps linger=true +
  --- drift meta) and the descendants via the tree builders forced dim.  A flat
  --- linger has no subtree → one dimmed row.
  ---
  --- ent.linger_ancestors (tree.ancestor_rows) renders the dim breadcrumb chain
  --- ABOVE the block so the lingered root keeps its prior visual context.
  --- crumbs_emitted / live_unit_keys are the per-group-body dedup sets from
  --- emit_group_body: a breadcrumb already emitted in this group (by a
  --- still-live sibling's unit or an earlier linger) — or whose line is itself
  --- a live unit root — must not render twice (one managed row per disk line).
  --- @param ent            table
  --- @param group_name     string
  --- @param group_index    integer
  --- @param crumbs_emitted table<string,boolean>|nil
  --- @param live_unit_keys table<string,boolean>|nil
  local function emit_linger(ent, group_name, group_index, crumbs_emitted, live_unit_keys)
    local sub = ent.linger_subtree
    if not sub or #sub == 0 then
      lines[#lines + 1] = build_linger_line(ent, group_name, group_index)
      return
    end
    for _, brow in ipairs(ent.linger_ancestors or {}) do
      local k = (brow.src_path or "") .. ":" .. tostring(brow.src_line or 0)
      local dup = (crumbs_emitted and crumbs_emitted[k]) or (live_unit_keys and live_unit_keys[k])
      if not dup then
        if crumbs_emitted then
          crumbs_emitted[k] = true
        end
        brow.group_name = group_name
        brow.group_index = group_index
        brow.dim = true
        local rec
        if brow.kind == "bullet" then
          rec = build_tree_bullet_line(brow)
        else
          rec = build_tree_task_line(brow)
        end
        -- Part of the lingered block: clears with it, state-tracked like the
        -- descendants below.
        rec.linger = true
        rec.dim = true
        lines[#lines + 1] = rec
      end
    end
    -- Tree linger: the root row reuses build_linger_line (linger=true, the
    -- captured task, drift meta), then gets the depth-relative indent + tree
    -- metadata of its row so it folds + indents like a live subtree root.  Each
    -- descendant renders through the tree builders, forced dim.
    for i, row in ipairs(sub) do
      row.group_name = group_name
      row.group_index = group_index
      if i == 1 then
        local rec = build_linger_line(ent, group_name, group_index)
        local lead = tree_indent(row.depth)
        rec.text = lead .. rec.text:gsub("^%s*", "")
        rec.source_indent = (row.task and row.task.indent) or ent.task.indent or ""
        rec.tree_kind = "task"
        rec.depth = row.depth
        rec.fold_group = row.fold_group
        rec.matched = false
        lines[#lines + 1] = rec
      else
        local rec
        if row.kind == "task" then
          row.dim = true
          rec = build_tree_task_line(row)
        elseif row.kind == "bullet" then
          row.dim = true
          rec = build_tree_bullet_line(row)
        else
          rec = build_tree_blank_line(row)
        end
        -- Mark every descendant row as a linger so render/init's line_map and the
        -- linger-clearing logic treat the whole block as one lingered unit.
        rec.linger = true
        rec.dim = true
        lines[#lines + 1] = rec
      end
    end
  end

  --- Emit a group's body into *lines*: a sequence of LIVE UNITS with lingers
  --- spliced at their prior_index_within_group, dedup'd against active lingers
  --- (per-block-query: linger wins, live suppressed).  Shared by FLAT and TREE.
  ---
  --- @param group_name     string    current group name (may be "")
  --- @param live_units     table[]   { { key="path:line", emit=fn(gname, gidx) }, … }
  ---                                 in render order; each counts as one index slot
  --- @param linger_entries table[]|nil  linger entries pre-bucketed for this group
  local function emit_group_body(group_name, live_units, linger_entries)
    linger_entries = linger_entries or {}
    consumed_linger_groups[group_name] = true

    -- Build dedup key set from active lingers in this group.  A FLAT linger keys
    -- only its single root (src_path, src_line).  A TREE linger emits a WHOLE
    -- subtree block (root + descendants via ent.linger_subtree / emit_linger), so
    -- EVERY row of that block must be keyed — otherwise a descendant whose matched
    -- ancestor left the filter becomes its own LIVE unit (its own path:line key)
    -- and renders TWICE: once dimmed inside the lingered block, once live.  Two
    -- managed rows for one disk line corrupt locate/drift, so suppress the live
    -- copy by keying every subtree row, not just the root.
    local linger_keys = {}
    for _, ent in ipairs(linger_entries) do
      local path = ent.src_path or (ent.task and ent.task._src_path) or ""
      local line_nr = ent.src_line or (ent.task and ent.task._src_line) or 0
      linger_keys[path .. ":" .. tostring(line_nr)] = true
      if ent.linger_subtree then
        for _, row in ipairs(ent.linger_subtree) do
          local rp = row.src_path or ""
          local rl = row.src_line or 0
          linger_keys[rp .. ":" .. tostring(rl)] = true
        end
      end
    end

    -- Filter live units: drop those whose key matches an active linger entry in
    -- this group (Q8 dedup: linger wins within same query).
    local filtered_live = {}
    for _, unit in ipairs(live_units) do
      if not linger_keys[unit.key] then
        filtered_live[#filtered_live + 1] = unit
      end
    end

    -- Per-body breadcrumb dedup.  A dim connector-ancestor line can be owed by
    -- BOTH a live unit (a still-matching sibling) and a lingered block
    -- (ent.linger_ancestors) in the same group — whoever emits first claims the
    -- key, the other skips it.  live_unit_keys additionally suppresses a linger
    -- ancestor whose line is itself a live unit ROOT (it renders lit, not as a
    -- dim crumb).
    local crumbs_emitted = {}
    local live_unit_keys = {}
    for _, unit in ipairs(filtered_live) do
      live_unit_keys[unit.key] = true
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
    -- each live unit, drain indexed lingers whose prior_index ≤ output_idx
    -- (linger holds its prior slot; live unit gets bumped one position).
    local output_idx = 0
    local linger_i = 1
    for _, unit in ipairs(filtered_live) do
      while linger_i <= #indexed and indexed[linger_i].prior_index_within_group <= output_idx do
        emit_linger(indexed[linger_i], group_name, output_idx, crumbs_emitted, live_unit_keys)
        linger_i = linger_i + 1
        output_idx = output_idx + 1
      end
      unit.emit(group_name, output_idx, crumbs_emitted)
      output_idx = output_idx + 1
    end

    -- Remaining indexed lingers whose prior_index exceeded the live count.
    while linger_i <= #indexed do
      emit_linger(indexed[linger_i], group_name, output_idx, crumbs_emitted, live_unit_keys)
      linger_i = linger_i + 1
      output_idx = output_idx + 1
    end

    -- Unindexed (legacy fallback) lingers appended at end.
    for _, ent in ipairs(unindexed) do
      emit_linger(ent, group_name, output_idx, crumbs_emitted, live_unit_keys)
      output_idx = output_idx + 1
    end
  end

  --- Build a render record for a tree TASK row.  Reuses build_live_line's
  --- serialize+backlink path, then prepends the depth-derived 2-space indent so
  --- the dashboard nesting mirrors the source.  Carries the tree-specific
  --- metadata (tree_kind / depth / fold_group / matched) so draw can register
  --- it as a managed EDITABLE row and group it into a per-subtree fold.
  --- @param row table  tree row from query/tree.lua
  --- @return table  render record
  function build_tree_task_line(row)
    -- Descendant tasks come from the node model (nodes_for); run.lua only sets
    -- _src_path/_src_line on the MATCHED root, so stamp every tree task's source
    -- coordinates from the row before serializing.  Without this, a nested task's
    -- src_line is nil and edit-through can't locate its source line.
    row.task._src_path = row.src_path
    row.task._src_line = row.src_line
    local rec = build_live_line(row.task, row.group_name or "", row.group_index or 0)
    -- The dashboard renders nested tree tasks with a depth-relative 2-space
    -- indent (tree_indent), which differs from the task's ON-DISK leading
    -- whitespace whenever the vault doesn't use exactly 2-space nesting.  On an
    -- edit-flush the dashboard line is written back to source, so we must record
    -- the ORIGINAL source indent here and re-apply it on write-back (see
    -- render/edit.lua) — otherwise a 4-space / tab-indented child would be
    -- rewritten with the dashboard's 2-space indent, corrupting the nesting.
    rec.source_indent = row.task.indent or ""
    -- depth is the TRUE source depth (no re-rooting).  ALWAYS strip the
    -- serialized text's leading whitespace and re-apply the depth-relative
    -- 2-space indent — including depth 0, which strips to flush-left.  Only the
    -- DISPLAY (rec.text) changes; rec.source_indent (true on-disk indent) and
    -- rec.source_text (verbatim disk line, set by build_live_line) stay intact so
    -- write-back/locate compare against the real source, not the rendered column.
    local lead = tree_indent(row.depth)
    local body = rec.text:gsub("^%s*", "")
    rec.text = lead .. body
    rec.tree_kind = "task"
    rec.depth = row.depth
    rec.fold_group = row.fold_group
    rec.matched = row.matched or false
    -- TRUE structural parent line (nil at top level) for the edit.lua group-attr
    -- gate's parent-chain walk.
    rec.parent_line = row.parent_line
    -- Connector-ancestor (breadcrumb) rows render dimmed (same highlight as
    -- lingered rows) but stay managed + editable; build_live_line already set
    -- rec.dim for live-completed, so OR the tree dim flag in.
    rec.dim = rec.dim or row.dim or nil
    return rec
  end

  --- Build a render record for a tree BULLET (non-task description) row.
  --- Phase 5a makes bullet rows EDITABLE in-place: they render their literal
  --- text at the depth-relative indent using the ORIGINAL source marker, and are
  --- registered as managed EDITABLE rows.  An in-place body edit writes back RAW
  --- (no task serialize / no `- [ ]` repair): the source line is reconstructed as
  --- bullet_indent .. marker .. " " .. body (see render/edit.lua's bullet branch).
  ---
  --- The dashboard form keeps the marker (so `*`/`+` show as themselves) at the
  --- depth-relative indent; the source form keeps the original raw indent.  Both
  --- derive from the same body so they never diverge.
  --- @param row table
  --- @return table
  function build_tree_bullet_line(row)
    local lead = tree_indent(row.depth)
    -- The node model stores the bullet's TRIMMED body (no list marker) plus the
    -- ORIGINAL marker (row.bullet_marker) and raw source indent (row.bullet_indent).
    -- Render the original marker (not a synthesized "-") so "*"/"+" bullets show
    -- as themselves; depth supplies the dashboard leading whitespace.
    local marker = row.bullet_marker or "-"
    local source_indent = row.bullet_indent or ""
    local body = (row.text or ""):gsub("^%s*", "")
    local text = lead .. marker .. " " .. body
    -- The VERBATIM on-disk line (node.source_line, threaded as bullet_source_text)
    -- is used as managed.task_text/expected_text for drift+locate so the flush
    -- compares against the EXACT disk line — mirroring how a task row uses
    -- task.raw_line.  A trimmed reconstruction (source_indent..marker.." "..body)
    -- would NOT match a disk line that has trailing spaces or multiple
    -- post-marker spaces, so M.locate would silently drop the edit/delete.  Fall
    -- back to the reconstruction only for synthesized rows lacking a source line
    -- (e.g. tests / generated rows), matching the task-row fallback.
    local source_text = row.bullet_source_text or (source_indent .. marker .. " " .. body)
    return {
      kind = "task", -- draw inserts it as a real buffer line + managed row
      tree_kind = "bullet",
      text = text,
      src_path = row.src_path,
      src_line = row.src_line,
      src_hash = src_hash(text),
      -- ORIGINAL source leading whitespace + marker for write-back (see
      -- render/edit.lua bullet branch).  source_indent presence is what flags a
      -- managed row as a tree row in flush; bullet_marker distinguishes the
      -- bullet (raw) write path from the task (serialize) write path.
      source_indent = source_indent,
      bullet_marker = marker,
      source_text = source_text,
      depth = row.depth,
      fold_group = row.fold_group,
      matched = false,
      parent_line = row.parent_line,
      -- A connector-ancestor bullet (a checkbox nested under a `-` bullet) renders
      -- dimmed via the linger highlight, like a dim task ancestor.
      dim = row.dim or nil,
      indent = "",
    }
  end

  --- Build a render record for a tree BLANK row (an interspersed empty line in
  --- the subtree).  Renders as an empty buffer line; READ-ONLY like bullets.
  --- @param row table
  --- @return table
  function build_tree_blank_line(row)
    return {
      kind = "task",
      tree_kind = "blank",
      read_only = true,
      text = "",
      src_path = row.src_path,
      src_line = row.src_line,
      src_hash = src_hash(""),
      depth = nil,
      fold_group = row.fold_group,
      matched = false,
      indent = "",
    }
  end

  -- ── Build per-group LIVE UNITS (shared by FLAT and TREE) ───────────────────
  -- A "unit" is one index slot in a group body: it emits its row(s) at the given
  -- (group_name, group_index) and carries a (path,line) key for linger dedup.
  -- FLAT: one live task → one unit (one row).  TREE: one matched ROOT → one unit
  -- (root + its drag rows).  Both converge on emit_group_body so linger
  -- interleaving / dedup / positioning are identical.  Connector-ancestor (dim)
  -- rows in the tree path are NOT units — they are emitted in place ahead of the
  -- lit root they precede (fold_group 0, always-visible breadcrumb), and never
  -- consume an index slot, so prior_index splicing matches the flat path.
  --
  -- ordered_live_groups: { { name=string, units={unit,…} }, … } in live order.
  local ordered_live_groups = {}

  if query_result.tree_rows then
    -- Group tree rows by group name (caller/source order), then partition each
    -- group's rows into UNITS keyed by group_index (the root's position).  A
    -- DIM connector-ancestor row (dim=true) is NOT part of any lit unit; emit it
    -- ahead of the first unit it precedes so the breadcrumb renders before its
    -- matched descendant.
    local group_order = {}
    local seen = {}
    local rows_by_group = {}
    for _, row in ipairs(query_result.tree_rows) do
      local gn = row.group_name or ""
      if not seen[gn] then
        seen[gn] = true
        group_order[#group_order + 1] = gn
        rows_by_group[gn] = {}
      end
      table.insert(rows_by_group[gn], row)
    end

    for _, gn in ipairs(group_order) do
      local units = {}
      -- pending_dim: dim ANCESTOR breadcrumb rows (fold_group 0) seen since the
      -- last lit root; flushed (emitted in place) at the head of the next lit
      -- unit's output.  A breadcrumb can precede a LATER root (after the current
      -- unit's descendants), which is why it must be buffered rather than ride
      -- along.  A dim DESCENDANT (fold_group > 0) is NOT a breadcrumb — it stays
      -- in place inside its lit root's subtree (see the cur_unit branch below).
      local pending_dim = {}
      local cur_unit = nil
      for _, row in ipairs(rows_by_group[gn]) do
        -- Only a dim ANCESTOR is a breadcrumb.  assemble tags ancestor rows with
        -- fold_group 0 and descendant rows with fold_group > 0; without this
        -- split a dim descendant (e.g. a non-matching child bullet between two
        -- lit siblings) was buffered as a breadcrumb and dumped at the END of the
        -- group instead of rendering in source order.
        local is_breadcrumb = row.dim and (row.fold_group == 0 or row.fold_group == nil)
        if is_breadcrumb then
          pending_dim[#pending_dim + 1] = row
        elseif row.matched then
          -- A new lit ROOT starts a new unit; capture the dim breadcrumbs that
          -- precede it so the unit emits them first.
          local breadcrumbs = pending_dim
          pending_dim = {}
          local rows_for_unit = { row }
          cur_unit = {
            key = (row.src_path or "") .. ":" .. tostring(row.src_line or 0),
            breadcrumbs = breadcrumbs,
            rows = rows_for_unit,
          }
          units[#units + 1] = cur_unit
        elseif cur_unit then
          -- A LIT descendant OR a DIM descendant (fold_group > 0) rides along in
          -- the current unit's drag, in source order — only ancestor breadcrumbs
          -- are deferred.
          cur_unit.rows[#cur_unit.rows + 1] = row
        else
          -- Defensive: a non-matched, non-dim row with no current unit (should
          -- not occur given assemble's ordering) — treat as its own unit so it
          -- is never dropped.
          cur_unit = {
            key = (row.src_path or "") .. ":" .. tostring(row.src_line or 0),
            breadcrumbs = pending_dim,
            rows = { row },
          }
          pending_dim = {}
          units[#units + 1] = cur_unit
        end
      end
      -- Trailing dim breadcrumbs with no following lit root (degenerate): emit
      -- them as a standalone always-visible unit so they are not lost.
      if #pending_dim > 0 then
        units[#units + 1] = { key = "\0dim", breadcrumbs = pending_dim, rows = {} }
      end

      -- Wrap each unit's rows into an emit closure.  The closure stamps the
      -- group_index emit_group_body assigns (which reflects any linger that
      -- bumped this unit) onto the lit root + descendant rows, exactly like the
      -- flat path passes output_idx into build_live_line — so a later toggle of a
      -- bumped tree root recovers the SAME prior_index_within_group flat would.
      -- Breadcrumb (dim ancestor) rows are not index slots and keep their own
      -- group metadata.
      local function emit_tree_row(trow)
        if trow.kind == "task" then
          lines[#lines + 1] = build_tree_task_line(trow)
        elseif trow.kind == "bullet" then
          lines[#lines + 1] = build_tree_bullet_line(trow)
        else
          lines[#lines + 1] = build_tree_blank_line(trow)
        end
      end
      for _, u in ipairs(units) do
        local breadcrumbs = u.breadcrumbs
        local rows_for_unit = u.rows
        u.emit = function(group_name, group_index, crumbs_emitted)
          for _, brow in ipairs(breadcrumbs) do
            -- Claim each breadcrumb in the per-body dedup set: a lingered block
            -- (emit_linger's linger_ancestors) may owe the same ancestor line in
            -- this group — first emitter wins, the other skips.
            local k = (brow.src_path or "") .. ":" .. tostring(brow.src_line or 0)
            if not (crumbs_emitted and crumbs_emitted[k]) then
              if crumbs_emitted then
                crumbs_emitted[k] = true
              end
              emit_tree_row(brow)
            end
          end
          for _, trow in ipairs(rows_for_unit) do
            trow.group_name = group_name
            trow.group_index = group_index
            emit_tree_row(trow)
          end
        end
      end

      ordered_live_groups[#ordered_live_groups + 1] = { name = gn, units = units }
    end
  else
    -- FLAT: one live task → one unit (one row via build_live_line).
    for _, group in ipairs(live_groups) do
      local gname = group.name or ""
      local units = {}
      for _, task in ipairs(group.tasks or {}) do
        local t = task
        units[#units + 1] = {
          key = (t._src_path or "") .. ":" .. tostring(t._src_line or 0),
          emit = function(group_name, group_index)
            lines[#lines + 1] = build_live_line(t, group_name, group_index)
          end,
        }
      end
      ordered_live_groups[#ordered_live_groups + 1] = { name = gname, units = units }
    end
  end

  -- ── Unified group emission (headers + bodies + ghost groups) ───────────────
  -- ONE loop drives BOTH modes: the header rule (named always; unnamed only in a
  -- multi-group context) and the body emission (emit_group_body: live units +
  -- linger splice + dedup) are identical, so a tree-mode regression in any of
  -- these surfaces in the parametrized flat-vs-tree harness.
  --
  -- The tree path's multi_group flag is recomputed from its own group names
  -- (live_groups is empty-of-headers in tree mode — run.lua fills tree_rows), but
  -- the RULE is the same: header iff named, or unnamed-with-more-than-one-group.
  --
  -- Tree-mode ghost detection must derive from ordered_live_groups (the names that
  -- actually rendered LIVE BODIES), NOT from query_result.groups: a group can be
  -- PRESENT in query_result.groups yet produce zero tree_rows (a named group with
  -- no matching tasks).  The flat-path ghost_names puts that name in live_set, so
  -- a linger bucketed under it would be neither spliced (no ordered_live_group of
  -- that name) nor ghosted (excluded by live_set) — it would silently vanish.
  -- Recomputing from the rendered live names lets such a linger surface as a
  -- ghost group.  Flat mode keeps the original ghost_names byte-for-byte.
  if query_result.tree_rows then
    local live_set = {}
    for _, g in ipairs(ordered_live_groups) do
      live_set[g.name or ""] = true
    end
    ghost_names = {}
    for name in pairs(lingers_by_group) do
      if not live_set[name] then
        ghost_names[#ghost_names + 1] = name
      end
    end
    table.sort(ghost_names, function(a, b)
      return vim.stricmp(a, b) < 0
    end)
  end

  local emit_multi_group
  if query_result.tree_rows then
    local distinct = #ordered_live_groups
    local first_name = ordered_live_groups[1] and ordered_live_groups[1].name or nil
    -- Ghost groups also count toward multi_group in tree mode.
    emit_multi_group = (distinct + #ghost_names) > 1 or (first_name ~= nil and first_name ~= "")
  else
    emit_multi_group = multi_group
  end

  local function emit_group_header(name)
    if name ~= "" then
      lines[#lines + 1] = {
        kind = "group_header",
        text = "## " .. name,
        src_path = nil,
        src_line = nil,
        src_hash = nil,
        indent = "",
      }
    elseif emit_multi_group then
      lines[#lines + 1] = {
        kind = "group_header",
        text = "## (no group)",
        src_path = nil,
        src_line = nil,
        src_hash = nil,
        indent = "",
      }
    end
  end

  for _, g in ipairs(ordered_live_groups) do
    emit_group_header(g.name)
    emit_group_body(g.name, g.units, lingers_by_group[g.name])
  end

  -- Ghost groups: a header + linger rows for each linger group-name with no live
  -- group in the current result set.  Identical for flat and tree (a tree linger
  -- carries linger_subtree, so emit_linger renders the whole dimmed block).
  for _, name in ipairs(ghost_names) do
    if not consumed_linger_groups[name] then
      emit_group_header(name)
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
