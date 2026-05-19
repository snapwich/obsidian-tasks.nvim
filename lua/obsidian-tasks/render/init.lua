-- lua/obsidian-tasks/render/init.lua
-- Render orchestrator: drives the query → layout → draw pipeline for every
-- ```tasks block in a buffer.
--
-- Key responsibilities:
--   • Scan buffers for ```tasks fences (has_tasks_block / find_blocks).
--   • For each block: parse query → run against index → layout → draw.
--   • Handle multi-block buffers (blocks render independently).
--   • Catch Lua exceptions and emit an INTERNAL ERROR line in place of results.
--   • Lazy index init: kick off a vault walk on first render if index is empty.
--   • Track per-buffer state in M._buffer_state (used by BufWritePost refresh).

local M = {}

-- Eagerly alias both possible require keys to the same module instance.
-- Lua's package.loaded uses the require string as the cache key, so
-- `require("obsidian-tasks.render")` and `require("obsidian-tasks.render.init")`
-- otherwise load this file twice and create two independent M tables with
-- separate _buffer_state / _lingers tables.  This caused two real bugs:
--   • P9 group_attr ctx was always {} (edit.lua used .init; tests used .render)
--   • BufDelete autocmd hit nil _lingers (autocmds used .render; init.lua's
--     buffer state lived on the other instance)
-- Setting both keys here makes the second require return this same M.
package.loaded["obsidian-tasks.render"] = M
package.loaded["obsidian-tasks.render.init"] = M

-- ── Module-level opts ─────────────────────────────────────────────────────────
-- Populated by M.configure(opts) called from init.setup().
-- Default: default_folded=true mirrors the config.lua default.
M._opts = { default_folded = true }

--- Store plugin opts for use by render_buffer / rerender_buffer.
--- Called from init.lua after opts are merged and validated.
--- @param opts table  merged plugin opts (see config.lua)
function M.configure(opts)
  M._opts = opts or {}
end

--- Record a task that should linger on the next rerender if it exits the
--- buffer's live filter set.  No-op when linger_on_filter_exit is false.
---
--- Called from cmd/{toggle,done,cancel,onHold,inProgress}.lua and from
--- render/revert.lua's classify_and_commit pass.  `bufnr` is the buffer the
--- user acted in (i.e. nvim_get_current_buf() at cmd-dispatch time), NOT the
--- source buffer the cmd writes to — only acting-buffer state can be promoted
--- to a visible linger.
---
--- @param bufnr            integer
--- @param src_path         string
--- @param src_line         integer  1-indexed source line at toggle time
--- @param source_text_hash string|nil  sha256[:16] of the source line
--- @param task             table    parsed Task post-mutation
function M._record_pending_linger(bufnr, src_path, src_line, source_text_hash, task)
  if not M._opts or M._opts.linger_on_filter_exit == false then
    return
  end
  if not src_path or not src_line then
    return
  end
  -- Deep-copy the task and refresh raw_line to reflect the post-mutation
  -- state.  task.raw_line was captured by parse.lua at parse time (PRE-
  -- mutation), so without this the linger entry's source_text would mismatch
  -- the actual disk content — drift would fire on any subsequent operation
  -- against the lingered row (e.g. a second <leader>tt to un-toggle).
  local task_copy = vim.deepcopy(task)
  local serialize = require("obsidian-tasks.task.serialize")
  task_copy.raw_line = serialize.serialize(task_copy)
  M._pending_lingers[bufnr] = M._pending_lingers[bufnr] or {}
  table.insert(M._pending_lingers[bufnr], {
    src_path = src_path,
    src_line = src_line,
    source_text_hash = source_text_hash,
    task = task_copy,
  })
end

--- Refresh a buffer's renders AND clear all linger state.
--- Used by manual refresh paths (:ObsidianTask refresh, <leader>tr).
--- Other rerender triggers (BufWritePost, FocusGained, reverse_index) keep
--- lingers intact via rerender_buffer.
---
--- @param bufnr     integer
--- @param workspace table?
function M.refresh_with_clear_lingers(bufnr, workspace)
  M._lingers[bufnr] = nil
  M._pending_lingers[bufnr] = nil
  -- Manual refresh is the user's explicit "discard plugin history" gesture —
  -- drop the per-dashboard undo/redo rings too.
  local ok, cmd = pcall(require, "obsidian-tasks.cmd")
  if ok and type(cmd.clear_dashboard_undo) == "function" then
    cmd.clear_dashboard_undo(bufnr)
  end
  M.rerender_buffer(bufnr, workspace)
end

