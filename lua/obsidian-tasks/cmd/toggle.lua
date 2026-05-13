-- lua/obsidian-tasks/cmd/toggle.lua
-- :ObsidianTask toggle — cycle the status of the task(s) at cursor / in range.
--
-- Uses task/status.next() which respects user-overridden status tables merged
-- in init.setup() via status.merge(opts.statuses).
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   mutates source file directly via managed task_meta resolver.

local M = {}

--- Toggle the task status for a single resolved task entry.
---
--- @param resolved     table   result of cmd.resolve_task_at()
--- @param active_bufnr integer buffer the user acted in (for linger recording)
local function toggle_one(resolved, active_bufnr)
  if resolved.kind == "source" or resolved.kind == "render" then
    local status_mod = require("obsidian-tasks.task.status")
    local serialize = require("obsidian-tasks.task.serialize")
    local task = resolved.task
    task.status_symbol = status_mod.next(task.status_symbol)
    local new_line = serialize.serialize(task)
    local cmd = require("obsidian-tasks.cmd")
    if not cmd.commit_line(resolved, { new_line }) then
      return
    end
    cmd._record_linger(active_bufnr, resolved, task)
  end
end

--- Run the toggle command.
---
--- @param _args  table   extra arguments (unused by toggle)
--- @param range  table   { line1: integer, line2: integer } 1-indexed
function M.run(_args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  local resolved_list = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    log.warn("ObsidianTask toggle: no task found in the specified range")
    return
  end

  for _, resolved in ipairs(resolved_list) do
    toggle_one(resolved, bufnr)
  end
end

return M
