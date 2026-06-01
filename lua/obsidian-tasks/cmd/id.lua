-- lua/obsidian-tasks/cmd/id.lua
-- :ObsidianTask id [<value>]
--
-- With no argument: if the task at cursor has no 🆔, generate a fresh 6-char
-- base36 id, set it on the task, and persist.  If it already has an id, leave
-- it unchanged and log the existing id.
--
-- With an argument: set the id to <value> (overriding any existing).
--
-- The auto-generated id format matches upstream's short-id convention:
-- six characters drawn from [0-9a-z], chosen randomly.  Collisions are
-- statistically unlikely (~2.2 billion ids) but the user can re-run the
-- command to assign a different value if needed.

local M = {}

local CHARSET = "0123456789abcdefghijklmnopqrstuvwxyz"

local function random_id()
  local out = {}
  for _ = 1, 6 do
    local i = math.random(1, #CHARSET)
    out[#out + 1] = CHARSET:sub(i, i)
  end
  return table.concat(out)
end

--- Apply the id mutation to a single resolved task entry.
local function id_one(resolved, explicit_value)
  if resolved.kind ~= "source" and resolved.kind ~= "render" then
    return
  end
  local serialize = require("obsidian-tasks.task.serialize")
  local log = require("obsidian-tasks.log")
  local task = resolved.task

  if explicit_value and explicit_value ~= "" then
    task.fields.id = explicit_value
    task._origin.id = task._origin.id or "emoji"
  elseif task.fields.id and task.fields.id ~= "" then
    log.info("obsidian-tasks: task already has id " .. task.fields.id)
    return
  else
    task.fields.id = random_id()
    task._origin.id = "emoji"
  end

  local new_line = serialize.serialize(task)
  local cmd = require("obsidian-tasks.cmd")
  cmd.commit_line(resolved, { new_line })
end

--- Run :ObsidianTask id.
--- @param args  table   fargs after the subcmd name
--- @param range table   { line1, line2 } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()
  local explicit_value = args and args[1] or nil

  local resolved_list, explained = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    -- A known non-task row already emitted the specific "not a task" notice;
    -- skip the redundant generic warning (§11).
    if not explained then
      log.warn("ObsidianTask id: no task found in the specified range")
    end
    return
  end

  for _, resolved in ipairs(resolved_list) do
    id_one(resolved, explicit_value)
  end
end

return M
