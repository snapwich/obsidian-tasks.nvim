-- lua/obsidian-tasks/cmd/tags.lua
-- :ObsidianTask tags add #foo     — idempotently append a tag to task(s).
-- :ObsidianTask tags remove #foo  — silently remove a tag from task(s).
--
-- Both sub-subcommands operate on the cursor line (or visual range for bulk).
-- The tag argument must start with '#' (e.g. "#project", "#area/work").
--
-- add:    adds the tag to task.tags if not already present (idempotent).
--         The tag appears as a trailing tag after all field tokens in the
--         serialized line (it is NOT embedded in task.description).
-- remove: removes the tag from task.tags and also strips it from
--         task.description if it appears there.  Silent no-op if absent.
--
-- Source buffers: edits the buffer line in-place via nvim_buf_set_lines.
-- Render lines:   edit-through pipeline (F4) handles write-back on :w.

local M = {}

-- Tag pattern — kept in sync with task/parse.lua TAG_PAT.
local TAG_PAT = "#[%w%-_/]+"

--- Check whether *tag* exists in *tag_list*.
--- @param tag_list string[]
--- @param tag      string
--- @return boolean
local function has_tag(tag_list, tag)
  for _, t in ipairs(tag_list) do
    if t == tag then
      return true
    end
  end
  return false
end

--- Remove the first occurrence of *tag* from *tag_list* (in-place).
--- @param tag_list string[]
--- @param tag      string
local function remove_tag(tag_list, tag)
  for i, t in ipairs(tag_list) do
    if t == tag then
      table.remove(tag_list, i)
      return
    end
  end
end

--- Strip a specific tag token from a description string.
--- Only the first occurrence is removed (to be safe with duplicates).
--- @param desc string
--- @param tag  string  must be a literal tag like "#foo" (no Lua magic chars except the leading #)
--- @return string
local function strip_tag_from_desc(desc, tag)
  -- Escape magic Lua pattern chars in the tag (only `-` is magic in character
  -- classes; `#` is literal; `/` is literal; letters/digits are literal).
  local escaped = tag:gsub("%-", "%%-"):gsub("/", "%/")
  -- Match the tag optionally surrounded by whitespace.
  -- We only want to remove the tag token itself (not collapse double spaces into
  -- nothing ugly), so we eat one leading space if available.
  local result, count = desc:gsub("%s?" .. escaped, "", 1)
  if count == 0 then
    -- Try without the leading-space prefix (tag at start of string).
    result = desc:gsub(escaped .. "%s?", "", 1)
  end
  return vim.trim(result)
end

--- Apply an add mutation to a single resolved task entry.
---
--- @param resolved table   result of cmd.resolve_task_at()
--- @param tag      string  e.g. "#project"
local function add_one(resolved, tag)
  if resolved.kind == "source" or resolved.kind == "render" then
    local task = resolved.task
    -- Idempotent: only add if not already present.
    if not has_tag(task.tags, tag) then
      task.tags[#task.tags + 1] = tag
    end
    local new_line = require("obsidian-tasks.task.serialize").serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
  end
end

--- Apply a remove mutation to a single resolved task entry.
---
--- @param resolved table   result of cmd.resolve_task_at()
--- @param tag      string  e.g. "#project"
local function remove_one(resolved, tag)
  if resolved.kind == "source" or resolved.kind == "render" then
    local task = resolved.task
    -- Silent no-op if the tag is not present.
    if not has_tag(task.tags, tag) then
      return
    end
    remove_tag(task.tags, tag)
    -- Also strip from description if it was embedded there.
    if task.description and task.description:find(TAG_PAT) then
      task.description = strip_tag_from_desc(task.description, tag)
    end
    local new_line = require("obsidian-tasks.task.serialize").serialize(task)
    vim.api.nvim_buf_set_lines(resolved.bufnr, resolved.lnum, resolved.lnum + 1, false, { new_line })
  end
end

--- Run the tags command.
---
--- @param args  table  { [1]="add"|"remove", [2]="#tag" }
--- @param range table  { line1: integer, line2: integer } 1-indexed
function M.run(args, range)
  local cmd = require("obsidian-tasks.cmd")
  local log = require("obsidian-tasks.log")
  local bufnr = vim.api.nvim_get_current_buf()

  local sub = args and args[1]
  if not sub or sub == "" then
    log.error("ObsidianTask tags: missing sub-subcommand. Usage: tags add #tag | tags remove #tag")
    return
  end

  if sub ~= "add" and sub ~= "remove" then
    log.error("ObsidianTask tags: unknown sub-subcommand '" .. sub .. "'. Use 'add' or 'remove'")
    return
  end

  local tag = args[2]
  if not tag or tag == "" then
    log.error("ObsidianTask tags " .. sub .. ": missing tag argument (e.g. #project)")
    return
  end

  -- Ensure the tag starts with '#'.
  if not tag:find("^#") then
    log.error("ObsidianTask tags " .. sub .. ": tag must start with '#' (got '" .. tag .. "')")
    return
  end

  local resolved_list = cmd.bulk_range(bufnr, range)
  if #resolved_list == 0 then
    log.warn("ObsidianTask tags: no task found in the specified range")
    return
  end

  if sub == "add" then
    for _, resolved in ipairs(resolved_list) do
      add_one(resolved, tag)
    end
  else -- "remove"
    for _, resolved in ipairs(resolved_list) do
      remove_one(resolved, tag)
    end
  end
end

--- Tab-completion for :ObsidianTask tags <sub>.
---
--- @param arg_lead  string
--- @return string[]
function M.complete(arg_lead, _cmdline, _cursorpos)
  local subs = { "add", "remove" }
  local matches = {}
  for _, s in ipairs(subs) do
    if vim.startswith(s, arg_lead) then
      matches[#matches + 1] = s
    end
  end
  return matches
end

return M
