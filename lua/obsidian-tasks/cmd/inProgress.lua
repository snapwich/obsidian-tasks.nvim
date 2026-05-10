-- lua/obsidian-tasks/cmd/inProgress.lua
-- :ObsidianTask inProgress — mark the task(s) at cursor / in range as In Progress.
--
-- Sets status_symbol to '/'.  No date stamp.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   edit-through pipeline (F4) handles write-back on :w.

local M = {}

--- Apply the inProgress mutation to a single resolved task entry.
---
--- @param resolved table  result of cmd.resolve_task_at()
local function in_progress_one(resolved)
  if resolved.kind == "source" or resolved.kind == "render" then
    local serialize = require("obsidian-tasks.task.serialize")
    local task = resolved.task
    task.status_symbol = "/"
    local new_line = serialize.serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
  end
end

--- Run the inProgress command.
---
--- @param _args  table  extra arguments (unused)
--- @param range  table  { line1: integer, line2: integer } 1-indexed
function M.run(_args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  local resolved_list = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    log.warn("ObsidianTask inProgress: no task found in the specified range")
    return
  end

  for _, resolved in ipairs(resolved_list) do
    in_progress_one(resolved)
  end
end

return M
