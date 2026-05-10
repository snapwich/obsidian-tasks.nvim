-- lua/obsidian-tasks/render/keymap.lua
-- Buffer-local <CR> and gf mappings for render buffers.
--
-- M.attach(bufnr): install buffer-local normal-mode mappings for <CR> and gf.
--   • On a render task line: jump to source file at recorded line, with
--     stale-jump fallback: if the recorded line's hash no longer matches,
--     the source file is scanned for the task and the cursor lands on the
--     moved position.  When no match exists at all the recorded line is used
--     and log.info is emitted to inform the user.
--   • On a non-render line: fall through to obsidian.actions.smart_action().
-- M.detach(bufnr): remove the buffer-local mappings.
--
-- attach is called from render/draw.draw on first draw for a buffer;
-- detach is called from render/draw.clear (full-buffer clear only).
--
-- draw is lazy-required inside the handler to avoid a circular dependency:
--   draw.lua → keymap.lua (attach/detach)
--   keymap.lua handler → draw.lua (is_render_line)

local M = {}

--- Read all lines from a source file.
--- Prefers a loaded buffer (avoids reading a stale disk copy) and falls back
--- to readfile when the file is not open.
--- @param  src_path string
--- @return table|nil  1-indexed list of line strings, or nil on failure
local function read_source_lines(src_path)
  local src_bufnr = vim.fn.bufnr(src_path, false)
  if src_bufnr > -1 then
    return vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
  end
  local result = vim.fn.readfile(src_path)
  if type(result) == "table" then
    return result
  end
  return nil
end

--- Resolve the 1-indexed jump target line in a source file.
---
--- Algorithm:
---   1. Read all lines from src_path.
---   2. If lines[src_line]'s sha256[:16] matches source_text_hash → return src_line.
---   3. Otherwise scan every line for a hash match → return first match.
---   4. If no match found → emit log.info and return src_line.
---
--- source_text_hash must be the hash of the task text BEFORE any wikilink was
--- appended (i.e. matching the raw source-file text).  This is layout.lua's
--- source_text_hash field, NOT src_hash (which includes the wikilink suffix
--- when backlinks are visible and would never match a source-file line).
---
--- @param src_path          string
--- @param src_line          integer  1-indexed recorded line
--- @param source_text_hash  string   sha256[:16] of the pre-wikilink task text
--- @return integer  1-indexed jump target
local function resolve_jump_line(src_path, src_line, source_text_hash)
  local lines = read_source_lines(src_path)
  if type(lines) ~= "table" or not source_text_hash then
    return src_line
  end

  -- Fast path: recorded line still has the right content.
  local recorded_text = lines[src_line]
  if recorded_text and vim.fn.sha256(recorded_text):sub(1, 16) == source_text_hash then
    return src_line
  end

  -- Stale: scan the whole file for a line whose hash matches.
  for i, text in ipairs(lines) do
    if vim.fn.sha256(text):sub(1, 16) == source_text_hash then
      return i
    end
  end

  -- No match: task may have been deleted; fall back and inform the user.
  require("obsidian-tasks.log").info("task may have moved — recorded line " .. tostring(src_line))
  return src_line
end

--- Build the <CR>/<gf> handler closed over *bufnr*.
--- @param bufnr integer
--- @return fun()
local function make_handler(bufnr)
  return function()
    -- Lazy-require draw to avoid circular dependency at module load time.
    local draw = require("obsidian-tasks.render.draw")

    -- nvim_win_get_cursor returns {row, col} with row 1-indexed.
    -- draw.is_render_line uses 0-indexed row.
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lnum = cursor[1] - 1

    local meta = draw.is_render_line(bufnr, lnum)
    if meta and meta.src_path then
      -- Resolve the actual jump line via hash-match fallback.
      -- source_text_hash is the hash of the pre-wikilink task text and matches
      -- raw source-file lines; src_hash includes the wikilink suffix and is
      -- only meaningful for rendered buffer lines (used by edit.lua diff).
      local jump_line = resolve_jump_line(meta.src_path, meta.src_line, meta.source_text_hash)
      -- Jump to source.  Use :edit (not :e!) to preserve unsaved changes in
      -- the destination buffer if it is already loaded.
      vim.cmd("edit " .. vim.fn.fnameescape(meta.src_path))
      -- src_line is 1-indexed (ripgrep line_number convention).
      vim.api.nvim_win_set_cursor(0, { jump_line, 0 })
    else
      -- Fall through: delegate to obsidian.actions.smart_action().
      local ok, actions = pcall(require, "obsidian.actions")
      if ok and type(actions.smart_action) == "function" then
        local result = actions.smart_action()
        if type(result) == "string" then
          local keys = vim.api.nvim_replace_termcodes(result, true, false, true)
          vim.api.nvim_feedkeys(keys, "n", false)
        end
      end
    end
  end
end

--- Attach buffer-local <CR> and gf mappings to *bufnr*.
--- Safe to call multiple times (idempotent: last definition wins).
--- @param bufnr integer
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local handler = make_handler(bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true,
    desc = "obsidian-tasks: jump to source or smart action",
  }
  vim.keymap.set("n", "<CR>", handler, opts)
  vim.keymap.set("n", "gf", handler, opts)
end

--- Detach buffer-local <CR> and gf mappings from *bufnr*.
--- Safe to call when no mappings exist (no-op).
--- @param bufnr integer
function M.detach(bufnr)
  pcall(vim.keymap.del, "n", "<CR>", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "gf", { buffer = bufnr })
end

return M
