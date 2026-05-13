-- lua/obsidian-tasks/cmd/priority.lua
-- :ObsidianTask priority [LEVEL] — set or clear the priority field on task(s).
--
-- LEVEL must be one of: highest | high | medium | low | lowest | none | cycle.
--   highest → 🔺
--   high    → ⏫
--   medium  → 🔼
--   low     → 🔽
--   lowest  → ⏬
--   none    → removes the priority field (no-op if absent)
--   cycle   → rotate through: none → highest → high → medium → low → lowest → none
--
-- With LEVEL arg: applied to every task in the range; non-task lines skipped.
-- Without arg:    same as calling with the current priority displayed, which
--                 is a no-op for UX consistency; in practice the user should
--                 supply a level.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   resolver (T7) opens source buffer; edits source in-place.

local M = {}

local VALID_LEVELS = { "highest", "high", "medium", "low", "lowest", "none" }

local VALID_LEVELS_SET = {}
for _, v in ipairs(VALID_LEVELS) do
  VALID_LEVELS_SET[v] = true
end

local CYCLE_NEXT = {}
CYCLE_NEXT["highest"] = "high"
CYCLE_NEXT["high"] = "medium"
CYCLE_NEXT["medium"] = "low"
CYCLE_NEXT["low"] = "lowest"
-- "lowest" wraps to nil (none); handled explicitly in next_priority().

--- Return the next priority level in the cycle.
--- @param current string|nil  current priority level name (or nil for none)
--- @return string|nil  next level name (nil means "none")
local function next_priority(current)
  if current == nil then
    -- none → start cycle at highest
    return "highest"
  end
  if current == "lowest" then
    -- lowest → wraps back to none
    return nil
  end
  local n = CYCLE_NEXT[current]
  if n == nil then
    -- Unknown value: treat as none → highest
    return "highest"
  end
  return n
end

--- Apply the priority mutation to a single resolved task entry.
---
--- @param resolved table   result of cmd.resolve_task_at()
--- @param level    string  one of VALID_LEVELS values (NOT "cycle")
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
    require("obsidian-tasks.cmd").commit_line(resolved, { new_line })
  end
end

--- Run the priority command.
---
--- @param args  table  positional args; args[1] is the level string (including "cycle")
--- @param range table  { line1: integer, line2: integer } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  local level = args and args[1]
  if not level or level == "" then
    log.error("ObsidianTask priority: missing level. Valid: " .. table.concat(VALID_LEVELS, " ") .. " cycle")
    return
  end

  if level ~= "cycle" and not VALID_LEVELS_SET[level] then
    log.error(
      "ObsidianTask priority: invalid level '" .. level .. "'. Valid: " .. table.concat(VALID_LEVELS, " ") .. " cycle"
    )
    return
  end

  local resolved_list = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    log.warn("ObsidianTask priority: no task found in the specified range")
    return
  end

  for _, resolved in ipairs(resolved_list) do
    if level == "cycle" then
      local current_priority = resolved.task and resolved.task.fields.priority
      local next_level = next_priority(current_priority)
      priority_one(resolved, next_level or "none")
    else
      priority_one(resolved, level)
    end
  end
end

--- Tab-completion for :ObsidianTask priority <level>.
---
--- @param arg_lead  string
--- @return string[]
function M.complete(arg_lead, _cmdline, _cursorpos)
  local all_levels = {}
  for _, level in ipairs(VALID_LEVELS) do
    all_levels[#all_levels + 1] = level
  end
  all_levels[#all_levels + 1] = "cycle"
  local matches = {}
  for _, level in ipairs(all_levels) do
    if vim.startswith(level, arg_lead) then
      matches[#matches + 1] = level
    end
  end
  return matches
end

-- Export for unit testing.
M._next_priority = next_priority

return M
