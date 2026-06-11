-- lua/obsidian-tasks/render/linger.lua
-- Linger LOGIC: pure-ish functions deciding which filter-exited tasks keep a
-- dimmed row/subtree on screen after a rerender.
--
-- STATE LIVES ELSEWHERE.  render/init.lua owns the per-buffer tables
-- (M._pending_lingers[bufnr], M._lingers[bufnr]); tests assign/read those
-- tables directly.  This module only builds entries and computes the next
-- linger list from inputs passed in — it holds no buffer state of its own.
--
-- ── Pending-entry shape (M._pending_lingers[bufnr] list items) ───────────────
--   {
--     src_path         = string,      -- absolute source file path
--     src_line         = integer,     -- 1-indexed source line at toggle time
--     source_text_hash = string|nil,  -- sha256[:16] of the source line
--     task             = table,       -- deepcopy of the parsed Task POST-
--                                     -- mutation; raw_line re-serialized so it
--                                     -- reflects the new status (drift check)
--   }
--
-- ── Linger-entry shape (M._lingers[bufnr] list items) ────────────────────────
-- All pending-entry fields, plus (set at promotion time, pending → linger):
--   {
--     block_idx                 = integer,     -- 1-based index of the pre-exit
--                                              -- ```tasks block (per_block /
--                                              -- _buffer_state index)
--     prior_group_name          = string|nil,  -- group the task occupied in the
--                                              -- prior render ("" = ungrouped)
--     prior_index_within_group  = integer|nil, -- 0-based position within the
--                                              -- prior render's group body;
--                                              -- layout splices the linger back
--                                              -- at this slot (holds position)
--     linger_subtree            = table|nil,   -- tree blocks only: the root's
--                                              -- whole subtree as rows from
--                                              -- tree.subtree_rows over the
--                                              -- CURRENT node model; descendant
--                                              -- task rows that independently
--                                              -- match the filter carry
--                                              -- lit_live = true.  nil for flat
--                                              -- blocks (single dimmed row) or
--                                              -- when the source line no longer
--                                              -- resolves to the captured task.
--     linger_ancestors          = table|nil,   -- tree blocks only: dim
--                                              -- connector-ancestor breadcrumb
--                                              -- rows (tree.ancestor_rows)
--                                              -- rendered above the block;
--                                              -- layout's emit_linger dedups
--                                              -- them against live breadcrumbs
--   }
-- When a task was visible in multiple blocks/groups pre-exit, one entry per
-- (block, group) appearance is created (group-by-tags can yield several
-- appearances per block).
--
-- The `matched` flag (was the prior row a LIT MATCHED root?) lives on the
-- prior render's line_map metadata and on the pre_clear_map appearance tuples
-- built here — it gates tree-linger promotion but is NOT stored on entries.
--
-- ── Lifecycle ────────────────────────────────────────────────────────────────
--   1. RECORDED:  status-change commands (toggle/done/cancel/onHold/
--      inProgress), edit.flush's status-edit path, and revert's
--      classify_and_commit push a pending entry via
--      render._record_pending_linger() → make_pending_entry().
--   2. PROMOTED:  the next render_buffer calls decide(); pending entries whose
--      task left the live filter set become linger entries, positioned via the
--      pre-clear line_map (block/group/index).  Pending is then drained.
--   3. REBUILT:   on EVERY subsequent rerender, kept tree lingers get their
--      linger_subtree / linger_ancestors rebuilt from the current node model
--      (never replayed from a stale snapshot), and an in-place edit's fresh
--      pending entry refreshes the kept entry's task.
--   4. DROPPED:   an entry is dropped when its task re-enters the live set,
--      its line renders live in its block anyway, or its block disappeared.
--   5. CLEARED:   manual refresh (render.refresh_with_clear_lingers), buffer
--      reload / BufDelete (render.clear_state) wipe both tables wholesale.

local M = {}

--- Stable identity key for a source line.
--- @param p string|nil  source path
--- @param l integer|nil source line (1-indexed)
--- @return string
local function entry_key(p, l)
  return (p or "") .. "\0" .. tostring(l or 0)
end

--- Build a pending-linger entry (see shape above).
---
--- Deep-copies the task and refreshes raw_line to reflect the post-mutation
--- state.  task.raw_line was captured by parse.lua at parse time (PRE-
--- mutation), so without this the linger entry's source_text would mismatch
--- the actual disk content — drift would fire on any subsequent operation
--- against the lingered row (e.g. a second <leader>tt to un-toggle).
---
--- @param src_path         string
--- @param src_line         integer  1-indexed source line at toggle time
--- @param source_text_hash string|nil  sha256[:16] of the source line
--- @param task             table    parsed Task post-mutation
--- @return table  pending entry
function M.make_pending_entry(src_path, src_line, source_text_hash, task)
  local task_copy = vim.deepcopy(task)
  local serialize = require("obsidian-tasks.task.serialize")
  task_copy.raw_line = serialize.serialize(task_copy)
  return {
    src_path = src_path,
    src_line = src_line,
    source_text_hash = source_text_hash,
    task = task_copy,
  }
end

--- Rebuild a TREE linger's subtree block + ancestor breadcrumbs from the
--- CURRENT node model.  Used at promotion AND for every kept linger on
--- every rerender: the subtree captured at promotion time goes stale the
--- moment any line of it is edited (the lingered task left the FILTER,
--- not the FILE — its descendants remain editable through the lingered
--- block).  Replaying a stale snapshot redraws pre-edit rows whose meta
--- then mismatches disk, so every following edit on them false-positives
--- the "source drift" check.
---
--- Stale-line guard (same as the original promotion-time guard): the
--- subtree is attached only when ent.src_line still resolves to a task
--- whose description matches the captured linger task — description is
--- checkbox-state-independent, so it survives the status flip that
--- created the linger.  On mismatch/absence the entry falls back to a
--- single dimmed root row.  ent.task is NOT touched: the ROOT row renders
--- from the capture-time task (refreshed via the pending_by_key adoption
--- in decide() on in-place edits), which stays authoritative even when
--- the node model lags a just-applied mutation.
---
--- @param ent table  linger entry (mutated: linger_subtree / linger_ancestors)
--- @param ctx table  { group_name = string|nil, group_index = integer|nil,
---                     matched_keys = table|nil  -- "path\0line" → true for the
---                                               -- block+group's matched tasks }
function M.rebuild_tree_linger(ent, ctx)
  local group_name, group_index, matched_keys = ctx.group_name, ctx.group_index, ctx.matched_keys
  local index = require("obsidian-tasks.index")
  local tree_mod = require("obsidian-tasks.query.tree")
  local nodes = index.nodes_for(ent.src_path) or {}
  local sub = tree_mod.subtree_rows(nodes, ent.src_path, ent.src_line, {
    matched = true,
    dim = false,
    fold_group = 1,
    group_name = group_name or "",
    group_index = group_index or 0,
  })
  local root_row = sub[1]
  local resolved_desc = root_row and root_row.task and root_row.task.description
  local captured_desc = ent.task and ent.task.description
  if #sub > 0 and resolved_desc ~= nil and resolved_desc == captured_desc then
    -- A descendant TASK that still independently matches the block's
    -- filter renders LIT inside the lingered block (D2: only rows not in
    -- the group's matched set dim).  layout's emit_linger reads this flag;
    -- rows without it dim with the block as before.
    if matched_keys then
      for j = 2, #sub do
        local row = sub[j]
        if row.kind == "task" and row.src_line ~= nil and matched_keys[entry_key(ent.src_path, row.src_line)] then
          row.lit_live = true
        end
      end
    end
    ent.linger_subtree = sub
    -- The dim connector-ancestor breadcrumb above the lingered root
    -- lingers WITH the block (otherwise the root renders as an orphaned
    -- indented row once its ancestors lose their last live descendant).
    -- layout's emit_linger dedups these against breadcrumbs a still-live
    -- sibling already emits in the same group.
    ent.linger_ancestors = tree_mod.ancestor_rows(nodes, ent.src_path, ent.src_line, {
      group_name = group_name or "",
      group_index = group_index or 0,
    })
  else
    ent.linger_subtree = nil
    ent.linger_ancestors = nil
  end
end

--- The per-render linger decision: from the new query results (per_block),
--- the prior render's line maps (pre_clear_state), the pending entries, and
--- the currently-displayed lingers, compute the NEXT linger list.
---
--- Promotes pending entries whose task left the live set, keeps/drops/
--- rebuilds existing lingers, and buckets the result by block for layout.
--- Operates as a no-op when args.linger_enabled is false (pending is always
--- empty in that mode and any leftover lingers drop naturally).
---
--- Kept `existing` entries are mutated in place (task adoption + tree
--- rebuild) and carried into the returned list; the caller owns storing the
--- result back on its state tables and draining pending.
---
--- @param args table  {
---   per_block       = table[],   -- pass-1 results: { block, fence_first0,
---                                --   fence_last0, ast, result, parse_ok, .. }
---   pre_clear_state = table|nil, -- M._buffer_state[bufnr] captured BEFORE
---                                --   clear (per-block line_map source)
---   pending         = table[],   -- pending entries (see shape above)
---   existing        = table[],   -- currently-displayed linger entries
---   linger_enabled  = boolean,   -- opts.linger_on_filter_exit ~= false
--- }
--- @return table[] new_lingers       the next M._lingers[bufnr] list
--- @return table   lingers_by_block  block_idx → list of entries (layout input)
function M.decide(args)
  local per_block = args.per_block
  local pre_clear_state = args.pre_clear_state
  local pending = args.pending or {}
  local existing = args.existing or {}
  local new_lingers = {}

  -- live_set across all blocks (post-rerender), keyed by (src_path, src_line)
  local live_set = {}
  for _, pb in ipairs(per_block) do
    if pb.result and pb.result.groups then
      for _, g in ipairs(pb.result.groups) do
        for _, t in ipairs(g.tasks or {}) do
          live_set[entry_key(t._src_path, t._src_line)] = true
        end
      end
    end
  end

  -- pre_clear_map: (src_path, src_line) → block_idx → list of
  -- {group_name, group_index} tuples (one per appearance in that block;
  -- group-by-tags can yield multiple appearances of the same task per
  -- block).  Used to recover prior position context when promoting a
  -- pending linger so it slots back at its prior visual index.
  local pre_clear_map = {}
  if pre_clear_state then
    for i, blk in ipairs(pre_clear_state) do
      for _, meta in pairs(blk.line_map or {}) do
        local key = entry_key(meta.src_path, meta.src_line)
        pre_clear_map[key] = pre_clear_map[key] or {}
        pre_clear_map[key][i] = pre_clear_map[key][i] or {}
        table.insert(pre_clear_map[key][i], {
          group_name = meta.group_name,
          group_index = meta.group_index,
          -- Was this row a LIT MATCHED root?  Tree-linger promotion is gated
          -- on it (only a matched root lingers as a subtree block).
          matched = meta.matched or false,
        })
      end
    end
  end

  -- Per-block LIVE ROW keys: every (path,line) the block will render live
  -- as a SUBSTANTIVE row — lit matched roots and dragged descendants for
  -- tree blocks (result.tree_rows with fold_group > 0); matched tasks for
  -- flat blocks.  A linger for one of these lines would render a SECOND
  -- managed row for the same disk line (or, via the Q8 linger-wins dedup,
  -- shadow the live row) — both the keep and the promotion steps below
  -- drop such lingers, since the line stays visible live, rebuilt fresh
  -- from the node model.
  --
  -- Connector-ancestor BREADCRUMBS (fold_group == 0) are deliberately NOT
  -- keyed: a toggled-Done root whose still-matching child keeps it visible
  -- as a breadcrumb must STILL linger as a whole subtree block — the
  -- breadcrumb carries only the ancestor chain, so dropping the linger
  -- would instantly vanish the root's OTHER branches (non-matching
  -- bullets / done descendants) that only the linger keeps on screen.
  -- The Q8 dedup then suppresses the live child unit (and its breadcrumb)
  -- in favor of the lingered block, so no line renders twice.
  local live_rows_by_block = {}
  for i, pb in ipairs(per_block) do
    local keys = {}
    if pb.result and pb.result.tree_rows then
      for _, row in ipairs(pb.result.tree_rows) do
        if row.src_line ~= nil and row.fold_group ~= 0 then
          keys[entry_key(row.src_path, row.src_line)] = true
        end
      end
    elseif pb.result and pb.result.groups then
      for _, g in ipairs(pb.result.groups) do
        for _, t in ipairs(g.tasks or {}) do
          keys[entry_key(t._src_path, t._src_line)] = true
        end
      end
    end
    live_rows_by_block[i] = keys
  end

  -- Per-block, per-group MATCHED task keys (same sets tree.assemble dims
  -- by): block_idx → group_name → { "path\0line" = true }.  Used when
  -- rebuilding a lingered subtree so a descendant that still INDEPENDENTLY
  -- matches the block's filter renders LIT inside the lingered block (D2
  -- invariant) — its own live unit is suppressed in the block by the Q8
  -- linger-wins dedup, so the lingered copy is the only one on screen.
  local matched_keys_by_block = {}
  for i, pb in ipairs(per_block) do
    local by_group = {}
    if pb.result and pb.result.groups then
      for _, g in ipairs(pb.result.groups) do
        local gname = g.name or ""
        local set = by_group[gname] or {}
        for _, t in ipairs(g.tasks or {}) do
          set[entry_key(t._src_path, t._src_line)] = true
        end
        by_group[gname] = set
      end
    end
    matched_keys_by_block[i] = by_group
  end

  -- Pending entries by key: an in-place edit to an already-lingered root
  -- records a fresh pending entry (post-mutation task) whose own promotion
  -- is gated off below (linger rows carry matched=false).  Adopt its task
  -- into the kept entry so the rebuild guard compares against the CURRENT
  -- description, not the capture-time one.
  local pending_by_key = {}
  for _, ent in ipairs(pending) do
    pending_by_key[entry_key(ent.src_path, ent.src_line)] = ent
  end

  -- Keep existing lingers unless their task re-entered the live filter,
  -- their line renders live anyway (dragged descendant / connector
  -- breadcrumb of a live root), or their associated block no longer
  -- exists.  Kept TREE lingers are rebuilt from the current node model —
  -- never replayed from the promotion-time snapshot (see
  -- rebuild_tree_linger).
  for _, ent in ipairs(existing) do
    local key = entry_key(ent.src_path, ent.src_line)
    local block_present = ent.block_idx == nil or ent.block_idx <= #per_block
    local live_in_block = ent.block_idx ~= nil
      and live_rows_by_block[ent.block_idx] ~= nil
      and live_rows_by_block[ent.block_idx][key] == true
    if not live_set[key] and block_present and not live_in_block then
      local fresher = pending_by_key[key]
      if fresher and fresher.task then
        ent.task = vim.deepcopy(fresher.task)
      end
      local pb = ent.block_idx ~= nil and per_block[ent.block_idx] or nil
      if pb and pb.ast and pb.ast.tree then
        local matched_keys = (matched_keys_by_block[ent.block_idx] or {})[ent.prior_group_name or ""]
        M.rebuild_tree_linger(ent, {
          group_name = ent.prior_group_name,
          group_index = ent.prior_index_within_group,
          matched_keys = matched_keys,
        })
      end
      new_lingers[#new_lingers + 1] = ent
    end
  end

  -- Promote pending entries whose task isn't in the new live set.  Use
  -- pre_clear_map to determine which block(s) and group(s) the task
  -- previously occupied; emit one linger entry per (block, group)
  -- appearance, carrying prior_group_name + prior_index_within_group so
  -- layout can splice it back at its prior position.
  if args.linger_enabled then
    for _, ent in ipairs(pending) do
      local key = entry_key(ent.src_path, ent.src_line)
      if not live_set[key] then
        local block_map = pre_clear_map[key]
        if block_map then
          for i, appearances in pairs(block_map) do
            -- Skip blocks where the line renders live anyway as a lit
            -- root or dragged descendant of a still-live root — the live
            -- row is fresher than any snapshot, and two managed rows per
            -- disk line corrupt locate/drift.  (A line live only as a
            -- connector BREADCRUMB does not count — see live_rows_by_block.)
            if i <= #per_block and not live_rows_by_block[i][key] then
              -- For a `show tree` block, the lingered root must linger AS A
              -- WHOLE SUBTREE BLOCK: the task left the FILTER, not the FILE,
              -- so its descendant subtree still lives in the index.  Rebuild
              -- it from index.nodes_for + tree.subtree_rows (the SAME slice
              -- assemble uses) and attach the rows to each linger copy;
              -- layout renders them dimmed as one fold unit.  Flat blocks
              -- leave linger_subtree nil and render a single dimmed row.
              local block_is_tree = per_block[i].ast and per_block[i].ast.tree
              for _, appearance in ipairs(appearances) do
                -- TREE gate: only a LIT MATCHED root lingers (as a subtree
                -- block).  A dragged DESCENDANT (matched=false) never left
                -- the FILTER — it was pulled in by subtree-drag — so it must
                -- NOT linger.  Skip its promotion entirely.  Flat rows have
                -- no matched flag and always linger (unchanged behavior).
                if not (block_is_tree and not appearance.matched) then
                  local copy = vim.deepcopy(ent)
                  copy.block_idx = i
                  copy.prior_group_name = appearance.group_name
                  copy.prior_index_within_group = appearance.group_index
                  if block_is_tree then
                    local matched_keys = (matched_keys_by_block[i] or {})[appearance.group_name or ""]
                    M.rebuild_tree_linger(copy, {
                      group_name = appearance.group_name,
                      group_index = appearance.group_index,
                      matched_keys = matched_keys,
                    })
                  end
                  new_lingers[#new_lingers + 1] = copy
                end
              end
            end
          end
        end
        -- else: no pre-clear record (task never visible in this buffer);
        -- nothing to linger against.
      end
    end
  end

  -- Pre-bucket lingers by block_idx for fast Pass-2 filtering.
  local lingers_by_block = {}
  for _, l in ipairs(new_lingers) do
    local i = l.block_idx
    if i then
      lingers_by_block[i] = lingers_by_block[i] or {}
      table.insert(lingers_by_block[i], l)
    end
  end

  return new_lingers, lingers_by_block
end

return M
