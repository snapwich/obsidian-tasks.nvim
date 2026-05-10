-- lua/obsidian-tasks/cmd/priority.lua
-- :ObsidianTask priority [LEVEL] — set or clear the priority field on task(s).
--
-- LEVEL must be one of: highest | high | medium | low | lowest | none.
--   highest → 🔺
--   high    → ⏫
--   medium  → 🔼
--   low     → 🔽
--   lowest  → ⏬
--   none    → removes the priority field (no-op if absent)
--
-- With LEVEL arg: applied to every task in the range; non-task lines skipped.
-- Without arg:    same as calling with the current priority displayed, which
--                 is a no-op for UX consistency; in practice the user should
--                 supply a level.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   edit-through pipeline (F4) handles write-back on :w.

local M = {}

local VALID_LEVELS = { "highest", "high", "medium", "low", "lowest", "none" }

local VALID_LEVELS_SET = {}
for _, v in ipairs(VALID_LEVELS) do
  VALID_LEVELS_SET[v] = true
end

--- Apply the priority mutation to a single resolved task entry.
---
--- @param resolved table   result of cmd.resolve_task_at()
--- @param level    string  one of the VALID_LEVELS values
local function priority_one(resolved, level)
  if resolved.kind == "source" or resolved.kind == "render" then
    local task = resolved.task
    if level == "none" then
      task.fields.priority = nil
      task._origin.priority = nil
    else
      task.fields.priority = level
      -- Preserve origin if the field already existed; default to emoji for new fields.
      if not task._origin.priority then
        task._origin.priority = "emoji"
      end
    end
    local new_line = require("obsidian-tasks.task.serialize").serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
  end
end

--- Run the priority command.
---
--- @param args  table  positional args; args[1] is the optional level string
--- @param range table  { line1: integer, line2: integer } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  local level = args and args[1]
  if not level or level == "" then
    log.error("ObsidianTask priority: missing level. Valid: " .. table.concat(VALID_LEVELS, " "))
    return
  end

  if not VALID_LEVELS_SET[level] then
    log.error("ObsidianTask priority: invalid level '" .. level .. "'. Valid: " .. table.concat(VALID_LEVELS, " "))
    return
  end

  local resolved_list = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    log.warn("ObsidianTask priority: no task found in the specified range")
    return
  end

  for _, resolved in ipairs(resolved_list) do
    priority_one(resolved, level)
  end
end

--- Tab-completion for :ObsidianTask priority <level>.
---
--- @param arg_lead  string
--- @return string[]
function M.complete(arg_lead, _cmdline, _cursorpos)
  local matches = {}
  for _, level in ipairs(VALID_LEVELS) do
    if vim.startswith(level, arg_lead) then
      matches[#matches + 1] = level
    end
  end
  return matches
end

return M
