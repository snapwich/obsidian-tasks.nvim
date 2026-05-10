-- lua/obsidian-tasks/cmd/edit.lua
-- :ObsidianTask edit — jump to the source line of the render task under cursor.
--
-- On a render line: opens the source file and positions cursor at the recorded
--   source line (src_line, 1-indexed).
-- On a non-render line: emits log.info("not on a render task line").
--
-- This command operates on the single cursor position (range.line1); visual
-- ranges are not meaningful for a jump command.
--
-- Note: stale-jump resolution (hash-based fallback scan) is intentionally not
-- included here because the hash fields returned by is_render_line have a known
-- mismatch (src_hash contains the wikilink suffix; source_text_hash may not
-- match source lines in all layouts).  The simple src_path + src_line jump is
-- correct for the common case; stale-jump improvements belong in a future task.

local M = {}

--- Run the edit command.
---
--- @param _args  table  extra arguments (unused)
--- @param range  table  { line1: integer, line2: integer } 1-indexed
function M.run(_args, range)
  local draw = require("obsidian-tasks.render.draw")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = range.line1 - 1 -- convert to 0-indexed

  local meta = draw.is_render_line(bufnr, lnum)
  if meta and meta.src_path then
    -- Jump to source file at recorded line.
    -- Use :edit (not :e!) to preserve unsaved changes if the file is already loaded.
    vim.cmd("edit " .. vim.fn.fnameescape(meta.src_path))
    -- src_line is 1-indexed (line-number convention).
    vim.api.nvim_win_set_cursor(0, { meta.src_line, 0 })
  else
    log.info("ObsidianTask edit: not on a render task line")
  end
end

return M
