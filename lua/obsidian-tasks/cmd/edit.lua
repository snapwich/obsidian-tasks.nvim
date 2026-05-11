-- lua/obsidian-tasks/cmd/edit.lua
-- :ObsidianTask edit — jump to the source line of the render task under cursor.
--
-- On a render line: opens the source file and positions cursor at the recorded
--   source row (meta.source_row, 0-indexed → 1-indexed for nvim_win_set_cursor).
-- On a non-render line: emits log.info("not on a render task line").
--
-- This command operates on the single cursor position (range.line1); visual
-- ranges are not meaningful for a jump command.
--
-- Uses managed.task_meta_for_row (T7) — no hash-scan fallback.  For stale
-- positions the user runs <leader>tr to refresh.

local M = {}

--- Run the edit command.
---
--- @param _args  table  extra arguments (unused)
--- @param range  table  { line1: integer, line2: integer } 1-indexed
function M.run(_args, range)
  local managed = require("obsidian-tasks.render.managed")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = range.line1 - 1 -- convert to 0-indexed

  local meta = managed.task_meta_for_row(bufnr, lnum)
  if meta and meta.source_file then
    -- Jump to source file at recorded row.
    -- Use :edit (not :e!) to preserve unsaved changes if the file is already loaded.
    vim.cmd("edit " .. vim.fn.fnameescape(meta.source_file))
    -- source_row is 0-indexed; nvim_win_set_cursor expects 1-indexed.
    vim.api.nvim_win_set_cursor(0, { meta.source_row + 1, 0 })
  else
    log.info("ObsidianTask edit: not on a render task line")
  end
end

return M
