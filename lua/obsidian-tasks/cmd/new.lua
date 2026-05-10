-- lua/obsidian-tasks/cmd/new.lua
-- :ObsidianTask new — insert a new task skeleton at the cursor position.
--
-- Inserts "- [ ] " at:
--   • The cursor's current column, when the cursor is at or past the end of
--     the current line (includes empty lines and lines shorter than the cursor).
--   • The end of the current line text, when the cursor is inside existing text
--     (mid-line insertion would break the existing content).
--
-- After inserting, the cursor is positioned at the end of the inserted marker
-- and insert mode is entered so the user can type the task description
-- immediately.  The blink.cmp suggestor (F6) will offer field completions on
-- this line via its is_available() check.

local M = {}

local TASK_MARKER = "- [ ] "

--- Run the new-task command.
---
--- @param _args  table  extra arguments (unused)
--- @param range  table  { line1: integer, line2: integer } 1-indexed
function M.run(_args, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = range.line1 -- 1-indexed
  local lnum = row - 1 -- 0-indexed

  -- Read the current line (guard against out-of-bounds).
  local existing = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  local line = existing[1] or ""

  -- Get cursor column (0-indexed byte offset within the line).
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- Determine where to insert "- [ ] ":
  --   • at cursor column when cursor is at or past the end of the line,
  --   • at the end of the line when the cursor is inside existing text.
  local insert_pos = (col >= #line) and col or #line

  -- Pad with spaces when the cursor column is beyond the existing line length.
  local prefix = line:sub(1, insert_pos)
  if #prefix < insert_pos then
    prefix = prefix .. string.rep(" ", insert_pos - #prefix)
  end

  local suffix = line:sub(insert_pos + 1)
  local new_line = prefix .. TASK_MARKER .. suffix

  vim.api.nvim_buf_set_lines(bufnr, lnum, lnum + 1, false, { new_line })

  -- Position cursor just after the task marker and enter insert mode.
  local cursor_col = insert_pos + #TASK_MARKER
  vim.api.nvim_win_set_cursor(0, { row, cursor_col })
  vim.cmd("startinsert!")
end

return M
