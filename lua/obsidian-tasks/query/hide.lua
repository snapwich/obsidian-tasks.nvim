-- lua/obsidian-tasks/query/hide.lua
-- Maps AST hide list → hide_flags table consumed by the render layout.
--
-- hide_flags is a flat table keyed by canonical flag names.
-- The render layer checks e.g. hide_flags.priority to decide whether to
-- omit that element from the output.

local M = {}

-- Mapping from hide subkey strings (as produced by parse.lua) → canonical flag name.
local HIDE_KEY_MAP = {
  ["priority"] = "priority",
  ["due date"] = "due_date",
  ["scheduled date"] = "scheduled_date",
  ["start date"] = "start_date",
  ["done date"] = "done_date",
  ["created date"] = "created_date",
  ["cancelled date"] = "cancelled_date",
  ["recurrence rule"] = "recurrence_rule",
  ["on completion"] = "on_completion",
  ["tags"] = "tags",
  ["id"] = "id",
  ["depends on"] = "depends_on",
  ["backlinks"] = "backlinks",
  ["task count"] = "task_count",
  -- NOTE: `tree` is NOT a hide flag.  `show tree` / `hide tree` are parsed in
  -- query/parse.lua into ast.tree (a boolean toggle), driving query/tree.lua
  -- assembly — not the field-hiding layout path that consumes these flags.
  ["edit button"] = "edit_button",
  ["postpone button"] = "postpone_button",
}

--- Build a hide_flags table from the AST hide list.
---
--- @param hide_list string[]  list of hide subkey strings from parse.lua
--- @return table<string, boolean>  flag → true when the element should be hidden
function M.make_flags(hide_list)
  local flags = {}
  if not hide_list then
    return flags
  end
  for _, subkey in ipairs(hide_list) do
    local flag = HIDE_KEY_MAP[subkey]
    if flag then
      flags[flag] = true
    end
  end
  return flags
end

return M
