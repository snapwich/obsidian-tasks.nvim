-- lua/obsidian-tasks/util/daily_note.lua
-- Daily-note resolver (plan D5, ADR 0005): the path of the daily note for a
-- date, where a group-top insert writes its task.
--
-- Daily notes belong to obsidian.nvim, not to this plugin, so the path comes
-- from `opts.daily_note`:
--   nil      → default resolver: obsidian.nvim's daily_note_path, only when
--              the `Obsidian` global is set (obsidian.nvim loaded); else nil;
--   function → custom resolver `function(date) -> abs_path|nil`;
--   false    → feature disabled.
-- A nil result means "no daily note": the caller keeps the below-fence
-- fallback.  A resolver error is logged and treated as nil.

local M = {}

local log = require("obsidian-tasks.log")

--- A usable path: a non-empty string, normalized.  Anything else → nil.
--- @param p any
--- @return string|nil
local function as_path(p)
  if type(p) ~= "string" or p == "" then
    return nil
  end
  return vim.fs.normalize(p)
end

--- Default resolver: obsidian.nvim's `daily.daily_note_path(date)`, guarded on
--- the `Obsidian` global (the plugin never requires obsidian.nvim).
--- @param date integer  os.time() value
--- @return string|nil
function M.default_resolver(date)
  if type(Obsidian) ~= "table" then
    return nil
  end
  local ok_req, daily = pcall(require, "obsidian.daily")
  if not ok_req or type(daily) ~= "table" or type(daily.daily_note_path) ~= "function" then
    return nil
  end
  -- daily_note_path returns an obsidian.Path; tostring gives the absolute path.
  local ok, path = pcall(daily.daily_note_path, date)
  if not ok then
    log.debug("daily note: obsidian.nvim daily_note_path failed: " .. tostring(path))
    return nil
  end
  if path == nil then
    return nil
  end
  return as_path(tostring(path))
end

--- Resolve the daily-note path for *date*.
---
--- @param date integer|nil  os.time() value (default: now)
--- @param opts table|nil    plugin opts (default: config.resolved())
--- @return string|nil  absolute path, or nil when there is no daily note
function M.resolve(date, opts)
  opts = opts or require("obsidian-tasks.config").resolved()
  date = date or os.time()

  local resolver = opts.daily_note
  if resolver == false then
    return nil
  end
  if resolver == nil then
    return M.default_resolver(date)
  end

  local ok, path = pcall(resolver, date)
  if not ok then
    log.warn("daily_note resolver failed: " .. tostring(path))
    return nil
  end
  return as_path(path)
end

return M
