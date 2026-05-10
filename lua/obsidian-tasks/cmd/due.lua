-- lua/obsidian-tasks/cmd/due.lua
-- :ObsidianTask due [DATE] — set/overwrite the due date on task(s) at cursor / in range.
--
-- With DATE arg (ISO YYYY-MM-DD, "today", "tomorrow"):
--   Overwrites task.fields.due; preserves _origin format (emoji vs dataview).
--   Applied to every task in the range; non-task lines are silently skipped.
-- Without arg (cursor only):
--   Appends "📅 " to the cursor task line and enters insert mode at end.
--   If the cursor is not on a task, emits an error.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   edit-through pipeline (F4) handles write-back on :w.

local M = {}

local FIELD_KEY = "due"
local FIELD_EMOJI = "📅"

--- Apply the due mutation to a single resolved task entry.
---
--- @param resolved table   result of cmd.resolve_task_at()
--- @param date     string  YYYY-MM-DD
local function due_one(resolved, date)
  if resolved.kind == "source" then
    local task = resolved.task
    -- Overwrite (preserves _origin format when field already existed).
    task.fields[FIELD_KEY] = date
    local new_line = require("obsidian-tasks.task.serialize").serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
  elseif resolved.kind == "render" then
    require("obsidian-tasks.log").warn("ObsidianTask due: render lines are updated via edit-through on :w")
  end
end

--- Run the due command.
---
--- @param args  table  positional arguments; args[1] is the optional date string
--- @param range table  { line1: integer, line2: integer } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  if args and args[1] then
    -- ── With arg: parse date and apply to range ─────────────────────────────
    local date = require("obsidian-tasks.cmp.date_nl").parse(args[1])
    if not date then
      log.error("ObsidianTask due: invalid date '" .. args[1] .. "' — use YYYY-MM-DD, 'today', or 'tomorrow'")
      return
    end

    local resolved_list = cmd.bulk_range(bufnr, range)
    if #resolved_list == 0 then
      log.warn("ObsidianTask due: no task found in the specified range")
      return
    end

    for _, resolved in ipairs(resolved_list) do
      due_one(resolved, date)
    end
  else
    -- ── No arg: append emoji + space, enter insert mode (cursor only) ────────
    local lnum = range.line1 - 1 -- convert to 0-indexed
    local resolved = cmd.resolve_task_at(bufnr, lnum)
    if not resolved then
      log.error("ObsidianTask due: no task at cursor")
      return
    end
    if resolved.kind == "render" then
      log.warn("ObsidianTask due: render lines are updated via edit-through on :w")
      return
    end

    -- Append "📅 " to the end of the task line.
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
    local new_line = lines[1] .. " " .. FIELD_EMOJI .. " "
    vim.api.nvim_buf_set_lines(bufnr, lnum, lnum + 1, false, { new_line })

    -- Position cursor after the appended emoji and enter insert mode.
    vim.api.nvim_win_set_cursor(0, { range.line1, #new_line })
    vim.cmd("startinsert!")
  end
end

return M
