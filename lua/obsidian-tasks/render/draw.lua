-- lua/obsidian-tasks/render/draw.lua
-- Apply layout lines to a buffer via extmarks + actual text inserts.
--
-- Responsibilities:
--   • Insert real buffer text for task lines.
--   • Attach virt_lines for group_header / footer / error.
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
  group_header = "ObsidianTasksGroupHeader",
  footer = "ObsidianTasksFooter",
  error = "ObsidianTasksError",
  linger = "ObsidianTasksLinger",
  field_invalid = "ObsidianTasksFieldInvalid",
}

local function hl(kind)
  return _HL[kind] or "Normal"
end

--- Resolve the highlight group used to dim lingered task lines.
--- Reads opts.linger_hl_group set via M.setup; falls back to the default name.
--- @return string
local function linger_hl_group()
  local ok, ot = pcall(require, "obsidian-tasks")
  if ok and ot.opts and type(ot.opts.linger_hl_group) == "string" and ot.opts.linger_hl_group ~= "" then
    return ot.opts.linger_hl_group
  end
  return _HL.linger
end

--- Resolve the highlight group used to mark invalid field values.
--- @return string
local function field_invalid_hl_group()
  local ok, ot = pcall(require, "obsidian-tasks")
  if ok and ot.opts and type(ot.opts.field_invalid_hl_group) == "string" and ot.opts.field_invalid_hl_group ~= "" then
    return ot.opts.field_invalid_hl_group
  end
  return _HL.field_invalid
end

-- ── Strip wikilink helper ─────────────────────────────────────────────────────

