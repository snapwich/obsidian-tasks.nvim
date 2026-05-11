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

--- Return merged opts (falls back to config defaults if setup not yet called).
local function get_opts()
  local ok, ot = pcall(require, "obsidian-tasks")
  if ok and ot.opts and next(ot.opts) then
    return ot.opts
  end
  return require("obsidian-tasks.config").defaults
end

--- Build the os.date format string honouring opts.done_date_tz.
--- When done_date_tz is "utc", prepend "!" so os.date returns UTC.
--- @param opts table
--- @return string
local function date_format(opts)
  local fmt = opts.done_date_format or "%Y-%m-%d"
  if opts.done_date_tz == "utc" then
    return "!" .. fmt
  end
  return fmt
end

--- Apply the done mutation to a single resolved task entry.
---
--- @param resolved table  result of cmd.resolve_task_at()
local function done_one(resolved)
  if resolved.kind == "source" or resolved.kind == "render" then
    local serialize = require("obsidian-tasks.task.serialize")
    local task = resolved.task

    -- Set status.
    task.status_symbol = "x"

    -- Stamp done date only when it hasn't been set (idempotency).
    if task.fields.done == nil then
      local opts = get_opts()
      task.fields.done = os.date(date_format(opts))
      task._origin.done = "emoji"
    end

    local new_line = serialize.serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
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
    done_one(resolved)
  end
end

return M
