-- lua/obsidian-tasks/cmd/recurrence.lua
-- :ObsidianTask recurrence [PATTERN] — set the recurrence field on a task.
--
-- With PATTERN arg (free-text, e.g. "every week", "every day"):
--   Sets task.fields.recurrence to the raw pattern string (no normalization in v1).
--   Applied to every task in the range; non-task lines are silently skipped.
-- Without arg (cursor only):
--   Appends "🔁 " to the cursor task line and enters insert mode at end.
--   If the cursor is not on a task, emits an error.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   edit-through pipeline (F4) handles write-back on :w.

local M = {}

local FIELD_KEY = "recurrence"
local FIELD_EMOJI = "🔁"

--- Apply the recurrence mutation to a single resolved task entry.
---
--- @param resolved table   result of cmd.resolve_task_at()
--- @param pattern  string  raw recurrence string
local function recurrence_one(resolved, pattern)
  if resolved.kind == "source" or resolved.kind == "render" then
    local task = resolved.task
    task.fields[FIELD_KEY] = pattern
    -- Preserve origin if the field already existed; default to emoji.
    if not task._origin[FIELD_KEY] then
      task._origin[FIELD_KEY] = "emoji"
    end
    local new_line = require("obsidian-tasks.task.serialize").serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
  end
end

--- Run the recurrence command.
---
--- @param args  table  positional args; multi-word args are joined as the pattern
--- @param range table  { line1: integer, line2: integer } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  -- Join all args as the recurrence pattern (supports multi-word patterns like
  -- "every week on Monday").
  local pattern = args and #args > 0 and vim.trim(table.concat(args, " ")) or nil
  if pattern == "" then
    pattern = nil
  end

  if pattern then
    -- ── With arg: set recurrence on all tasks in range ────────────────────────
    local resolved_list = cmd.bulk_range(bufnr, range)
    if #resolved_list == 0 then
      log.warn("ObsidianTask recurrence: no task found in the specified range")
      return
    end

    for _, resolved in ipairs(resolved_list) do
      recurrence_one(resolved, pattern)
    end
  else
    -- ── No arg: append emoji + space, enter insert mode (cursor only) ─────────
    local lnum = range.line1 - 1 -- convert to 0-indexed
    local resolved = cmd.resolve_task_at(bufnr, lnum)
    if not resolved then
      log.error("ObsidianTask recurrence: no task at cursor")
      return
    end

    -- Append "🔁 " to the end of the task line.
    -- For render lines, resolved.bufnr points to the source buffer (T7 resolver),
    -- so we read from and write to the source directly (no wikilink strip needed).
    local target_bufnr = resolved.bufnr
    local target_lnum = resolved.lnum
    local lines = vim.api.nvim_buf_get_lines(target_bufnr, target_lnum, target_lnum + 1, false)
    local base_line = lines[1] or ""
    local new_line = base_line .. " " .. FIELD_EMOJI .. " "
    vim.api.nvim_buf_set_lines(target_bufnr, target_lnum, target_lnum + 1, false, { new_line })

    -- For render lines jump to the source buffer; for source lines stay put.
    if resolved.kind == "render" then
      vim.cmd("edit " .. vim.fn.fnameescape(resolved.src_path))
      vim.api.nvim_win_set_cursor(0, { resolved.src_line, #new_line })
    else
      vim.api.nvim_win_set_cursor(0, { range.line1, #new_line })
    end
    vim.cmd("startinsert!")
  end
end

return M
