-- lua/obsidian-tasks/cmd/done.lua
-- :ObsidianTask done — mark the task(s) at cursor / in range as Done.
--
-- Sets status_symbol to 'x'.  If task.fields.done is unset, stamps it with
-- today's date via opts.done_date_format (default "%Y-%m-%d", local tz).
--
-- Idempotent: running :done on an already-done task skips the stamp so the
-- original completion date is preserved, and no error is raised.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   mutates source file directly via managed task_meta resolver.

local M = {}

--- Apply the done mutation to a single resolved task entry.
---
--- @param resolved     table   result of cmd.resolve_task_at()
--- @param active_bufnr integer buffer the user acted in (for linger recording)
local function done_one(resolved, active_bufnr)
  if resolved.kind == "source" or resolved.kind == "render" then
    local serialize = require("obsidian-tasks.task.serialize")
    local task = resolved.task

    -- Set status.
    task.status_symbol = "x"

    -- Stamp done date only when it hasn't been set (idempotency).
    if task.fields.done == nil then
      task.fields.done = require("obsidian-tasks.config").completion_date()
      task._origin.done = "emoji"
    end

    local cmd = require("obsidian-tasks.cmd")

    -- 🏁 delete: the task line is removed from its source file instead of
    -- being stamped done.  Matches upstream's onCompletion=Delete behavior.
    -- The linger pass is skipped because there is no longer a task to linger.
    if task.fields.on_completion == "delete" then
      if not cmd.commit_line(resolved, {}) then
        return
      end
      return
    end

    local new_line = serialize.serialize(task)
    if not cmd.commit_line(resolved, { new_line }) then
      return
    end
    cmd._record_linger(active_bufnr, resolved, task)
  end
end

--- Run the done command.
---
--- @param _args  table  extra arguments (unused)
--- @param range  table  { line1: integer, line2: integer } 1-indexed
function M.run(_args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  local resolved_list = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    log.warn("ObsidianTask done: no task found in the specified range")
    return
  end

  for _, resolved in ipairs(resolved_list) do
    done_one(resolved, bufnr)
  end
end

return M
