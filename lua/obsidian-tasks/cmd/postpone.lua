-- lua/obsidian-tasks/cmd/postpone.lua
-- :ObsidianTask postpone [N] — bump the task's primary date by N days.
--
-- Priority of fields to bump (matches upstream Postponer):
--   due > scheduled > start
-- The first one set is the one that moves; the others stay where they were.
-- Default N is 1.  Negative N pulls the date earlier ("unpostpone").

local M = {}

--- Compute a new ISO date from `iso` plus `n_days`.
--- Uses calendar arithmetic to survive month/year rollovers.
--- @param iso     string  YYYY-MM-DD
--- @param n_days  integer
--- @return string|nil  new YYYY-MM-DD, or nil on parse failure
local function shift_date(iso, n_days)
  local y, mo, d = iso:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  local t = os.time({ year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 })
  if not t then
    return nil
  end
  t = t + n_days * 86400
  return os.date("%Y-%m-%d", t) --[[@as string]]
end

--- Run :ObsidianTask postpone.
--- @param args  table  fargs after the subcmd name
--- @param range table  { line1, line2 } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local serialize = require("obsidian-tasks.task.serialize")
  local bufnr = vim.api.nvim_get_current_buf()

  local n_days = 1
  if args and args[1] then
    local parsed = tonumber(args[1])
    if not parsed then
      log.error("ObsidianTask postpone: argument must be an integer number of days, got '" .. args[1] .. "'")
      return
    end
    n_days = parsed
  end

  local resolved_list, explained = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    -- A known non-task row already emitted the specific "not a task" notice;
    -- skip the redundant generic warning (§11).
    if not explained then
      log.warn("ObsidianTask postpone: no task found in the specified range")
    end
    return
  end

  for _, resolved in ipairs(resolved_list) do
    if resolved.kind == "source" or resolved.kind == "render" then
      local task = resolved.task
      local target_field
      for _, field in ipairs({ "due", "scheduled", "start" }) do
        if task.fields[field] and task.fields[field] ~= "" then
          target_field = field
          break
        end
      end
      if target_field then
        local new_date = shift_date(task.fields[target_field], n_days)
        if new_date then
          task.fields[target_field] = new_date
          local new_line = serialize.serialize(task)
          cmd.commit_line(resolved, { new_line })
        else
          log.warn("ObsidianTask postpone: task date is not in YYYY-MM-DD format, skipped")
        end
      else
        log.info("ObsidianTask postpone: task has no date to postpone")
      end
    end
  end
end

return M
