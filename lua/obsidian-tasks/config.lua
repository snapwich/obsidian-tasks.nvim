-- lua/obsidian-tasks/config.lua
-- Opts schema, defaults, validation, and deep-merge.

local M = {}

--- Default configuration values.
M.defaults = {
  global_filter = nil,
  auto_render = true,
  watcher = true,
  watcher_debounce_ms = 300,
  done_date_format = "%Y-%m-%d",
  done_date_tz = "local",
  capture_file = nil,
  statuses = nil,
  hide_query_metadata = false,
  blink_cmp = { enabled = true },
  date_input = {
    natural_language = true,
    suggestions = { "today", "tomorrow", "next monday", "next week", "in 3 days" },
  },
  log_level = "info",
  max_file_bytes = 1048576,
}

--- Type-check a single field.
--- @param key string
--- @param value any
local function check_field(key, value)
  if key == "global_filter" then
    if value ~= nil and type(value) ~= "string" then
      error(("obsidian-tasks: 'global_filter' must be a string or nil, got %s"):format(type(value)), 2)
    end
  elseif key == "auto_render" then
    if type(value) ~= "boolean" then
      error(("obsidian-tasks: 'auto_render' must be a boolean, got %s"):format(type(value)), 2)
    end
  elseif key == "watcher" then
    if type(value) ~= "boolean" then
      error(("obsidian-tasks: 'watcher' must be a boolean, got %s"):format(type(value)), 2)
    end
  elseif key == "watcher_debounce_ms" then
    if type(value) ~= "number" or math.floor(value) ~= value or value <= 0 then
      error(("obsidian-tasks: 'watcher_debounce_ms' must be a positive integer, got %s"):format(tostring(value)), 2)
    end
  elseif key == "done_date_format" then
    -- Accept any string resembling a strftime pattern (contains %)
    if type(value) ~= "string" then
      error(("obsidian-tasks: 'done_date_format' must be a string, got %s"):format(type(value)), 2)
    end
    if not value:match("%%") then
      error(("obsidian-tasks: 'done_date_format' must be a strftime pattern (contain '%%'), got %q"):format(value), 2)
    end
  elseif key == "done_date_tz" then
    if type(value) ~= "string" then
      error(("obsidian-tasks: 'done_date_tz' must be a string, got %s"):format(type(value)), 2)
    end
  elseif key == "capture_file" then
    if value ~= nil and type(value) ~= "string" then
      error(("obsidian-tasks: 'capture_file' must be a string or nil, got %s"):format(type(value)), 2)
    end
  elseif key == "statuses" then
    if value ~= nil and type(value) ~= "table" then
      error(("obsidian-tasks: 'statuses' must be a table or nil, got %s"):format(type(value)), 2)
    end
  elseif key == "hide_query_metadata" then
    if type(value) ~= "boolean" then
      error(("obsidian-tasks: 'hide_query_metadata' must be a boolean, got %s"):format(type(value)), 2)
    end
  elseif key == "blink_cmp" then
    if type(value) ~= "table" then
      error(("obsidian-tasks: 'blink_cmp' must be a table, got %s"):format(type(value)), 2)
    end
  elseif key == "date_input" then
    if type(value) ~= "table" then
      error(("obsidian-tasks: 'date_input' must be a table, got %s"):format(type(value)), 2)
    end
  elseif key == "log_level" then
    if type(value) ~= "string" or (value ~= "debug" and value ~= "info" and value ~= "warn" and value ~= "error") then
      error(
        ("obsidian-tasks: 'log_level' must be one of 'debug','info','warn','error', got %q"):format(tostring(value)),
        2
      )
    end
  elseif key == "max_file_bytes" then
    if type(value) ~= "number" or math.floor(value) ~= value or value <= 0 then
      error(("obsidian-tasks: 'max_file_bytes' must be a positive integer, got %s"):format(tostring(value)), 2)
    end
  end
end

--- All recognized config keys (explicit list so nil-defaulted keys are included).
local KNOWN_KEYS = {
  global_filter = true,
  auto_render = true,
  watcher = true,
  watcher_debounce_ms = true,
  done_date_format = true,
  done_date_tz = true,
  capture_file = true,
  statuses = true,
  hide_query_metadata = true,
  blink_cmp = true,
  date_input = true,
  log_level = true,
  max_file_bytes = true,
}

--- Validate user opts types and return deep-merged result.
--- Unknown keys emit a warning via log.warn (not an error).
--- @param opts table User-supplied opts.
--- @return table Merged opts table.
function M.validate(opts)
  opts = opts or {}

  -- Warn on unknown keys
  local log = require("obsidian-tasks.log")
  for k in pairs(opts) do
    if not KNOWN_KEYS[k] then
      log.warn(("unknown config key: %q"):format(k))
    end
  end

  -- Type-check provided keys
  for k, v in pairs(opts) do
    if KNOWN_KEYS[k] then
      check_field(k, v)
    end
  end

  -- Deep-merge user opts over defaults
  return vim.tbl_deep_extend("force", M.defaults, opts)
end

--- Merge user opts over defaults (alias used by init.lua).
--- @param user_opts table? User-supplied opts.
--- @return table Merged opts table.
function M.merge(user_opts)
  return M.validate(user_opts or {})
end

return M
