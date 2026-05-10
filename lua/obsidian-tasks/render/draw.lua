-- lua/obsidian-tasks/render/draw.lua
-- Apply layout lines to a buffer via extmarks + actual text inserts.
--
-- Responsibilities:
--   • Insert real buffer text for task lines.
--   • Attach virt_lines for label / group_header / footer / error.
--   • Wire managed-region extmarks (fence, region, per-task).
--   • Maintain a Lua-side em_map (draw NS) for is_render_line / keymap jump.
--   • Expose clear / is_render_line / render_state for orchestrator + keymap.
--
-- Multi-block support:
--   Each (bufnr, fence_first) pair has independent state.  Drawing a block
--   only clears that specific block, not other blocks in the same buffer.
--   M.clear(bufnr) clears ALL blocks for a buffer.

local M = {}

local extmark_util = require("obsidian-tasks.util.extmark")
local managed = require("obsidian-tasks.render.managed")
local NS = extmark_util.NS

-- ── Side tables ──────────────────────────────────────────────────────────────
-- Per-buffer, per-block render state:
--   _state[bufnr] = {
--     [fence_first] = {
--       fence_range      = { first, last },  -- 0-indexed inclusive
--       inserted_range   = { first, last } | nil,
--       em_map           = { [extmark_id] = { src_path, src_line, src_hash,
--                                             source_text_hash, render_lnum } },
--       all_eids         = { eid, ... },     -- ALL draw-NS extmark ids for this block
--       managed_fence_id = integer | nil,    -- managed fence extmark
--       managed_region_id = integer | nil,   -- managed region extmark
--     },
--     ...
--   }

local _state = {}

-- ── Highlight group helpers ───────────────────────────────────────────────────

local _HL = {
  label = "ObsidianTasksLabel",
  group_header = "ObsidianTasksGroupHeader",
  footer = "ObsidianTasksFooter",
  error = "ObsidianTasksError",
}

local function hl(kind)
  return _HL[kind] or "Normal"
end

-- ── Strip wikilink helper ─────────────────────────────────────────────────────

