-- lua/obsidian-tasks/render/init.lua
-- Render orchestrator: drives the query → layout → draw pipeline for every
-- ```tasks block in a buffer.
--
-- Key responsibilities:
--   • Scan buffers for ```tasks fences (has_tasks_block / find_blocks).
--   • For each block: parse query → run against index → layout → draw.
--   • Handle multi-block buffers (blocks render independently).
--   • Catch Lua exceptions and emit an INTERNAL ERROR label in place of results.
--   • Lazy index init: kick off a vault walk on first render if index is empty.
--   • Track per-buffer state in M._buffer_state (used by BufWritePost refresh).

local M = {}

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

-- ── Per-buffer orchestrator state ─────────────────────────────────────────────
--
--   M._buffer_state[bufnr] = {
--     {
--       block_range       = { fence_start, fence_end },  -- 1-indexed source/cleared positions
--       fence_first       = integer,    -- 0-indexed rendered fence row at last render time (stale after edits)
--       managed_fence_id  = integer|nil, -- managed-NS extmark ID for the opening fence (live-tracked)
--       render_range      = { first, last } | nil,  -- 0-indexed inserted task lines (stale after edits)
--       extmark_ids       = { eid, ... },            -- task extmark IDs (draw NS)
--       line_map          = { [lnum] = {src_path, src_line, src_hash} },
--     },
--     ...
--   }
--
M._buffer_state = {}

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
--- After rendering, applies manual folds for each block and caches result counts
--- in foldtext.set_result_count so the foldtext function can report them.
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
  local foldtext_mod = require("obsidian-tasks.render.foldtext")

  -- ── 0. Guard: buffer must still be valid ───────────────────────────────────
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- ── 1. Check for tasks blocks ──────────────────────────────────────────────
  if not M.has_tasks_block(bufnr) then
    return
  end

  -- ── 2. Lazy index init ─────────────────────────────────────────────────────
  -- If the index appears empty and we have a workspace, kick off a one-shot
  -- vault walk.  The _lazy_init_started guard prevents re-triggering the walk
  -- on the recursive render call that fires from the completion callback —
  -- which would otherwise loop forever when the vault has zero tasks.
  do
    local any = index.tasks_in(nil)()
    if any == nil and workspace and not _lazy_init_started[workspace] then
      _lazy_init_started[workspace] = true
      -- Start async walk; re-render once complete (non-blocking).
      index.refresh_all(workspace, function()
        vim.schedule(function()
          M.render_buffer(bufnr, workspace)
        end)
      end)
      -- Fall through: render immediately with empty results so the user sees
      -- "0 results" rather than a blank block.
    end
  end

  -- ── 3. Clear previous render ───────────────────────────────────────────────
  -- Clear draw state (extmarks + inserted lines), drop our own state, and
  -- remove any reverse-index associations for this buffer.
  M.clear_buffer(bufnr)

  -- ── 4. Find all blocks (positions in now-cleared buffer) ───────────────────
  local blocks = M.find_blocks(bufnr)
  if #blocks == 0 then
    return
  end

  -- ── 5. Render each block ───────────────────────────────────────────────────
  local new_buf_state = {}
  -- `offset` tracks cumulative task lines inserted by prior blocks so we can
  -- adjust fence positions for subsequent blocks.
  local offset = 0
  -- Accumulate fold descriptors { fence_first, region_end } for post-render fold pass.
  local fold_blocks = {}

  for _, block in ipairs(blocks) do
    -- Convert 1-indexed block positions to 0-indexed, adjusted by offset.
    local fence_first = block.fence_start - 1 + offset
    local fence_last = block.fence_end - 1 + offset
    local fence_range = { fence_first, fence_last }

    -- Extract query text from the adjusted buffer positions.
    local query_text = ""
    if block.query_start <= block.query_end then
      local q_lines =
        vim.api.nvim_buf_get_lines(bufnr, block.query_start - 1 + offset, block.query_end - 1 + offset + 1, false)
      query_text = table.concat(q_lines, "\n")
    end

    -- Run pipeline; catch any Lua exceptions.
    local layout_lines
    local ok, err = pcall(function()
      local ast = query_parse.parse(query_text)
      local result = query_run.run(ast, index)
      layout_lines = layout_mod.layout(result)
    end)

    if not ok then
      -- Emit a single label line with the error message.
      local msg = type(err) == "string" and err or tostring(err)
      layout_lines = {
        {
          kind = "label",
          text = "▶ tasks · INTERNAL ERROR: " .. msg,
          src_path = nil,
          src_line = nil,
          src_hash = nil,
          indent = "",
        },
      }
    end

    -- Draw the block.
    draw.draw(bufnr, fence_range, layout_lines)

    -- Count tasks inserted for the offset update and result count cache.
    local n_tasks = 0
    for _, ll in ipairs(layout_lines) do
      if ll.kind == "task" then
        n_tasks = n_tasks + 1
      end
    end

    -- Cache result count so the foldtext function can report it without re-running.
    foldtext_mod.set_result_count(bufnr, fence_first, n_tasks)

    -- Build per-block orchestrator state from draw's recorded state.
    local block_state_map = draw.render_state(bufnr)
    local block_draw_state = block_state_map and block_state_map[fence_first]

    -- Build line_map: lnum (0-indexed) → src metadata.
    local line_map = {}
    if block_draw_state and block_draw_state.em_map then
      for _, meta in pairs(block_draw_state.em_map) do
        -- em_map keys are extmark IDs; line numbers are recovered via is_render_line.
        -- Store by iterating inserted_range if available.
        _ = meta -- used below via is_render_line; stored in draw state
      end
    end
    -- Populate line_map from inserted_range + layout_lines task order.
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

    -- Determine the end of the managed region (last task line or closing fence).
    local region_end
    if block_draw_state and block_draw_state.inserted_range then
      region_end = block_draw_state.inserted_range[2]
    else
      region_end = fence_last
    end
    fold_blocks[#fold_blocks + 1] = { fence_first = fence_first, region_end = region_end }

    new_buf_state[#new_buf_state + 1] = {
      block_range = { block.fence_start, block.fence_end },
      fence_first = fence_first, -- 0-indexed rendered fence row (stale if user edits between renders)
      -- managed_fence_id is the managed-NS extmark that Neovim auto-tracks to
      -- the live fence position even after source-line insertions/deletions.
      managed_fence_id = block_draw_state and block_draw_state.managed_fence_id or nil,
      render_range = block_draw_state and block_draw_state.inserted_range or nil,
      extmark_ids = extmark_ids,
      line_map = line_map,
    }

    offset = offset + n_tasks
  end

  M._buffer_state[bufnr] = new_buf_state

  -- ── 6. Apply manual folds for all rendered blocks ──────────────────────────
  -- Each block is folded from its opening fence through the end of its managed
  -- region.  setup_window() is called inside apply_folds for each window.
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
end

--- Refresh a buffer: clear all renders then re-render from scratch.
---
--- @param bufnr     integer
--- @param workspace table?
function M.refresh_buffer(bufnr, workspace)
  M.clear_buffer(bufnr)
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

  -- ── 2. Clear + re-render ───────────────────────────────────────────────────
  -- render_buffer applies folds for ALL blocks if default_folded=true,
  -- or leaves them open if default_folded=false.
  M.clear_buffer(bufnr)
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
end

--- Clear all renders for a buffer and drop orchestrator state.
---
--- @param bufnr integer
function M.clear_buffer(bufnr)
  local draw = require("obsidian-tasks.render.draw")
  draw.clear(bufnr)
  M._buffer_state[bufnr] = nil
  -- Drop foldtext result-count cache for this buffer.
  require("obsidian-tasks.render.foldtext").clear_buffer(bufnr)
  -- Keep reverse index consistent: bufnr no longer has any active render.
  require("obsidian-tasks.index").clear_render_paths(bufnr)
end

return M
