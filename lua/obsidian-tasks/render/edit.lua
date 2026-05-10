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

--- Resolve a user-inserted render line to its target source file.
---
--- Resolution heuristic (in priority order):
---   1. Walk UP from after_lnum within the current render block.
---      The first task extmark found ("nearest sibling above") determines the
---      target source file; new_text is inserted after that task's src_line.
---   2. If no sibling exists, fall back to opts.capture_file.
---      The path is resolved to absolute (relative → vault root via
---      util/obsidian.current_workspace().root), parent dirs are created if
---      needed, and new_text is appended.
---   3. If neither an anchor nor a capture_file is configured, emit
---      log.warn and silently drop the line.
---
--- Source-file writes use the same loaded-buffer-preferred / disk-fallback
--- primitives as apply_patch / apply_deletion.
---
--- @param bufnr      integer  render buffer number
--- @param after_lnum integer  0-indexed row of the user-inserted line
--- @param new_text   string   text typed by the user
function M.resolve_insert(bufnr, after_lnum, new_text)
  local draw = require("obsidian-tasks.render.draw")

  -- Find the render block that owns the region containing after_lnum.
  -- Used as a walk boundary so sibling search cannot cross into adjacent blocks.
  local state = draw.render_state(bufnr)
  local block_start = nil
  if state then
    for _, block in pairs(state) do
      if block.inserted_range then
        local r = block.inserted_range
        -- Pick the block whose inserted_range starts closest to (but ≤) after_lnum.
        if r[1] <= after_lnum then
          if block_start == nil or r[1] > block_start then
            block_start = r[1]
          end
        end
      end
    end
  end

  -- Walk UP from (after_lnum - 1) down to block_start.
  -- draw.is_render_line returns metadata only for lines with a task extmark.
  local anchor = nil
  local walk_stop = block_start or 0
  for lnum = after_lnum - 1, walk_stop, -1 do
    local info = draw.is_render_line(bufnr, lnum)
    if info then
      anchor = info
      break
    end
  end

  if anchor then
    -- Insert new_text after anchor.src_line (1-indexed) in the source file.
    -- 0-indexed insertion position = src_line (inserts before 0-indexed row
    -- src_line, which is after 1-indexed row src_line).
    local path = anchor.src_path
    local src_line = anchor.src_line -- 1-indexed

    log.debug("resolve_insert: sibling → " .. path .. ":" .. tostring(src_line))

    local src_bufnr = resolve_buf(path)
    if src_bufnr > -1 then
      -- Loaded buffer: insert before 0-indexed row src_line (= after 1-indexed src_line).
      vim.api.nvim_buf_set_lines(src_bufnr, src_line, src_line, false, { new_text })
    else
      -- Disk fallback.
      local lines = vim.fn.readfile(path)
      if type(lines) ~= "table" then
        log.error("resolve_insert: cannot read " .. path)
        return
      end
      -- table.insert at Lua index src_line + 1 inserts after the 1-indexed src_line.
      table.insert(lines, src_line + 1, new_text)
      vim.fn.writefile(lines, path)
    end
    return
  end

  -- No sibling above: try opts.capture_file.
  local opts_ok, plugin = pcall(require, "obsidian-tasks")
  local capture_file = opts_ok and plugin.opts and plugin.opts.capture_file

  if not capture_file then
    log.warn("dropped a new task — no anchor and no opts.capture_file set")
    return
  end

  -- Resolve relative path against vault root.
  local abs_path
  if capture_file:sub(1, 1) == "/" then
    abs_path = capture_file
  else
    local ws_ok, ws = pcall(function()
      return require("obsidian-tasks.util.obsidian").current_workspace()
    end)
    if ws_ok and ws and ws.root then
      local root = ws.root:gsub("[/\\]+$", "")
      abs_path = root .. "/" .. capture_file
    else
      -- Obsidian not initialised: use path as-is (best-effort).
      abs_path = capture_file
    end
  end

  -- Create parent dirs on first use.
  local parent = vim.fn.fnamemodify(abs_path, ":h")
  vim.fn.mkdir(parent, "p")

  log.debug("resolve_insert: capture_file → " .. abs_path)

  -- Append: prefer loaded buffer, disk fallback.
  local cf_bufnr = resolve_buf(abs_path)
  if cf_bufnr > -1 then
    local line_count = vim.api.nvim_buf_line_count(cf_bufnr)
    vim.api.nvim_buf_set_lines(cf_bufnr, line_count, line_count, false, { new_text })
  else
    if vim.fn.filereadable(abs_path) == 1 then
      local lines = vim.fn.readfile(abs_path)
      if type(lines) ~= "table" then
        lines = {}
      end
      lines[#lines + 1] = new_text
      vim.fn.writefile(lines, abs_path)
    else
      -- File does not exist yet — create it.
      vim.fn.writefile({ new_text }, abs_path)
    end
  end
end

--- Apply a user-inserted render line.
--- Delegates to M.resolve_insert when bufnr is provided.
--- When bufnr is absent (legacy callers), this is a no-op.
---
--- @param insert table    { after_lnum, new_text }
--- @param bufnr  integer? render buffer number (required for resolution)
function M.apply_insert(insert, bufnr)
  if not bufnr then
    return
  end
  M.resolve_insert(bufnr, insert.after_lnum, insert.new_text)
end

return M
