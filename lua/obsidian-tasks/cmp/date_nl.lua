-- lua/obsidian-tasks/cmp/date_nl.lua
-- Stub date parser used by F5 date commands.
-- Full natural-language parsing lands in F6 (blink.cmp suggestor).
--
-- Accepted inputs:
--   "today"       — returns local date as YYYY-MM-DD
--   "tomorrow"    — returns local date + 1 day as YYYY-MM-DD
--   "YYYY-MM-DD"  — ISO date; validated (month 1-12, day 1-31)
--
-- Returns nil for anything else.

local M = {}

--- Parse a date argument string into YYYY-MM-DD.
---
--- @param  arg string|nil  raw argument (may contain surrounding whitespace)
--- @return string|nil      "YYYY-MM-DD" on success, nil on failure
function M.parse(arg)
  if not arg or arg == "" then
    return nil
  end

  local trimmed = vim.trim(arg)
  local lower = trimmed:lower()

  if lower == "today" then
    return os.date("%Y-%m-%d")
  end

  if lower == "tomorrow" then
    return os.date("%Y-%m-%d", os.time() + 86400)
  end

  -- ISO YYYY-MM-DD: digits and hyphens only, validate ranges.
  if trimmed:match("^%d%d%d%d%-%d%d%-%d%d$") then
    local month = tonumber(trimmed:sub(6, 7))
    local day = tonumber(trimmed:sub(9, 10))
    if month >= 1 and month <= 12 and day >= 1 and day <= 31 then
      return trimmed
    end
  end

  return nil
end

return M
