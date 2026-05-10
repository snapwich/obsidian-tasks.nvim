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
-- Design note — why render_lnum beats extmark positions for diff:
--   nvim_buf_set_lines (used to replace a line's content) is internally a
--   char-level delete+insert.  Extmarks at the START of the deleted byte range
--   collapse to the end of the previous line even with right_gravity=false.
--   Because of this, extmark positions are unreliable for PATCH detection
--   after user edits.  Instead, em_map stores render_lnum (the 0-indexed buffer
--   row at draw time).  M.diff looks up task metadata directly by that row and
--   compares the current text hash — no extmark position query needed.

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
---
--- Algorithm (does NOT rely on extmark positions — see design note above):
---   1. Build lnum_to_meta: render_lnum → { eid, meta } from all tracked extmarks.
---   2. For each line in render_range (capped at buffer end):
---      • Line has a known render_lnum entry → read text, compare hash → patch/no-op.
---      • Line has NO render_lnum entry → user-inserted → emit insert.
---   3. Entries in lnum_to_meta whose render_lnum is beyond buf end or
---      outside the scanned range → emit deletion.
---
--- @param bufnr        integer
--- @param render_range table   { first, last } 0-indexed inclusive
--- @return table  { patches, deletions, inserts }
function M.diff(bufnr, render_range)
  local draw = require("obsidian-tasks.render.draw")

  local patches = {}
  local deletions = {}
  local inserts = {}

  local first = render_range[1]
  local last = render_range[2]

  -- Gather all tracked task extmarks from the live render state.
  local all_state = draw.render_state(bufnr)
  if not all_state then
    return { patches = patches, deletions = deletions, inserts = inserts }
  end

  -- Build lnum_to_meta keyed by render_lnum (draw-time 0-indexed row).
  -- render_lnum is stored in em_map by draw.lua and is immune to extmark drift.
  local lnum_to_meta = {} -- render_lnum → { src_path, src_line, src_hash, eid }
  for _, block in pairs(all_state) do
    for eid, meta in pairs(block.em_map or {}) do
      if meta.render_lnum ~= nil then
        lnum_to_meta[meta.render_lnum] = {
          src_path = meta.src_path,
          src_line = meta.src_line,
          src_hash = meta.src_hash,
          eid = eid,
        }
      end
    end
  end

  -- Scan each line in the render range, capped at the actual buffer length.
  local buf_line_count = vim.api.nvim_buf_line_count(bufnr)
  local scan_last = math.min(last, buf_line_count - 1)

  local seen_lnums = {} -- render_lnums visited in the scan loop

  for lnum = first, scan_last do
    local entry = lnum_to_meta[lnum]
    if entry then
      -- Line corresponds to a known task render position.
      seen_lnums[lnum] = true
      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
      local current_text = buf_lines[1] or ""
      local current_hash = vim.fn.sha256(current_text):sub(1, 16)
      if current_hash ~= entry.src_hash then
        log.debug("diff: patch " .. entry.src_path .. ":" .. tostring(entry.src_line))
        patches[#patches + 1] = {
          src_path = entry.src_path,
          src_line = entry.src_line,
          new_text = current_text,
        }
      end
    else
      -- No tracked task at this draw-time position → user-inserted line.
      local buf_lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
      local text = buf_lines[1] or ""
      inserts[#inserts + 1] = {
        after_lnum = lnum,
        new_text = text,
      }
    end
  end

  -- Any tracked render_lnum not seen (buffer shrank or row outside range) → deletion.
  for lnum, entry in pairs(lnum_to_meta) do
    if not seen_lnums[lnum] then
      log.debug("diff: deletion " .. entry.src_path .. ":" .. tostring(entry.src_line))
      deletions[#deletions + 1] = {
        src_path = entry.src_path,
        src_line = entry.src_line,
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
    if lines and line >= 1 and line <= #lines then
      lines[line] = new_text
      vim.fn.writefile(lines, path)
    end
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
    if lines and line >= 1 and line <= #lines then
      table.remove(lines, line)
      vim.fn.writefile(lines, path)
    end
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
