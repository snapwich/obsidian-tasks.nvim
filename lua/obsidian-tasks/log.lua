-- lua/obsidian-tasks/log.lua
-- Thin vim.notify wrapper with plugin prefix and log-level gating.

local M = {}

local PREFIX = "[obsidian-tasks]"

--- Emit a debug message (only when opts.log_level == 'debug').
--- @param msg string
function M.debug(msg)
  local ok, plugin = pcall(require, "obsidian-tasks")
  if ok and plugin.opts and plugin.opts.log_level == "debug" then
    vim.notify(PREFIX .. " " .. msg, vim.log.levels.DEBUG)
  end
end

--- Emit an info message.
--- @param msg string
function M.info(msg)
  vim.notify(PREFIX .. " " .. msg, vim.log.levels.INFO)
end

--- Emit a warning message.
--- @param msg string
function M.warn(msg)
  vim.notify(PREFIX .. " " .. msg, vim.log.levels.WARN)
end

--- Emit an error message.
--- @param msg string
function M.error(msg)
  vim.notify(PREFIX .. " " .. msg, vim.log.levels.ERROR)
end

return M
