-- lua/obsidian-tasks/cmd/_status_field.lua
-- Shared implementation for the status-setting subcommands
-- (toggle / done / cancel / onHold / inProgress).
-- Each of cmd/{toggle,done,cancel,onHold,inProgress}.lua is one line: `make({...})`.
--
-- Source buffers: edits the buffer line in-place via cmd.commit_line.
-- Render lines:   mutates the source file directly via the managed resolver.
--
-- spec fields:
--   name                 string   subcommand name (used in the no-task warning)
--   symbol               string?  fixed status char to set ("x"|"-"|"h"|"/")
--   cycle                boolean? cycle via task.status.next() instead of setting
--                                 a fixed symbol (toggle).  Respects user-merged
--                                 status overrides.
--   date_field           string?  field key stamped with the completion date when
--                                 previously unset ("done"|"cancelled").  Idempotent:
--                                 a re-run preserves the original date.
--   on_completion_delete boolean? when true, a task carrying `🏁 delete` whose new
--                                 status is completed is removed instead of stamped
--                                 (toggle, done).  Matches upstream onCompletion=Delete.
--
-- Exactly one of `symbol` / `cycle` must be set.

local M = {}

--- Build an :ObsidianTask <status> subcommand module.
---
--- @param spec table  see field docs above
--- @return table  module exposing run(args, range)
function M.make(spec)
  --- Apply the status mutation to a single resolved task entry.
  ---
  --- @param resolved     table   result of cmd.resolve_task_at()
  --- @param active_bufnr integer buffer the user acted in (for linger recording)
  local function status_one(resolved, active_bufnr)
    if resolved.kind ~= "source" and resolved.kind ~= "render" then
      return
    end
    local status_mod = require("obsidian-tasks.task.status")
    local serialize = require("obsidian-tasks.task.serialize")
    local cmd = require("obsidian-tasks.cmd")
    local task = resolved.task

    if spec.cycle then
      task.status_symbol = status_mod.next(task.status_symbol)
    else
      task.status_symbol = spec.symbol
    end

    -- Stamp the completion date only when unset, so the original date survives
    -- a re-run (idempotency).
    if spec.date_field and task.fields[spec.date_field] == nil then
      task.fields[spec.date_field] = require("obsidian-tasks.config").completion_date()
      task._origin[spec.date_field] = "emoji"
    end

    -- 🏁 delete: remove the task line instead of stamping it.  The linger pass
    -- is skipped because there is no longer a task to linger.
    if
      spec.on_completion_delete
      and task.fields.on_completion == "delete"
      and status_mod.is_completed(task.status_symbol)
    then
      cmd.commit_line(resolved, {})
      return
    end

    local new_line = serialize.serialize(task)
    if not cmd.commit_line(resolved, { new_line }) then
      return
    end
    cmd._record_linger(active_bufnr, resolved, task)
  end

  --- @param _args table  extra arguments (unused)
  --- @param range table  { line1: integer, line2: integer } 1-indexed
  local function run(_args, range)
    local cmd = require("obsidian-tasks.cmd")
    local log = require("obsidian-tasks.log")
    local bufnr = vim.api.nvim_get_current_buf()

    local resolved_list = cmd.bulk_range(bufnr, range)
    if #resolved_list == 0 then
      log.warn(("ObsidianTask %s: no task found in the specified range"):format(spec.name))
      return
    end

    for _, resolved in ipairs(resolved_list) do
      status_one(resolved, bufnr)
    end
  end

  return { run = run }
end

return M
