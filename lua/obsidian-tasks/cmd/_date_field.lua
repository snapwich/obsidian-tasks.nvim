-- lua/obsidian-tasks/cmd/_date_field.lua
-- Shared implementation for the date-setting subcommands (due / start / scheduled).
-- Each of cmd/{due,start,scheduled}.lua is one line: `make(<field_key>)`.
--
-- With a DATE arg (ISO YYYY-MM-DD, "today", "tomorrow"):
--   Overwrites task.fields[field_key]; preserves _origin format (emoji vs dataview).
--   Applied to every task in the range; non-task lines are silently skipped.
-- Without arg (cursor only):
--   Appends the field emoji + a space to the cursor task line and enters insert mode.
--   If the cursor is not on a task, emits an error.

local M = {}

--- Build an :ObsidianTask <field> subcommand module for a date field.
---
--- @param field_key string  canonical field key ("due"|"start"|"scheduled")
--- @return table  module exposing run(args, range)
function M.make(field_key)
  local emoji = require("obsidian-tasks.task.fields").by_key[field_key].emoji

  --- Apply the date mutation to a single resolved task entry.
  local function apply_one(resolved, date)
    if resolved.kind == "source" or resolved.kind == "render" then
      local task = resolved.task
      task.fields[field_key] = date
      local new_line = require("obsidian-tasks.task.serialize").serialize(task)
      vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
    end
  end

  --- @param args  table  positional arguments; args[1] is the optional date string
  --- @param range table  { line1: integer, line2: integer } 1-indexed
  local function run(args, range)
    local cmd = require("obsidian-tasks.cmd")
    local log = require("obsidian-tasks.log")
    local bufnr = vim.api.nvim_get_current_buf()

    if args and args[1] then
      local date = require("obsidian-tasks.cmp.date_nl").parse(args[1])
      if not date then
        log.error(
          ("ObsidianTask %s: invalid date '%s' — use YYYY-MM-DD, 'today', or 'tomorrow'"):format(field_key, args[1])
        )
        return
      end

      local resolved_list = cmd.bulk_range(bufnr, range)
      if #resolved_list == 0 then
        log.warn(("ObsidianTask %s: no task found in the specified range"):format(field_key))
        return
      end

      for _, resolved in ipairs(resolved_list) do
        apply_one(resolved, date)
      end
    else
      local resolved = cmd.resolve_task_at(bufnr, range.line1 - 1)
      if not resolved then
        log.error(("ObsidianTask %s: no task at cursor"):format(field_key))
        return
      end

      -- Append the emoji + space, then enter insert mode so the user types the
      -- date.  For render rows, open the source file first — the natural place
      -- for any swap-file prompt to fire — then mutate the now-current buffer.
      local target_bufnr, cursor_lnum
      if resolved.kind == "render" then
        vim.cmd("edit " .. vim.fn.fnameescape(resolved.src_path))
        target_bufnr = vim.api.nvim_get_current_buf()
        cursor_lnum = resolved.src_line
      else
        target_bufnr = resolved.bufnr
        cursor_lnum = range.line1
      end
      local lines = vim.api.nvim_buf_get_lines(target_bufnr, resolved.lnum, resolved.lnum + 1, false)
      local new_line = (lines[1] or "") .. " " .. emoji .. " "
      vim.api.nvim_buf_set_lines(target_bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
      vim.api.nvim_win_set_cursor(0, { cursor_lnum, #new_line })
      vim.cmd("startinsert!")
    end
  end

  return { run = run }
end

return M
