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
--   • Track per-buffer state for F4 (edit-through) in M._buffer_state.

local M = {}

-- ── Per-buffer orchestrator state ─────────────────────────────────────────────
--
--   M._buffer_state[bufnr] = {
--     {
--       block_range  = { fence_start, fence_end },  -- 1-indexed original positions
--       render_range = { first, last } | nil,        -- 0-indexed inserted task lines
--       extmark_ids  = { eid, ... },                 -- task extmark IDs
--       line_map     = { [lnum] = {src_path, src_line, src_hash} },
--     },
--     ...
--   }
--
M._buffer_state = {}

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
--- @param bufnr     integer
--- @param workspace table?  workspace object (required for lazy index init)
function M.render_buffer(bufnr, workspace)
  local draw = require("obsidian-tasks.render.draw")
  local layout_mod = require("obsidian-tasks.render.layout")
  local query_parse = require("obsidian-tasks.query.parse")
  local query_run = require("obsidian-tasks.query.run")
  local index = require("obsidian-tasks.index")

  -- ── 0. Guard: buffer must still be valid ───────────────────────────────────
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- ── 1. Check for tasks blocks ──────────────────────────────────────────────
  if not M.has_tasks_block(bufnr) then
    return
  end

  -- ── 2. Lazy index init ─────────────────────────────────────────────────────
  -- Count index entries by iterating once; if empty, kick off async walk.
  do
    local any = index.tasks_in(nil)()
    if any == nil and workspace then
      -- Index is empty; start an async walk and re-render when done.
      index.refresh_all(workspace, function()
        vim.schedule(function()
          M.render_buffer(bufnr, workspace)
        end)
      end)
      -- Don't block user; return now (renders with empty results on first pass).
      -- Fall through so the user sees "0 results" immediately rather than nothing.
    end
  end

  -- ── 3. Clear previous render ───────────────────────────────────────────────
  -- Clear draw state (extmarks + inserted lines) then drop our own state.
  draw.clear(bufnr)
  M._buffer_state[bufnr] = nil

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

    new_buf_state[#new_buf_state + 1] = {
      block_range = { block.fence_start, block.fence_end },
      render_range = block_draw_state and block_draw_state.inserted_range or nil,
      extmark_ids = extmark_ids,
      line_map = line_map,
    }

    offset = offset + n_tasks
  end

  M._buffer_state[bufnr] = new_buf_state
end

--- Refresh a buffer: clear all renders then re-render from scratch.
---
--- @param bufnr     integer
--- @param workspace table?
function M.refresh_buffer(bufnr, workspace)
  M.clear_buffer(bufnr)
  M.render_buffer(bufnr, workspace)
end

--- Clear all renders for a buffer and drop orchestrator state.
---
--- @param bufnr integer
function M.clear_buffer(bufnr)
  local draw = require("obsidian-tasks.render.draw")
  draw.clear(bufnr)
  M._buffer_state[bufnr] = nil
end

return M