--- Strip the ' [[basename]]' wikilink suffix from a rendered task line.
--- Used to recover the pre-wikilink (source-file) task text for managed.task_text.
--- @param text     string
--- @param src_path string|nil
--- @return string
local function strip_wikilink(text, src_path)
  if not src_path then
    return text
  end
  local basename = vim.fn.fnamemodify(src_path, ":t:r")
  local suffix = " [[" .. basename .. "]]"
  if #text >= #suffix and text:sub(-#suffix) == suffix then
    return text:sub(1, -(#suffix + 1))
  end
  return text
end

-- ── Internal: clear a single block ───────────────────────────────────────────

--- Clear one specific (bufnr, fence_first) block without touching other blocks.
--- Removes its inserted lines, deletes its draw-NS extmarks, and cleans up its
--- managed-namespace extmarks.
---
--- @param bufnr      integer
--- @param fence_first integer  0-indexed first line of the fence
local function clear_block(bufnr, fence_first)
  if not _state[bufnr] or not _state[bufnr][fence_first] then
    return
  end
  local block = _state[bufnr][fence_first]

  -- Remove inserted task lines.
  if block.inserted_range then
    local first = block.inserted_range[1]
    local last = block.inserted_range[2]
    vim.api.nvim_buf_set_lines(bufnr, first, last + 1, false, {})
  end

  -- Delete individual draw-NS extmarks so we don't clobber other blocks.
  for _, eid in ipairs(block.all_eids or {}) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, eid)
  end

  -- Clean up managed-namespace extmarks for this block.
  -- cleanup_region also removes per-task extmarks within the region's range.
  if block.managed_region_id then
    managed.cleanup_region(bufnr, block.managed_region_id)
  end
  if block.managed_fence_id then
    managed.cleanup_block(bufnr, block.managed_fence_id)
  end

  _state[bufnr][fence_first] = nil
  if not next(_state[bufnr]) then
    _state[bufnr] = nil
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Apply layout lines to a buffer.
---
--- Re-entrant per block: if (bufnr, fence_first) already has an active render,
--- only that block is cleared first; other blocks in the buffer are untouched.
---
--- @param bufnr       integer   target buffer
--- @param fence_range table     { first, last }  0-indexed line numbers (inclusive)
--- @param layout_lines table[]  output of render/layout.lua M.layout()
function M.draw(bufnr, fence_range, layout_lines)
  local fence_first = fence_range[1]

  -- Track whether this is the first draw for this buffer so we can attach
  -- keymap bindings once (after state is initialised below).
  local is_first_for_buf = _state[bufnr] == nil

  -- Clear only this specific block (not the whole buffer).
  if _state[bufnr] and _state[bufnr][fence_first] then
    clear_block(bufnr, fence_first)
  end

  local fence_last = fence_range[2]
  local all_eids = {} -- collects ALL draw-NS extmark IDs for this block

  -- ── 1. Collect task texts and insert them as real buffer lines ─────────────

  local task_texts = {}
  for _, ll in ipairs(layout_lines) do
    if ll.kind == "task" then
      task_texts[#task_texts + 1] = ll.text
    end
  end

  -- Insert all tasks right after the closing fence line in a single call.
  local insert_at = fence_last + 1 -- 0-indexed; insert before this position
  if #task_texts > 0 then
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, task_texts)
  end

  -- ── 2. Anchor managed-region extmarks ─────────────────────────────────────

  -- Fence extmark — marks the opening fence line in the managed namespace.
  local managed_fence_id = managed.add_block(bufnr, fence_first, fence_last)

  -- Region extmark — brackets all inserted task lines.
  local managed_region_id = nil
  if #task_texts > 0 then
    managed_region_id = managed.add_region(bufnr, insert_at, insert_at + #task_texts - 1)
  end

  -- ── 3. Walk layout_lines and attach draw-NS extmarks ─────────────────────
  -- • label        → virt_lines_above on fence_first
  -- • group_header / error → accumulate; attach above next task (virt_lines_above=true)
  -- • task         → per-line extmark tracked in em_map
  -- • footer       → virt_lines_above=false on last task (or fence if none)

  local em_map = {}
  local task_index = 0 -- tracks how many task lines have been processed
  local pending_virt = {} -- virt_line rows waiting for the next real line
  local last_task_lnum = nil

  for _, ll in ipairs(layout_lines) do
    local kind = ll.kind

    if kind == "label" then
      -- Render as a virtual line above the opening fence.
      local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, fence_first, 0, {
        virt_lines = { { { ll.text, hl("label") } } },
        virt_lines_above = true,
      })
      all_eids[#all_eids + 1] = eid
    elseif kind == "group_header" or kind == "error" then
      -- Accumulate; will appear above the next task line.
      pending_virt[#pending_virt + 1] = { { ll.text, hl(kind) } }
    elseif kind == "task" then
      local task_lnum = insert_at + task_index

      -- Flush pending virt lines above this task.
      if #pending_virt > 0 then
        local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, task_lnum, 0, {
          virt_lines = pending_virt,
          virt_lines_above = true,
        })
        all_eids[#all_eids + 1] = eid
        pending_virt = {}
      end

      -- Per-line task extmark (draw NS) — id stored in em_map for keymap lookup.
      local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, task_lnum, 0, {})
      all_eids[#all_eids + 1] = eid
      em_map[eid] = {
        src_path = ll.src_path,
        src_line = ll.src_line,
        src_hash = ll.src_hash,
        source_text_hash = ll.source_text_hash,
        render_lnum = task_lnum,
      }

      -- Per-task extmark in managed namespace (consumed by T6/T7).
      managed.add_task(bufnr, task_lnum, {
        source_file = ll.src_path,
        source_row = (ll.src_line or 1) - 1, -- convert 1-indexed → 0-indexed
        task_text = strip_wikilink(ll.text, ll.src_path),
      })

      last_task_lnum = task_lnum
      task_index = task_index + 1
    elseif kind == "footer" then
      -- Flush any remaining pending_virt before the footer row.
      local anchor = last_task_lnum or fence_first
      local virts = {}
      for _, pv in ipairs(pending_virt) do
        virts[#virts + 1] = pv
      end
      virts[#virts + 1] = { { ll.text, hl("footer") } }
      pending_virt = {}

      local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, anchor, 0, {
        virt_lines = virts,
        virt_lines_above = false,
      })
      all_eids[#all_eids + 1] = eid
    end
  end

  -- Flush any leftover pending_virt (e.g., errors with no following task).
  if #pending_virt > 0 then
    local anchor = last_task_lnum or fence_first
    local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, anchor, 0, {
      virt_lines = pending_virt,
      virt_lines_above = false,
    })
    all_eids[#all_eids + 1] = eid
  end

  -- ── 4. Record state ───────────────────────────────────────────────────────

  local inserted_range = nil
  if #task_texts > 0 then
    inserted_range = { insert_at, insert_at + #task_texts - 1 }
  end

  if not _state[bufnr] then
    _state[bufnr] = {}
  end
  _state[bufnr][fence_first] = {
    fence_range = { fence_first, fence_last },
    inserted_range = inserted_range,
    em_map = em_map,
    all_eids = all_eids,
    managed_fence_id = managed_fence_id,
    managed_region_id = managed_region_id,
  }

  -- Attach buffer-local keymap and acwrite/BufWriteCmd handler on first draw.
  -- Both are lazy-required to avoid circular dependencies at module load time.
  if is_first_for_buf then
    require("obsidian-tasks.render.keymap").attach(bufnr)
    -- Set buftype=acwrite and register the BufWriteCmd handler so :w writes
    -- only source content (queries + prose) and never mutates the buffer.
    require("obsidian-tasks.render.save").set_acwrite(bufnr)
  end
end

--- Clear all render extmarks and inserted task lines for a buffer.
--- Clears ALL blocks in the buffer.
--- Safe to call on a buffer that has no active render (no-op).
---
--- @param bufnr integer
function M.clear(bufnr)
  local blocks = _state[bufnr]
  if not blocks then
    return
  end

  -- Collect blocks with inserted lines; sort in reverse order so removing lines
  -- from the end of the buffer first preserves earlier blocks' line numbers.
  local with_lines = {}
  for _, block in pairs(blocks) do
    if block.inserted_range then
      with_lines[#with_lines + 1] = block
    end
  end
  table.sort(with_lines, function(a, b)
    return a.inserted_range[1] > b.inserted_range[1]
  end)
  for _, block in ipairs(with_lines) do
    local first = block.inserted_range[1]
    local last = block.inserted_range[2]
    vim.api.nvim_buf_set_lines(bufnr, first, last + 1, false, {})
  end

  -- Remove all extmarks owned by our draw namespace (fast path for bulk clear).
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)

  -- Clear all managed-namespace state for this buffer.
  managed.clear_buffer(bufnr)

  -- Drop state record.
  _state[bufnr] = nil

  -- Remove buffer-local keymap bindings installed on first draw.
  -- Lazy-require avoids a circular dependency (keymap → draw → keymap).
  require("obsidian-tasks.render.keymap").detach(bufnr)
end

--- Check whether a buffer line is a render-inserted task line.
--- Uses the live extmark positions (auto-tracked by Neovim), so the result
--- stays correct even if lines above have been inserted or deleted.
---
--- @param bufnr integer
--- @param lnum  integer  0-indexed buffer line number
--- @return table|nil  { src_path, src_line, src_hash, source_text_hash } or nil
function M.is_render_line(bufnr, lnum)
  local blocks = _state[bufnr]
  if not blocks then
    return nil
  end

  -- Query all our draw-NS extmarks that sit on this exact line.
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, NS, { lnum, 0 }, { lnum, -1 }, { details = true })
  for _, em in ipairs(ems) do
    local eid = em[1]
    for _, block in pairs(blocks) do
      local entry = block.em_map[eid]
      if entry then
        return {
          src_path = entry.src_path,
          src_line = entry.src_line,
          src_hash = entry.src_hash,
          source_text_hash = entry.source_text_hash,
        }
      end
    end
  end

  return nil
end

--- Return the full render state for a buffer.
--- Returns a map keyed by fence_first (0-indexed).
---   { [fence_first] = { fence_range, inserted_range, em_map, all_eids }, ... }
--- Returns nil if the buffer has no active render.
---
--- @param bufnr integer
--- @return table|nil  per-block state map, or nil
function M.render_state(bufnr)
  return _state[bufnr]
end

return M
