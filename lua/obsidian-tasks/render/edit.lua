-- lua/obsidian-tasks/render/edit.lua
-- Diff render lines against extmark snapshot; patch source files.
--
-- Responsibilities:
--   • M.diff    — classify lines in render_range as patched / deleted / inserted.
--   • M.apply_patch     — write a changed task line back to its source file.
--   • M.apply_deletion  — remove a deleted task line from its source file.
--   • M.apply_insert    — stub forwarded to F4 T3 (render/newline.lua).
--
-- Source-file writes prefer an open buffer so user undo history is preserved.
-- Disk writes (readfile/writefile) are used only when the file is not loaded.
--
-- Design note — two-phase diff algorithm:
--
--   nvim_buf_set_lines is internally a char-level delete+insert.  For CONTENT
--   replacements (editing a task's text) the extmark drifts to an adjacent row.
--   For LINE insertions/deletions, extmarks track correctly with right_gravity=true.
--
--   Phase 1 — "strong claim":
--     For each tracked extmark, query its live position via get_extmark_by_id.
--     If the current row is within render_range AND the hash at that row matches
--     the stored src_hash → the task is there unchanged.  Claim that row.
--
--   Phase 2 — "weak claim":
--     Tasks without a strong claim fall back to their draw-time render_lnum.
--     If render_lnum is within render_range and not already claimed → use it.
--     Hash mismatch → emit patch.  Row still claimed (prevents spurious insert).
--
--   Deletions:  tasks with no valid claim (render_lnum out of range or stolen
--               by another task's strong claim after a row shift).
--
--   Inserts:    rows in render_range not claimed by any task.
--
-- This two-phase approach correctly handles:
--   • in-place content edit   (extmark drifts → weak claim detects text change)
--   • insert above a task     (extmark tracks new row → strong claim, old row
--                              is unclaimed → insert)
--   • delete non-last task    (surviving task's extmark at the deleted row →
--                              strong claim; deleted task has no valid claim →
--                              deletion)

local M = {}

local log = require("obsidian-tasks.log")

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Resolve a buffer number for a file path without loading it.
--- @param path string
--- @return integer  bufnr, or -1 if not loaded
local function resolve_buf(path)
  return vim.fn.bufnr(path, false)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Diff render lines in render_range against the draw-time snapshot.
--- See the module design note for the two-phase algorithm details.
---
--- @param bufnr        integer
--- @param render_range table   { first, last } 0-indexed inclusive
--- @param block_em_map table?  optional: em_map for this block only (eid → meta).
---                             When provided, only this block's extmarks are
---                             considered; this prevents spurious deletions of
---                             tasks that belong to other rendered blocks in the
---                             same buffer.  Callers handling multi-block buffers
---                             MUST supply this.  When nil the function falls
---                             back to gathering extmarks from all blocks (safe
---                             only when the buffer has exactly one block).
--- @return table  { patches, deletions, inserts }
function M.diff(bufnr, render_range, block_em_map)
  local NS = require("obsidian-tasks.util.extmark").NS

  local patches = {}
  local deletions = {}
  local inserts = {}

  local first = render_range[1]
  local last = render_range[2]

  -- Build the tracked extmark table.
  -- When block_em_map is supplied, use it directly (multi-block safe).
  -- Otherwise fall back to gathering from the full draw state (single-block path).
  local tracked = {} -- eid → { src_path, src_line, src_hash, render_lnum }
  if block_em_map then
    for eid, meta in pairs(block_em_map) do
      tracked[eid] = meta
    end
  else
    local draw = require("obsidian-tasks.render.draw")
    local all_state = draw.render_state(bufnr)
    if not all_state then
      return { patches = patches, deletions = deletions, inserts = inserts }
    end
    for _, block in pairs(all_state) do
      for eid, meta in pairs(block.em_map or {}) do
        tracked[eid] = meta
      end
    end
  end

  -- Snapshot text + hashes for every line in render_range (capped at buffer end).
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local scan_last = math.min(last, buf_line_count - 1)

  local range_texts = {} -- lnum → current text
  local range_hashes = {} -- lnum → sha256[:16]
  for lnum = first, scan_last do
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
    range_texts[lnum] = buf_lines[1] or ""
    range_hashes[lnum] = vim.fn.sha256(range_texts[lnum]):sub(1, 16)
  end

  -- Phase 1 — strong claims: extmark's live row is in range AND hash matches.
  -- Each row can be claimed at most once.
  local claimed_lnums = {} -- lnum → true
  local eid_task_row = {} -- eid → resolved row

  for eid, meta in pairs(tracked) do
    local pos = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, eid, {})
    local current_row = (pos and #pos >= 2) and pos[1] or nil
    if
      current_row ~= nil
      and current_row >= first
      and current_row <= scan_last
      and not claimed_lnums[current_row]
      and range_hashes[current_row] == meta.src_hash
    then
      eid_task_row[eid] = current_row
      claimed_lnums[current_row] = true
    end
  end

  -- Phase 2 — weak claims: fall back to draw-time render_lnum for tasks that
  -- did not receive a strong claim.
  for eid, meta in pairs(tracked) do
    if not eid_task_row[eid] then
      if
        meta.render_lnum ~= nil
        and meta.render_lnum >= first
        and meta.render_lnum <= scan_last
        and not claimed_lnums[meta.render_lnum]
      then
        -- Weak claim: extmark drifted (e.g., in-place content edit) but the
        -- draw-time row is still available and unclaimed.
        eid_task_row[eid] = meta.render_lnum
        claimed_lnums[meta.render_lnum] = true
      else
        -- No valid claim: task was deleted or its row was taken by another task.
        log.debug("diff: deletion " .. meta.src_path .. ":" .. tostring(meta.src_line))
        deletions[#deletions + 1] = {
          src_path = meta.src_path,
          src_line = meta.src_line,
        }
      end
    end
  end

  -- Emit patches for resolved tasks whose content changed.
  for eid, task_row in pairs(eid_task_row) do
    local meta = tracked[eid]
    if range_hashes[task_row] ~= meta.src_hash then
      log.debug("diff: patch " .. meta.src_path .. ":" .. tostring(meta.src_line))
      patches[#patches + 1] = {
        src_path = meta.src_path,
        src_line = meta.src_line,
        new_text = range_texts[task_row],
      }
    end
  end

  -- Unclaimed rows in render_range → user-inserted lines.
  for lnum = first, scan_last do
    if not claimed_lnums[lnum] then
      inserts[#inserts + 1] = {
        after_lnum = lnum,
        new_text = range_texts[lnum],
      }
    end
  end

  return { patches = patches, deletions = deletions, inserts = inserts }
end

--- Apply a patch to a source file (open-buffer preferred, disk fallback).
--- Uses nvim_buf_set_lines when the file is loaded to preserve undo history.
---
--- @param patch table  { src_path, src_line, new_text }
function M.apply_patch(patch)
  local path = patch.src_path
  local line = patch.src_line -- 1-indexed in source file
  local new_text = patch.new_text

  log.debug("apply_patch: " .. path .. ":" .. tostring(line))

  local bufnr = resolve_buf(path)
  if bufnr > -1 then
    -- Loaded buffer: use nvim API to preserve undo history.
    vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, { new_text })
  else
    -- Disk fallback: read → replace → write.
    local lines = vim.fn.readfile(path)
    if type(lines) ~= "table" or line < 1 or line > #lines then
      log.error("apply_patch: cannot write " .. path .. ":" .. tostring(line))
      return
    end
    lines[line] = new_text
    vim.fn.writefile(lines, path)
  end
end

--- Apply a deletion to a source file (open-buffer preferred, disk fallback).
---
--- @param deletion table  { src_path, src_line }
function M.apply_deletion(deletion)
  local path = deletion.src_path
  local line = deletion.src_line -- 1-indexed in source file

  log.debug("apply_deletion: " .. path .. ":" .. tostring(line))

  local bufnr = resolve_buf(path)
  if bufnr > -1 then
    -- Loaded buffer: remove the line, preserving undo history.
    vim.api.nvim_buf_set_lines(bufnr, line - 1, line, false, {})
  else
    -- Disk fallback: read → remove → write.
    local lines = vim.fn.readfile(path)
    if type(lines) ~= "table" or line < 1 or line > #lines then
      log.error("apply_deletion: cannot delete line " .. tostring(line) .. " from " .. path)
      return
    end
    table.remove(lines, line)
    vim.fn.writefile(lines, path)
  end
end

--- Apply a user-inserted render line.
--- Resolution logic (nearest-sibling source file, capture_file fallback) lives
--- in render/newline.lua (F4 T3 — ot-wjee).  This stub exists so the diff
--- caller can forward inserts without knowing the resolution module.
---
--- @param insert table  { after_lnum, new_text }
function M.apply_insert(insert)
  -- Forwarded to F4 T3: render/newline.lua (ot-wjee).
  _ = insert
end

return M
