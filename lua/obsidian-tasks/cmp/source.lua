-- lua/obsidian-tasks/cmp/source.lua
-- blink.cmp source for obsidian-tasks field completion.
--
-- NOT auto-registered.  Users must add this to their blink.cmp config:
--
--   sources.providers['obsidian-tasks'] = {
--     module = 'obsidian-tasks.cmp.source',
--     name   = 'ObsidianTasks',
--   }
--
-- Tested against blink.cmp v1.x (2026-05-09 snapshot).
--
-- Source contract (blink.cmp.Source):
--   new(opts, config)               → self
--   enabled(self)                   → bool
--   get_trigger_characters(self)    → string[]
--   get_completions(self, ctx, cb)  → cb({ items, is_incomplete_forward, is_incomplete_backward })
--   resolve(self, item, cb)         → cb(item)   [pass-through]
--
-- We do NOT override `execute`.  blink's default execute inserts the item's
-- `insertText` at the cursor.  Overriding it and not calling the supplied
-- `default_implementation` silently no-ops the accept (menu closes, preview
-- reverts, nothing inserted).

local M = {}
M.__index = M

-- ── Task-line detection ───────────────────────────────────────────────────────

--- Lua pattern that identifies a task-list item.
--- Matches lines like "- [ ] …", "* [x] …", "+ [/] …" (any leading whitespace).
local TASK_LINE_PATTERN = "^%s*[-*+] %[.%]"

--- Return true if *line* looks like a task-list item.
--- @param line string
--- @return boolean
local function is_task_line(line)
  return line:match(TASK_LINE_PATTERN) ~= nil
end

-- ── Vault / buffer helpers ────────────────────────────────────────────────────

--- Return true if *bufnr* is a markdown file (name ends with .md).
--- @param bufnr integer
--- @return boolean
local function is_md_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("%.md$") ~= nil
end

--- Return true if *path* belongs to any configured obsidian.nvim workspace.
--- Silently returns false when obsidian.nvim is not initialised yet.
--- @param path string  absolute file path
--- @return boolean
local function is_vault_path(path)
  local ok, ws = pcall(function()
    return require("obsidian-tasks.util.obsidian").workspace_for_path(path)
  end)
  return ok and ws ~= nil
end

-- ── Source constructor ────────────────────────────────────────────────────────

--- Create a new source instance.
--- Called by blink.cmp on registration.
--- @param _opts   table                       per-source options (currently unused)
--- @param _config table                       full provider config (currently unused)
--- @return obsidian-tasks.cmp.Source
function M.new(_opts, _config)
  return setmetatable({}, M)
end

-- ── Availability ──────────────────────────────────────────────────────────────

--- Return true iff the current cursor position is eligible for task-field
--- completion.
---
--- Conditions (all must hold):
---   0. opts.blink_cmp.enabled is not false.
---   1. Current buffer is a .md file.
---   2. The file is inside an obsidian.nvim vault.
---   3. The line under the cursor matches the task-list regex  OR
---      is a render-inserted task line (render.draw.is_render_line).
---
--- @return boolean
function M:enabled()
  -- ── 0. Plugin-level blink_cmp opt-out ────────────────────────────────────
  local ok_ot, ot = pcall(require, "obsidian-tasks")
  if ok_ot and ot.opts and ot.opts.blink_cmp and ot.opts.blink_cmp.enabled == false then
    return false
  end

  local bufnr = vim.api.nvim_get_current_buf()

  -- ── 1. Markdown buffer ────────────────────────────────────────────────────
  if not is_md_buffer(bufnr) then
    return false
  end

  -- ── 2. Vault membership ───────────────────────────────────────────────────
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not is_vault_path(path) then
    return false
  end

  -- ── 3a. Check render-inserted task line first ─────────────────────────────
  local cursor = vim.api.nvim_win_get_cursor(0) -- {row, col}, 1-indexed row
  local lnum = cursor[1] - 1 -- convert to 0-indexed

  local ok_draw, draw = pcall(require, "obsidian-tasks.render.draw")
  if ok_draw and draw.is_render_line(bufnr, lnum) then
    return true
  end

  -- ── 3b. Check raw buffer line ─────────────────────────────────────────────
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  local line = lines[1] or ""
  return is_task_line(line)
end

-- ── Trigger characters ────────────────────────────────────────────────────────

--- Characters that should trigger the source.
---   ' '  after status checkbox (e.g. "- [ ] ")
---   ':'  after dataview key    (e.g. "[due:: ")
---   '#'  tag prefix
--- @return string[]
function M:get_trigger_characters()
  return { " ", ":", "#" }
end

-- ── Completions ───────────────────────────────────────────────────────────────

--- Provide completion items.
---
--- Delegates field-icon suggestions to cmp/fields.lua.
--- Per-field value suggestions will be added by cmp/values.lua (T3).
---
--- blink.cmp context shape used here:
---   ctx.line       string   full text of the current line
---   ctx.cursor     {row, col}  1-indexed row, 0-indexed col byte offset
---
--- @param ctx       table    blink.cmp context
--- @param callback  fun(response: table)
function M:get_completions(ctx, callback)
  -- Adapt blink context to the shape expected by sub-modules.
  local adapted = {
    line = ctx.line or "",
    cursor_col = ctx.cursor and ctx.cursor[2] or 0,
  }

  -- Field-icon suggestions (T2): offered when cursor is in description position.
  local items = {}
  local ok_fields, fields_mod = pcall(require, "obsidian-tasks.cmp.fields")
  if ok_fields then
    local field_items = fields_mod.completions(adapted)
    for _, item in ipairs(field_items) do
      items[#items + 1] = item
    end
  end

  -- Per-field value suggestions (T3): offered when cursor is inside a field.
  local ok_values, values_mod = pcall(require, "obsidian-tasks.cmp.values")
  if ok_values then
    local value_items = values_mod.completions(adapted)
    for _, item in ipairs(value_items) do
      items[#items + 1] = item
    end
  end

  callback({
    items = items,
    is_incomplete_forward = false,
    is_incomplete_backward = false,
  })
end

-- ── Resolve pass-through ─────────────────────────────────────────────────────

--- Resolve additional details for a completion item (pass-through).
--- @param item     table
--- @param callback fun(resolved_item: table|nil)
function M:resolve(item, callback)
  callback(item)
end

return M