--- Strip the ' [[<target>]]' wikilink suffix from a rendered task line.
--- Used to recover the pre-wikilink (source-file) task text for managed.task_text.
--- *target* is the exact inner [[...]] text layout appended ('basename' or
--- 'basename|alias'); nil means no suffix was rendered, so *text* is returned
--- unchanged.
--- @param text   string
--- @param target string|nil
--- @return string
local function strip_wikilink(text, target)
  if not target or target == "" then
    return text
  end
  local suffix = " [[" .. target .. "]]"
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
  -- Per-block diagnostic entries built from invalid field-value ranges; the
  -- orchestrator aggregates across all blocks before vim.diagnostic.set.
  local diagnostics = {}
  -- For same-buffer dashboards (the task's source file IS this buffer), the
  -- source-row already carries a diagnostic from refresh_source_diagnostics.
  -- Suppress the duplicate rendered-region diagnostic to keep trouble.nvim /
  -- diagnostic pickers from listing the same task twice.
  local buf_name = vim.api.nvim_buf_get_name(bufnr)

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

  -- ── 1b. EOF sentinel ───────────────────────────────────────────────────────
  -- When the dashboard's last managed row is the buffer's last line, append a
  -- single empty sentinel line.  obsidian.nvim anchors its note footer at the
  -- last buffer line; without the sentinel its footer extmark collides with
  -- ours on the same row and their draw order is non-deterministic.  The
  -- sentinel guarantees obsidian.nvim's anchor lands strictly below ours.
  --
  -- The sentinel is folded into the managed region (stripped on :w, reverted on
  -- edit) and tracked by its own extmark so the demote path can detect the user
  -- typing into it.
  local sentinel_row = nil
  do
    -- The last managed row is the last task when tasks were inserted, otherwise
    -- the closing fence (zero-result dashboards anchor their footer at fence_last).
    local last_managed_row = (#task_texts > 0) and (insert_at + #task_texts - 1) or fence_last
    if last_managed_row == vim.api.nvim_buf_line_count(bufnr) - 1 then
      sentinel_row = last_managed_row + 1
      vim.api.nvim_buf_set_lines(bufnr, sentinel_row, sentinel_row, false, { "" })
    end
  end

  -- ── 2. Anchor managed-region extmarks ─────────────────────────────────────

  -- Fence extmark — marks the opening fence line in the managed namespace.
  local managed_fence_id = managed.add_block(bufnr, fence_first, fence_last)

  -- Region extmark — brackets all inserted task lines (plus the sentinel, when
  -- present, so it is stripped on :w and reverted on edit alongside the tasks).
  local managed_region_id = nil
  if #task_texts > 0 then
    local region_end = sentinel_row or (insert_at + #task_texts - 1)
    managed_region_id = managed.add_region(bufnr, insert_at, region_end)
  elseif sentinel_row ~= nil then
    -- Zero-task EOF dashboard: bracket the lone sentinel so it is stripped on
    -- :w and reverted on edit just like a task row.
    managed_region_id = managed.add_region(bufnr, sentinel_row, sentinel_row)
  end

  -- Sentinel-tracking extmark (draw NS): the demote path resolves the sentinel's
  -- live row via this id in on_lines.  Tracked in all_eids so clear_block tears
  -- it down with the rest of the block's draw-NS extmarks.
  local sentinel_extmark_id = nil
  if sentinel_row ~= nil then
    sentinel_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, NS, sentinel_row, 0, {})
    all_eids[#all_eids + 1] = sentinel_extmark_id
  end

  -- ── 3. Walk layout_lines and attach draw-NS extmarks ─────────────────────
  -- • group_header / error → accumulate; attach above next task (virt_lines_above=true)
  -- • task         → per-line extmark tracked in em_map
  -- • footer       → virt_lines_above=false on last task (or fence if none)

  local em_map = {}
  local task_index = 0 -- tracks how many task lines have been processed
  local pending_virt = {} -- virt_line rows waiting for the next real line
  local last_task_lnum = nil

  for _, ll in ipairs(layout_lines) do
    local kind = ll.kind

    if kind == "group_header" or kind == "error" then
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
      -- Dimmed task lines (either lingered or live-completed) get a full-line
      -- highlight via line_hl_group; other rows get a bare extmark so syntax
      -- highlighting governs them.
      local ext_opts = ll.dim and { line_hl_group = linger_hl_group() } or {}
      local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, task_lnum, 0, ext_opts)
      all_eids[#all_eids + 1] = eid
      em_map[eid] = {
        src_path = ll.src_path,
        src_line = ll.src_line,
        src_hash = ll.src_hash,
        source_text_hash = ll.source_text_hash,
        render_lnum = task_lnum,
      }

      -- Per-range extmarks for fields whose value failed parse validation.
      -- invalid_ranges entries are 1-indexed byte ranges (end-exclusive) into
      -- the serialized text; convert to 0-indexed end-exclusive cols for
      -- nvim_buf_set_extmark.  The wikilink suffix was appended after the
      -- ranges were captured, so existing ranges remain valid; we just need
      -- to clamp to current line length defensively.
      if ll.invalid_ranges then
        local line_len = #ll.text
        local invalid_hl = field_invalid_hl_group()
        -- Suppress diagnostic emission (NOT the visual underline) for tasks
        -- whose source lives in this same buffer — the source row already
        -- carries an equivalent diagnostic from refresh_source_diagnostics.
        local is_same_buffer_source = ll.src_path == buf_name
        for _, range in ipairs(ll.invalid_ranges) do
          local col_start = math.max(0, range[1] - 1)
          local col_end = math.min(line_len, range[2] - 1)
          if col_end > col_start then
            local iid = vim.api.nvim_buf_set_extmark(bufnr, NS, task_lnum, col_start, {
              end_col = col_end,
              hl_group = invalid_hl,
            })
            all_eids[#all_eids + 1] = iid
            if not is_same_buffer_source then
              diagnostics[#diagnostics + 1] = {
                lnum = task_lnum,
                col = col_start,
                end_lnum = task_lnum,
                end_col = col_end,
                message = range[3] or "invalid field value",
                severity = vim.diagnostic.severity.WARN,
                source = "obsidian-tasks",
              }
            end
          end
        end
      end

      -- Per-task extmark in managed namespace (consumed by T6/T7).
      -- rendered_text is the canonical buffer line including wikilink suffix;
      -- the read-only revert / status-edit detector compares against it.
      --
      -- task_text MUST be the verbatim source-file line so the drift check
      -- in cmd.resolve_task_at compares like-for-like.  Prefer ll.source_text
      -- (= task.raw_line, set by layout from the parser); fall back to
      -- strip_wikilink on the rendered text for synthesized tasks that lack
      -- raw_line (e.g. tests, generated rows).
      --
      -- wikilink_target is the inner [[...]] text layout appended ('basename'
      -- or 'basename|alias', nil when no suffix) — render/edit.lua reads it to
      -- strip and re-apply the suffix faithfully during edit-flush.
      managed.add_task(bufnr, task_lnum, {
        source_file = ll.src_path,
        source_row = (ll.src_line or 1) - 1, -- convert 1-indexed → 0-indexed
        task_text = ll.source_text or strip_wikilink(ll.text, ll.wikilink_target),
        rendered_text = ll.text,
        wikilink_target = ll.wikilink_target,
        linger = ll.linger or nil,
      })

      last_task_lnum = task_lnum
      task_index = task_index + 1
    elseif kind == "footer" then
      -- Flush any remaining pending_virt before the footer row.
      -- Anchor ABOVE the row that follows the last managed row (the EOF sentinel,
      -- or the pre-existing next line otherwise) via virt_lines_above=true.  That
      -- row always exists by now — the sentinel block above appended one whenever
      -- the last managed row was the buffer's last line.  Anchoring above the
      -- trailing line (rather than below the last task) (a) keeps the footer
      -- visible when the fence is folded — for zero results the old fence_last
      -- anchor sat INSIDE the fold and vanished when closed — and (b) makes `o`
      -- on the last task open the new line ABOVE the footer (the footer's
      -- right-gravity extmark shifts down with the inserted line).
      local anchor = (last_task_lnum or fence_last) + 1
      local virts = {}
      for _, pv in ipairs(pending_virt) do
        virts[#virts + 1] = pv
      end
      virts[#virts + 1] = { { ll.text, hl("footer") } }
      pending_virt = {}

      local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, anchor, 0, {
        virt_lines = virts,
        virt_lines_above = true,
      })
      all_eids[#all_eids + 1] = eid
    end
  end

  -- Flush any leftover pending_virt (e.g., errors with no following task).
  -- Same above-the-trailing-line anchoring as the footer (see above).
  if #pending_virt > 0 then
    local anchor = (last_task_lnum or fence_last) + 1
    local eid = vim.api.nvim_buf_set_extmark(bufnr, NS, anchor, 0, {
      virt_lines = pending_virt,
      virt_lines_above = true,
    })
    all_eids[#all_eids + 1] = eid
  end

  -- ── 4. Record state ───────────────────────────────────────────────────────

  local inserted_range = nil
  if #task_texts > 0 then
    inserted_range = { insert_at, sentinel_row or (insert_at + #task_texts - 1) }
  elseif sentinel_row ~= nil then
    inserted_range = { sentinel_row, sentinel_row }
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
    sentinel_extmark_id = sentinel_extmark_id,
  }

  -- Attach buffer-local keymap and BufWriteCmd save handler on first draw.
  -- Both are lazy-required to avoid circular dependencies at module load time.
  if is_first_for_buf then
    require("obsidian-tasks.render.keymap").attach(bufnr)
    -- Register the BufWriteCmd handler so :w writes only source content
    -- (queries + prose) and never mutates the buffer.  Buftype is left as
    -- "" so other plugins still treat this as a normal file buffer.
    require("obsidian-tasks.render.save").attach(bufnr)
  end

  -- Return per-block diagnostic entries so the orchestrator can aggregate
  -- across all blocks and vim.diagnostic.set them at once (a single
  -- diagnostic-namespace write per render).
  return { diagnostics = diagnostics }
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

  -- Use LIVE managed-region positions (auto-tracked by Neovim's extmark
  -- subsystem) instead of stale inserted_range values.  When source lines are
  -- inserted above a rendered region between renders, inserted_range points to
  -- the wrong row and would delete the wrong line (e.g. the fence itself).
  -- managed.all_regions() queries current extmark positions, so it always
  -- returns the actual current location of task lines.
  -- Remove from bottom to top (all_regions is sorted ascending; we reverse)
  -- so earlier line numbers stay valid as later lines are removed.
  local live_regions = managed.all_regions(bufnr)
  for i = #live_regions, 1, -1 do
    local first = live_regions[i][1]
    local last = live_regions[i][2]
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

--- Drop all render state for a buffer WITHOUT mutating buffer lines.
--- Used on BufReadPre: the buffer is about to be rewritten from disk so the
--- rendered task lines will be erased by Neovim regardless, but our extmarks
--- and side tables would otherwise persist with stale positions and corrupt the
--- next render (clear() would trust them and delete the wrong rows).
---
--- @param bufnr integer
function M.clear_state(bufnr)
  if not _state[bufnr] then
    return
  end
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
  managed.clear_buffer(bufnr)
  _state[bufnr] = nil
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

--- Demote the sentinel of a single block: stop managing it so user-typed
--- content on the sentinel row persists (not stripped on :w, not reverted).
---
--- Mutates all draw/managed-owned state for the block:
---   • deletes the sentinel-tracking extmark and clears sentinel_extmark_id;
---   • shrinks the managed region to exclude the sentinel row (removing the
---     region entirely when the sentinel was its only row — zero-task dashboard);
---   • shrinks inserted_range likewise (nil when the sentinel was the only row).
---
--- No-op when the block has no sentinel.  The caller (revert.on_lines) is
--- responsible for the revert-side _region_snapshot update and mark_dirty.
---
--- @param bufnr       integer
--- @param fence_first integer  0-indexed opening-fence row identifying the block
function M.demote_sentinel(bufnr, fence_first)
  local block = _state[bufnr] and _state[bufnr][fence_first]
  if not block or not block.sentinel_extmark_id then
    return
  end

  -- Resolve the sentinel's live row before deleting its tracking extmark.
  local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, block.sentinel_extmark_id, {})
  local srow = pos and pos[1] or nil

  pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, block.sentinel_extmark_id)
  block.sentinel_extmark_id = nil

  if srow == nil then
    return
  end

  -- Shrink / remove the managed region so the demoted row is no longer managed.
  if block.managed_region_id then
    local region = managed.region_for_row(bufnr, srow)
    if region then
      local rstart = region.range[1]
      if rstart <= srow - 1 then
        managed.resize_region(bufnr, region.mark_id, rstart, srow - 1)
      else
        -- Sentinel was the region's only row (zero-task dashboard): drop it.
        managed.cleanup_region(bufnr, region.mark_id)
        block.managed_region_id = nil
      end
    end
  end

  -- Shrink inserted_range to match (nil when the sentinel was its only row).
  if block.inserted_range then
    if block.inserted_range[1] <= srow - 1 then
      block.inserted_range[2] = srow - 1
    else
      block.inserted_range = nil
    end
  end
end

--- Demote every block sentinel that the user typed into during an edit.
---
--- For each block with a live sentinel extmark whose row falls in
--- [first_line, check_end) and whose current content is non-empty, releases the
--- sentinel via M.demote_sentinel.  Returns the list of demoted 0-indexed rows
--- so the caller can update its own region snapshot.
---
--- @param bufnr      integer
--- @param first_line integer  0-indexed first changed row of the edit
--- @param check_end  integer  0-indexed exclusive end of the changed range
--- @return integer[]  demoted sentinel rows (0-indexed)
function M.demote_typed_sentinels(bufnr, first_line, check_end)
  local blocks = _state[bufnr]
  if not blocks then
    return {}
  end
  local demoted = {}
  for fence_first, block in pairs(blocks) do
    if block.sentinel_extmark_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, block.sentinel_extmark_id, {})
      local srow = pos and pos[1] or nil
      if srow and srow >= first_line and srow < check_end then
        local cur = vim.api.nvim_buf_get_lines(bufnr, srow, srow + 1, false)[1]
        if cur ~= nil and not cur:match("^%s*$") then
          M.demote_sentinel(bufnr, fence_first)
          demoted[#demoted + 1] = srow
        end
      end
    end
  end
  return demoted
end

return M