--- Mark a windowless buffer for a deferred sync rerender on its next BufEnter.
---
--- Called by the reverse_index propagation paths (BufWritePost in autocmds.lua,
--- apply_source_edit in cmd/init.lua) INSTEAD of rerendering a windowless
--- buffer directly: a clear+render on a buffer with no window drifts its
--- stored cursor (line removals during clear carry it, and rerender_buffer's
--- cursor save/restore is a no-op because win_findbuf finds nothing).  We
--- defer to the buffer's next BufEnter, when it has a window and the cursor
--- can be preserved.
---
--- Idempotent — only one BufEnter autocmd is registered per buffer even if
--- several source writes land before the user switches to it.
---
--- @param bufnr integer
function M.mark_dirty_for_deferred_sync(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.b[bufnr].obsidian_tasks_sync_dirty then
    return -- a BufEnter autocmd is already pending for this buffer
  end
  vim.b[bufnr].obsidian_tasks_sync_dirty = true
  vim.api.nvim_create_autocmd("BufEnter", {
    buffer = bufnr,
    once = true,
    desc = "obsidian-tasks: deferred dashboard sync after off-screen source edit",
    callback = function()
      vim.b[bufnr].obsidian_tasks_sync_dirty = nil
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      -- The current window now shows this buffer; capture the cursor before
      -- the clear+render pass.  rerender_buffer also saves/restores cursors
      -- for visible windows, but we restore explicitly afterwards to guard
      -- against the rendered task at the old row shifting on the rerender.
      local cursor = vim.api.nvim_win_get_cursor(0)
      local path = vim.api.nvim_buf_get_name(bufnr)
      local ws
      pcall(function()
        ws = require("obsidian-tasks.util.obsidian").workspace_for_path(path)
      end)
      M.rerender_buffer(bufnr, ws)
      local nlines = vim.api.nvim_buf_line_count(bufnr)
      local row = math.max(1, math.min(cursor[1], math.max(1, nlines)))
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      local col = math.max(0, math.min(cursor[2], #line))
      pcall(vim.api.nvim_win_set_cursor, 0, { row, col })
    end,
  })
end

-- ── Per-buffer orchestrator state ─────────────────────────────────────────────
--
--   M._buffer_state[bufnr] = {
--     {
--       block_range       = { fence_start, fence_end },  -- 1-indexed source/cleared positions
--       fence_first       = integer,    -- 0-indexed rendered fence row at last render time (stale after edits)
--       managed_fence_id  = integer|nil, -- managed-NS extmark ID for the opening fence (live-tracked)
--       render_range      = { first, last } | nil,  -- 0-indexed inserted task lines (stale after edits)
--       extmark_ids       = { eid, ... },            -- task extmark IDs (draw NS)
--       line_map          = { [lnum] = {src_path, src_line, src_hash, rendered_text, group_name, group_index, linger?, dim?} },
--     },
--     ...
--   }
--
M._buffer_state = {}

-- ── Linger state ─────────────────────────────────────────────────────────────
-- _pending_lingers[bufnr]:  recently-mutated tasks awaiting linger promotion
--                           on the next rerender.  Status-change commands
--                           (toggle/done/cancel/onHold/inProgress) and the
--                           direct status-edit revert path push here via
--                           M._record_pending_linger().  Consumed by the
--                           next render_buffer call.
-- _lingers[bufnr]:          promoted lingers currently displayed in the
--                           buffer.  Survive BufWritePost/FocusGained/
--                           reverse_index re-renders; cleared by manual
--                           refresh, buffer reload, or task re-entering
--                           the live filter set.
--
-- Entry shape:
--   { src_path, src_line, source_text_hash, task,
--     block_idx?, prior_group_name?, prior_index_within_group? }
--
-- block_idx, prior_group_name, prior_index_within_group are set at
-- promotion time (pending → linger).  Lingers are displayed only in their
-- pre-exit block.  When a task was in multiple blocks/groups pre-exit, one
-- entry per (block, group) appearance is created (group-by-tags can yield
-- multiple appearances per block).  prior_index_within_group is the 0-based
-- position within the prior render's group body; layout uses it to splice
-- the linger back at its prior slot (linger holds position).
M._pending_lingers = {}
M._lingers = {}

-- ── Diagnostic namespace ──────────────────────────────────────────────────────
-- Every render flushes invalid-field diagnostic entries (built by draw from
-- the layout's invalid_ranges metadata) under this namespace.  vim.diagnostic.
-- set replaces the namespace's entries for the buffer, so a single set call
-- per render handles both "add new" and "clear old".  clear_buffer +
-- BufDelete reset the namespace to drop diagnostics when the render goes
-- away.
M._diag_ns = vim.api.nvim_create_namespace("obsidian_tasks_diagnostics")

-- ── Source-row diagnostic namespace ───────────────────────────────────────────
-- Separate namespace for diagnostics on source-file task lines (every .md in
-- a workspace).  Kept distinct from the dashboard rendered-region namespace
-- (M._diag_ns) so a same-buffer dashboard can carry both kinds without one
-- clobbering the other via vim.diagnostic.set.
M._source_diag_ns = vim.api.nvim_create_namespace("obsidian_tasks_source_diagnostics")

--- Rebuild source-row diagnostics for *bufnr* from the in-memory index entry
--- for *file_path*.  Each task whose _invalid_ranges is populated emits one
--- diagnostic at its source row with byte-accurate col/end_col in raw_line
--- coordinates and the parser's error message.  vim.diagnostic.set replaces
--- the namespace's entries for the buffer; an empty list therefore clears.
---
--- @param bufnr     integer
--- @param file_path string  absolute path; uses the index's entry for it
function M.refresh_source_diagnostics(bufnr, file_path)
  if not vim.api.nvim_buf_is_valid(bufnr) or not file_path or file_path == "" then
    return
  end
  local diags = {}
  local idx = require("obsidian-tasks.index")
  local raw = type(idx._raw) == "function" and idx._raw() or {}
  local entry = raw[file_path]
  if entry and entry.tasks then
    for _, item in ipairs(entry.tasks) do
      local task = item.task
      local line_num = item.line_num or task._src_line
      if task and line_num and task._invalid_ranges then
        for field_key, range in pairs(task._invalid_ranges) do
          local message = (task._errors and task._errors[field_key]) or "invalid field value"
          diags[#diags + 1] = {
            lnum = line_num - 1, -- index uses 1-indexed lines; diagnostics 0-indexed
            col = math.max(0, range[1] - 1),
            end_lnum = line_num - 1,
            end_col = math.max(0, range[2] - 1),
            message = message,
            severity = vim.diagnostic.severity.WARN,
            source = "obsidian-tasks",
          }
        end
      end
    end
  end
  pcall(vim.diagnostic.set, M._source_diag_ns, bufnr, diags)
end

-- ── Lazy-init guard ───────────────────────────────────────────────────────────
-- Tracks workspaces for which a refresh_all walk has already been kicked off.
-- Prevents re-triggering the walk on each recursive render call when the vault
-- has zero tasks (which would produce an infinite loop).
-- Key: workspace object (identity), value: true.
local _lazy_init_started = {}

-- ── Opening-fence pattern ─────────────────────────────────────────────────────

--- Match the opening fence of a tasks block.
--- @param line string
--- @return boolean
local function is_open_fence(line)
  -- Match exactly ```tasks (with optional leading whitespace).
  return line:match("^%s*```tasks%s*$") ~= nil
end

--- Match a generic closing fence (``` only, not ```tasks).
--- @param line string
--- @return boolean
local function is_close_fence(line)
  return line:match("^%s*```%s*$") ~= nil
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Return true if *bufnr* contains at least one ```tasks block.
--- Single-pass early-exit scan.
---
--- @param bufnr integer
--- @return boolean
function M.has_tasks_block(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if is_open_fence(line) then
      return true
    end
  end
  return false
end

--- Return the list of ```tasks blocks in *bufnr*.
--- Each entry: { fence_start, query_start, query_end, fence_end }  (1-indexed).
--- An empty query (opening fence immediately followed by closing fence) has
--- query_start > query_end.
---
--- @param bufnr integer
--- @return table[]
function M.find_blocks(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blocks = {}
  local open_at = nil -- 1-indexed line number of the current opening fence

  for i, line in ipairs(lines) do
    if open_at == nil then
      if is_open_fence(line) then
        open_at = i
      end
    else
      if is_close_fence(line) then
        blocks[#blocks + 1] = {
          fence_start = open_at,
          query_start = open_at + 1,
          query_end = i - 1,
          fence_end = i,
        }
        open_at = nil
      end
    end
  end

  return blocks
end

--- Render all ```tasks blocks in *bufnr*.
---
--- Pipeline per block:
---   buffer text → query/parse → query/run (index) → render/layout → render/draw
---
--- If the index is empty when the first render runs, an async vault walk is
--- kicked off and render is retried once the walk completes (non-blocking).
---
--- After rendering, applies manual folds for each block.
---
--- @param bufnr     integer
--- @param workspace table?  workspace object (required for lazy index init)
function M.render_buffer(bufnr, workspace)
  local draw = require("obsidian-tasks.render.draw")
  local layout_mod = require("obsidian-tasks.render.layout")
  local query_parse = require("obsidian-tasks.query.parse")
  local query_run = require("obsidian-tasks.query.run")
  local index = require("obsidian-tasks.index")
  local folds_mod = require("obsidian-tasks.render.folds")
  local revert = require("obsidian-tasks.render.revert")
  local hygiene = require("obsidian-tasks.render.hygiene")

  -- ── 0. Guard: buffer must still be valid ───────────────────────────────────
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- ── 1. Check for tasks blocks ──────────────────────────────────────────────
  if not M.has_tasks_block(bufnr) then
    return
  end

  -- Plugin mutations are not user edits — suppress eventignore signals, keep
  -- them out of undo, and (if clean_baseline allows) clear `modified` after.
  hygiene.with_clean_buffer(bufnr, function()
    -- Suppress on_lines callbacks for the duration of this render so our own
    -- buffer mutations don't trigger spurious reverts.  Placed after the cheap
    -- guard checks so we only touch the suppress counter when we will actually
    -- mutate the buffer.
    --
    -- The pcall wrapper below guarantees unsuppress() is called even if an
    -- unexpected exception escapes the render pipeline (e.g. from draw or folds).
    revert.suppress(bufnr)
    local _render_ok, _render_err = pcall(function()
      -- ── 2. Lazy index init ─────────────────────────────────────────────────────
      -- Per-workspace: kick off a full vault walk on the first dashboard
      -- render so the index is complete before queries run.
      --
      -- This used to additionally gate on `index.tasks_in(...)() == nil`
      -- (skip the walk if any tasks were already indexed), but that broke
      -- once BufReadPost started populating per-file index entries for
      -- source-row diagnostics: the dashboard would observe a partial index
      -- (only files the user had opened) and skip the full walk, producing
      -- results that depended on which buffers were opened first.
      --
      -- refresh_all is idempotent over an already-populated index (each
      -- refresh_file is mtime-gated), so the only cost of always firing it
      -- is the ripgrep walk itself — which the user already pays on the
      -- first dashboard render of a session.
      do
        if workspace and not _lazy_init_started[workspace] then
          _lazy_init_started[workspace] = true
          index.refresh_all(workspace, function()
            vim.schedule(function()
              M.render_buffer(bufnr, workspace)
            end)
          end)
        end
      end

      -- ── 3. Capture pre-clear state + clear previous render ─────────────────
      -- pre_clear_state lets the linger-decision step below find which block(s)
      -- a now-exited task previously appeared in.  Capture BEFORE clear_buffer
      -- since clear_buffer wipes M._buffer_state[bufnr].
      local pre_clear_state = M._buffer_state[bufnr]
      M.clear_buffer(bufnr)

      -- ── 4. Find all blocks (positions in now-cleared buffer) ───────────────────
      local blocks = M.find_blocks(bufnr)
      if #blocks == 0 then
        -- No complete (paired) blocks found (e.g. unclosed fence); bail out.
        -- unsuppress() is called by the pcall wrapper below.
        return
      end

      -- ── 5a. Pass 1: parse + run each block ─────────────────────────────────
      -- Collect ASTs and query results before any layout/draw so the linger
      -- decision (5b) can compute the buffer-wide live set.  No buffer
      -- mutations in this pass, so positions don't need offset adjustment.
      local per_block = {}
      for _, block in ipairs(blocks) do
        local fence_first0 = block.fence_start - 1
        local fence_last0 = block.fence_end - 1

        local query_text = ""
        if block.query_start <= block.query_end then
          local q_lines = vim.api.nvim_buf_get_lines(bufnr, block.query_start - 1, block.query_end, false)
          query_text = table.concat(q_lines, "\n")
        end

        local ast, result
        local ok, err = pcall(function()
          ast = query_parse.parse(query_text)
          local ws_root = workspace and workspace.root or nil
          result = query_run.run(ast, index, ws_root)
        end)

        per_block[#per_block + 1] = {
          block = block,
          fence_first0 = fence_first0,
          fence_last0 = fence_last0,
          ast = ok and ast or nil,
          result = ok and result or nil,
          parse_ok = ok,
          parse_err = err,
        }
      end

      -- ── 5b. Linger decision ────────────────────────────────────────────────
      -- Use live tasks from per_block results and pre_clear_state's line_map
      -- to promote / drop pending entries and existing lingers.  Operates as
      -- a no-op when linger_on_filter_exit = false (pending is always empty
      -- and any leftover _lingers is dropped naturally).
      local function entry_key(p, l)
        return (p or "") .. "\0" .. tostring(l or 0)
      end

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
            })
          end
        end
      end

      local pending = M._pending_lingers[bufnr] or {}
      local existing = M._lingers[bufnr] or {}
      local new_lingers = {}

      -- Keep existing lingers unless their task re-entered the live filter or
      -- their associated block no longer exists.
      for _, ent in ipairs(existing) do
        local key = entry_key(ent.src_path, ent.src_line)
        local block_present = ent.block_idx == nil or ent.block_idx <= #per_block
        if not live_set[key] and block_present then
          new_lingers[#new_lingers + 1] = ent
        end
      end

      -- Promote pending entries whose task isn't in the new live set.  Use
      -- pre_clear_map to determine which block(s) and group(s) the task
      -- previously occupied; emit one linger entry per (block, group)
      -- appearance, carrying prior_group_name + prior_index_within_group so
      -- layout can splice it back at its prior position.
      if M._opts and M._opts.linger_on_filter_exit ~= false then
        for _, ent in ipairs(pending) do
          local key = entry_key(ent.src_path, ent.src_line)
          if not live_set[key] then
            local block_map = pre_clear_map[key]
            if block_map then
              for i, appearances in pairs(block_map) do
                if i <= #per_block then
                  for _, appearance in ipairs(appearances) do
                    local copy = vim.deepcopy(ent)
                    copy.block_idx = i
                    copy.prior_group_name = appearance.group_name
                    copy.prior_index_within_group = appearance.group_index
                    new_lingers[#new_lingers + 1] = copy
                  end
                end
              end
            end
            -- else: no pre-clear record (task never visible in this buffer);
            -- nothing to linger against.
          end
        end
      end

      M._lingers[bufnr] = #new_lingers > 0 and new_lingers or nil
      M._pending_lingers[bufnr] = nil

      -- Pre-bucket lingers by block_idx for fast Pass-2 filtering.
      local lingers_by_block = {}
      for _, l in ipairs(new_lingers) do
        local i = l.block_idx
        if i then
          lingers_by_block[i] = lingers_by_block[i] or {}
          table.insert(lingers_by_block[i], l)
        end
      end

      -- ── 5c. Pass 2: layout + draw each block ───────────────────────────────
      local new_buf_state = {}
      -- `offset` tracks cumulative task lines inserted by prior blocks so we can
      -- adjust fence positions for subsequent blocks.
      local offset = 0
      -- Accumulate fold descriptors { fence_first, fence_last } for post-render fold pass.
      -- Folds cover ONLY the fence lines; rendered task lines stay visible below.
      local fold_blocks = {}
      -- Aggregate diagnostic entries from every block; flushed via
      -- vim.diagnostic.set once after the loop so users see one coherent
      -- diagnostic set per render (no per-block flicker).
      local all_diagnostics = {}

      -- Alias resolver for the [[basename|alias]] backlink suffix.  Notes
      -- without a frontmatter alias render a plain [[basename]] (see layout).
      local resolve_alias = require("obsidian-tasks.render.alias").for_path

      for i, pb in ipairs(per_block) do
        local block = pb.block
        -- 0-indexed positions adjusted by cumulative insertions from prior blocks.
        local fence_first = pb.fence_first0 + offset
        local fence_last = pb.fence_last0 + offset
        local fence_range = { fence_first, fence_last }

        -- Build layout lines (with this block's filtered lingers).
        local layout_lines
        if pb.parse_ok then
          local ok2, err2 = pcall(function()
            layout_lines = layout_mod.layout(pb.result, {
              lingers = lingers_by_block[i] or {},
              group_by = (pb.ast and pb.ast.group_by) or {},
              dim_completed = M._opts and M._opts.dim_completed_tasks ~= false,
              resolve_alias = resolve_alias,
            })
          end)
          if not ok2 then
            pb.parse_ok = false
            pb.parse_err = err2
          end
        end
        if not pb.parse_ok then
          local msg = type(pb.parse_err) == "string" and pb.parse_err or tostring(pb.parse_err)
          layout_lines = {
            {
              kind = "error",
              text = "▼ INTERNAL ERROR: " .. msg,
              src_path = nil,
              src_line = nil,
              src_hash = nil,
              indent = "",
            },
            {
              kind = "footer",
              text = "─",
              src_path = nil,
              src_line = nil,
              src_hash = nil,
              indent = "",
            },
          }
        end

        -- Draw the block.  Returns per-block diagnostic entries which we
        -- aggregate for a single vim.diagnostic.set call after the loop.
        local draw_result = draw.draw(bufnr, fence_range, layout_lines)
        if draw_result and draw_result.diagnostics then
          for _, d in ipairs(draw_result.diagnostics) do
            all_diagnostics[#all_diagnostics + 1] = d
          end
        end

        -- Count tasks inserted for the offset update.
        local n_tasks = 0
        for _, ll in ipairs(layout_lines) do
          if ll.kind == "task" then
            n_tasks = n_tasks + 1
          end
        end

        -- Build per-block orchestrator state from draw's recorded state.
        local block_state_map = draw.render_state(bufnr)
        local block_draw_state = block_state_map and block_state_map[fence_first]

        -- Build line_map: lnum (0-indexed) → src metadata.
        local line_map = {}
        -- Populate line_map from inserted_range + layout_lines task order.
        -- `rendered_text` is the canonical buffer line we just wrote; the
        -- revert/commit path compares it against the live row to detect status
        -- edits and reject any other modification.
        if block_draw_state and block_draw_state.inserted_range then
          local insert_start = block_draw_state.inserted_range[1]
          local task_idx = 0
          for _, ll in ipairs(layout_lines) do
            if ll.kind == "task" then
              local lnum = insert_start + task_idx
              line_map[lnum] = {
                src_path = ll.src_path,
                src_line = ll.src_line,
                src_hash = ll.src_hash,
                rendered_text = ll.text,
                linger = ll.linger or nil,
                dim = ll.dim or nil,
                -- Captured at layout time so promotion can recover the prior
                -- group/position when this task is later lingered.
                group_name = ll.group_name,
                group_index = ll.group_index,
              }
              task_idx = task_idx + 1
            end
          end
        end

        -- Collect task extmark IDs.
        local extmark_ids = {}
        if block_draw_state and block_draw_state.em_map then
          for eid in pairs(block_draw_state.em_map) do
            extmark_ids[#extmark_ids + 1] = eid
          end
        end

        -- Fold range covers only the fence lines so rendered tasks remain visible
        -- below the collapsed query (AC1).
        fold_blocks[#fold_blocks + 1] = { fence_first = fence_first, fence_last = fence_last }

        new_buf_state[#new_buf_state + 1] = {
          block_range = { block.fence_start, block.fence_end },
          fence_first = fence_first, -- 0-indexed rendered fence row (stale if user edits between renders)
          -- managed_fence_id is the managed-NS extmark that Neovim auto-tracks to
          -- the live fence position even after source-line insertions/deletions.
          managed_fence_id = block_draw_state and block_draw_state.managed_fence_id or nil,
          render_range = block_draw_state and block_draw_state.inserted_range or nil,
          extmark_ids = extmark_ids,
          line_map = line_map,
          group_by = (pb.ast and pb.ast.group_by) or {},
          sort_by = (pb.ast and pb.ast.sort_by) or {},
        }

        offset = offset + n_tasks
      end

      M._buffer_state[bufnr] = new_buf_state

      -- Flush aggregated invalid-field diagnostics for this buffer.  Calling
      -- vim.diagnostic.set with the full list replaces any previous entries
      -- in the namespace, so this also serves to clear diagnostics for fields
      -- that are no longer invalid (or no longer rendered).
      pcall(vim.diagnostic.set, M._diag_ns, bufnr, all_diagnostics)

      -- ── 6. Apply manual folds for all rendered blocks ──────────────────────────
      -- Each block is folded across its fence lines only; rendered tasks stay
      -- visible underneath the collapsed fold.  setup_window() is called inside
      -- apply_folds for each window.
      -- Skip folding when default_folded = false: render but leave folds open.
      if M._opts.default_folded ~= false then
        folds_mod.apply_folds(bufnr, fold_blocks)
      end

      -- ── 7. Update reverse index ────────────────────────────────────────────────
      -- Collect the unique set of source paths referenced by this render so
      -- index.reverse_index(path) can return this buffer.
      local paths_set = {}
      for _, block_state in ipairs(new_buf_state) do
        for _, meta in pairs(block_state.line_map) do
          if meta.src_path then
            paths_set[meta.src_path] = true
          end
        end
      end
      index.set_render_paths(bufnr, paths_set)

      -- ── 8. Attach read-only revert listener (idempotent) ──────────────────────
      -- Must be called AFTER managed regions are established so the listener has
      -- valid region extmarks to check against.  Updates the stored workspace on
      -- subsequent calls so rerender_buffer always uses the current workspace.
      --
      -- Pass a closure over `M` (the real module table) as the render function.
      -- This ensures do_revert always calls the real implementation even when a
      -- test has replaced package.loaded["obsidian-tasks.render.init"] with a mock.
      -- render_buffer (not rerender_buffer) is used here: do_revert performs its
      -- own snapshot-based line removal before calling this function, so the
      -- fold-state-preserving rerender_buffer path is not needed.
      revert.attach(bufnr, workspace, function(b, w)
        M.render_buffer(b, w)
      end)
    end) -- end pcall wrapper

    -- Allow on_lines callbacks again now that render is complete.
    -- Called unconditionally so the counter stays balanced even if the render
    -- pipeline threw an unexpected exception.
    revert.unsuppress(bufnr)

    if not _render_ok then
      require("obsidian-tasks.log").warn("render_buffer error: " .. tostring(_render_err))
    end
  end) -- end with_clean_buffer

  -- After a successful (or partial) render the dashboard has no pending user
  -- edits we don't already know about: the only mutations were ours.
  hygiene.mark_clean(bufnr)
end

--- Refresh a buffer: clear all renders then re-render from scratch.
---
--- @param bufnr     integer
--- @param workspace table?
function M.refresh_buffer(bufnr, workspace)
  -- render_buffer does its own internal clear; an explicit clear here would
  -- wipe pre_clear_state needed for linger promotion.
  M.render_buffer(bufnr, workspace)
end

--- Re-render a buffer while preserving block fold states.
---
--- Used by BufWritePost and FocusGained handlers so that:
---   • Existing blocks retain their open/closed state after re-render.
---   • New blocks (not present in prior render) are folded per default_folded.
---   • Deleted blocks (rendered lines removed by clear) are cleaned up.
---
--- Algorithm:
---   1. Before clearing: snapshot the source-fence-row → fold-state map from
---      the current _buffer_state (compensating for rendered lines so rows match
---      the cleared buffer).
---   2. Clear and re-render (render_buffer applies folds for all blocks when
---      default_folded=true, or leaves them open when default_folded=false).
---   3. For blocks whose old fold state was "open" AND render_buffer applied
---      folds (default_folded=true), re-open those folds.
---
--- @param bufnr     integer
--- @param workspace table?
function M.rerender_buffer(bufnr, workspace)
  local folds_mod = require("obsidian-tasks.render.folds")
  local managed_mod = require("obsidian-tasks.render.managed")

  -- ── 0. Snapshot cursor positions for every window showing this buffer ─────
  -- Restored after the clear+render pass so user-triggered rerenders (`<leader>tr`,
  -- `<leader>tT`, auto-refresh on save/focus, etc.) don't leave the cursor at
  -- column 0 or at the end of the buffer.  Row clamped to the new line count
  -- and column clamped to the new line length on restore.
  local cursor_saves = {}
  for _, w in ipairs(vim.fn.win_findbuf(bufnr)) do
    cursor_saves[w] = vim.api.nvim_win_get_cursor(w)
  end

  -- ── 1. Snapshot fold states keyed by post-clear source-fence-row ──────────
  -- We use LIVE extmark positions for both fences and task regions, so fold
  -- states remain correct even when source lines have been inserted or deleted
  -- above existing rendered blocks between renders.
  --
  -- Algorithm:
  --   a) Get all live task-region positions via managed.all_regions() — these
  --      are the rows that clear_buffer will remove.
  --   b) For each old block, query its managed_fence_id extmark for the LIVE
  --      fence row (auto-tracked by Neovim despite intervening edits).
  --   c) source_fence_start = live_fence_row − (task lines at rows < live_fence) + 1
  --      This equals the 1-indexed position find_blocks() returns after clear.
  --   d) Sort blocks by live fence row so that when two blocks map to the same
  --      source position (e.g. a deleted block's extmark collapsed onto a
  --      surviving block's fence), the surviving block (higher live row) wins.
  local fold_states = {} -- source_fence_start (1-indexed, post-clear) → "open"|"closed"

  local old_buf_state = M._buffer_state[bufnr]
  if old_buf_state then
    local ns = managed_mod.namespace()

    -- Live task-region positions, sorted ascending by start_row.
    local live_regions = managed_mod.all_regions(bufnr)

    -- Pair each old block with its live fence row (from extmark) or stale fallback.
    local fence_entries = {}
    for _, block_state in ipairs(old_buf_state) do
      local live_fence_row = nil
      local mfid = block_state.managed_fence_id
      if mfid then
        local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mfid, {})
        if pos and pos[1] then
          live_fence_row = pos[1] -- 0-indexed
        end
      end
      -- Fall back to the stale fence_first when managed extmark is unavailable
      -- (e.g. in unit tests that use a mock draw module without real extmarks).
      if live_fence_row == nil then
        live_fence_row = block_state.fence_first
      end
      fence_entries[#fence_entries + 1] = { fence_row = live_fence_row, block_state = block_state }
    end

    -- Sort ascending so higher-row blocks overwrite lower-row blocks when they
    -- share the same computed source position (surviving block wins over deleted).
    table.sort(fence_entries, function(a, b)
      return a.fence_row < b.fence_row
    end)

    for _, entry in ipairs(fence_entries) do
      local live_fence_row = entry.fence_row

      -- Count rendered task lines at rows strictly before this fence.
      -- They will be removed by clear_buffer and must not be counted in
      -- the source (post-clear) position.
      local task_lines_before = 0
      for _, region in ipairs(live_regions) do
        if region[1] < live_fence_row then
          task_lines_before = task_lines_before + (region[2] - region[1] + 1)
        end
      end

      -- 1-indexed source position = what find_blocks() will return after clear.
      local source_fence_start = live_fence_row - task_lines_before + 1

      -- Capture at the LIVE fence row (not the stale fence_first stored in state).
      fold_states[source_fence_start] = folds_mod.capture_fold_state(bufnr, live_fence_row)
    end
  end

  -- ── 2. Re-render ───────────────────────────────────────────────────────────
  -- render_buffer does its own internal clear_buffer and applies folds for ALL
  -- blocks if default_folded=true, or leaves them open if default_folded=false.
  -- Calling clear_buffer here too would wipe M._buffer_state[bufnr] before
  -- render_buffer can capture it as pre_clear_state for linger promotion.
  M.render_buffer(bufnr, workspace)

  -- ── 3. Restore "open" fold states when default_folded=true ─────────────────
  -- When default_folded=false, render_buffer leaves folds open — nothing to do.
  -- When default_folded=true, render_buffer closes all folds; we re-open the
  -- blocks that were open before.
  if M._opts.default_folded ~= false then
    local new_buf_state = M._buffer_state[bufnr]
    if new_buf_state then
      for _, new_block_state in ipairs(new_buf_state) do
        local source_fence_start = new_block_state.block_range[1] -- 1-indexed (cleared buffer)
        local old_state = fold_states[source_fence_start]
        if old_state == "open" then
          -- Block existed before and was open; re-open it.
          -- fence_first is 0-indexed; :foldopen takes 1-indexed.
          folds_mod.open_fold(bufnr, new_block_state.fence_first + 1)
        end
        -- old_state == "closed" → already closed by apply_folds (no action)
        -- old_state == nil      → new block; apply_folds already closed it (default_folded)
      end
    end
  end

  -- ── 4. Restore cursor positions ───────────────────────────────────────────
  -- Row clamped to new line count; column clamped to length of the resulting
  -- line.  nvim_win_set_cursor rejects out-of-range positions, so the clamps
  -- ensure the call succeeds even when the rendered task at the old position
  -- shrank or disappeared.
  local new_line_count = vim.api.nvim_buf_line_count(bufnr)
  for w, pos in pairs(cursor_saves) do
    if vim.api.nvim_win_is_valid(w) then
      local row = math.min(pos[1], new_line_count)
      if row < 1 then
        row = 1
      end
      local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
      local col = math.min(pos[2], #line)
      pcall(vim.api.nvim_win_set_cursor, w, { row, col })
    end
  end
end

--- Drop render state for a buffer WITHOUT mutating buffer lines.
--- Used on BufReadPre when Neovim is about to overwrite buffer contents from
--- disk: extmarks would otherwise survive the reload at clamped positions and
--- the next render's clear_buffer would trust those stale positions and delete
--- the wrong rows.
---
--- @param bufnr integer
function M.clear_state(bufnr)
  local draw = require("obsidian-tasks.render.draw")
  draw.clear_state(bufnr)
  M._buffer_state[bufnr] = nil
  -- Linger state is bound to the buffer's render lifecycle: a reload from disk
  -- (BufReadPre) or BufDelete invalidates any lingered rows, so drop them too.
  M._lingers[bufnr] = nil
  M._pending_lingers[bufnr] = nil
  require("obsidian-tasks.index").clear_render_paths(bufnr)
end

--- Clear all renders for a buffer and drop orchestrator state.
---
--- @param bufnr integer
function M.clear_buffer(bufnr)
  -- Suppress on_lines callbacks while we remove rendered lines so the listener
  -- does not detect managed-region row deletions as user edits and schedule a
  -- spurious revert.
  local revert = require("obsidian-tasks.render.revert")
  local hygiene = require("obsidian-tasks.render.hygiene")

  hygiene.with_clean_buffer(bufnr, function()
    revert.suppress(bufnr)

    local draw = require("obsidian-tasks.render.draw")
    draw.clear(bufnr)
    M._buffer_state[bufnr] = nil
    -- Keep reverse index consistent: bufnr no longer has any active render.
    require("obsidian-tasks.index").clear_render_paths(bufnr)
    -- Drop invalid-field diagnostics tied to the cleared render.
    pcall(vim.diagnostic.reset, M._diag_ns, bufnr)

    revert.unsuppress(bufnr)
  end)
end

return M
