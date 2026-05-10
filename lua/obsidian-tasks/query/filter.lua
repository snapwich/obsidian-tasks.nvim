-- lua/obsidian-tasks/query/filter.lua
-- Predicate factory: AST filter node → function(task, path) → bool
--
-- A "task" here is the table produced by task/parse.lua.
-- A "path" is the absolute path string of the file the task came from.
--
-- Design:
--   * compile_node(node) → predicate   (public: M.compile)
--   * All date comparisons work on ISO YYYY-MM-DD strings.
--   * Run-time errors (e.g. "due before X" on task with no due date) are
--     treated as filter-fail (task excluded), not raised.

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Return today's date as YYYY-MM-DD.
local function today_str()
  return os.date("%Y-%m-%d")
end

--- Return tomorrow's date as YYYY-MM-DD.
local function tomorrow_str()
  local t = os.time() + 86400
  return os.date("%Y-%m-%d", t)
end

--- Resolve a date token (possibly 'today', 'tomorrow') → YYYY-MM-DD string.
--- Returns nil if the token is nil or unrecognizable.
--- @param s string|nil
--- @return string|nil
local function resolve_date(s)
  if not s then
    return nil
  end
  local tok = s:match("^%s*(.-)%s*$"):lower()
  if tok == "today" then
    return today_str()
  end
  if tok == "tomorrow" then
    return tomorrow_str()
  end
  -- Accept YYYY-MM-DD verbatim.
  if tok:match("^%d%d%d%d%-%d%d%-%d%d$") then
    return tok
  end
  return nil
end

--- Compare two YYYY-MM-DD date strings lexicographically.
--- Returns: -1 (a<b), 0 (a==b), 1 (a>b).  nil dates are never valid → error.
--- @param a string
--- @param b string
--- @return integer
local function cmp_date(a, b)
  if a < b then
    return -1
  elseif a > b then
    return 1
  end
  return 0
end

--- Priority level ordering (higher value = higher priority).
--- Matches obsidian-tasks TS: highest > high > medium > low > lowest > none.
local PRIORITY_ORDER = {
  highest = 6,
  high = 5,
  medium = 4,
  low = 3,
  lowest = 2,
  none = 1,
}

--- Return task priority level; nil maps to 'none'.
--- @param task table
--- @return string
local function task_priority(task)
  return task.fields and task.fields.priority or "none"
end

--- Return task status entry (from status.lua) for the task's status_symbol.
--- @param task table
--- @return table|nil
local function task_status_entry(task)
  local status = require("obsidian-tasks.task.status")
  return status.by_symbol[task.status_symbol]
end

-- ── date field accessor ────────────────────────────────────────────────────────

--- Return the value of a date field from the task.
--- Special handling for 'happens': earliest of (due, scheduled, start).
--- @param task table
--- @param field string  canonical field name
--- @return string|nil
local function task_date_field(task, field)
  if field == "happens" then
    local candidates = {}
    for _, key in ipairs({ "due", "scheduled", "start" }) do
      local v = task.fields and task.fields[key]
      if v and v ~= "" then
        candidates[#candidates + 1] = v
      end
    end
    if #candidates == 0 then
      return nil
    end
    table.sort(candidates)
    return candidates[1]
  end
  return task.fields and task.fields[field] or nil
end

-- ── text field accessor ────────────────────────────────────────────────────────

--- Return a string value for a text field from the task or path.
--- @param task table
--- @param path string  absolute file path
--- @param field string  canonical field name
--- @return string|nil
local function task_text_field(task, path, field)
  if field == "path" then
    return path
  end
  if field == "folder" then
    -- Everything up to (but not including) the filename.
    return path:match("^(.*)/[^/]*$") or ""
  end
  if field == "root" then
    -- Top-level subfolder within the vault.
    -- Assumption: absolute path with one directory component as vault root.
    -- /vault/a/b/note.md → "a";  /vault/note.md → "" (file directly in vault).
    local parts = vim.split(path, "/", { plain = true })
    local dirs = {}
    for _, p in ipairs(parts) do
      if p ~= "" then
        dirs[#dirs + 1] = p
      end
    end
    -- dirs[1]=vault, dirs[2]=first subfolder (if present), last=filename
    -- If only vault + filename (no subfolder), return "".
    if #dirs <= 2 then
      return ""
    end
    return dirs[2]
  end
  if field == "filename" then
    return path:match("[^/]+%.%w+$") or path:match("[^/]+$") or ""
  end
  if field == "backlink" then
    -- Filename without extension.
    local fname = path:match("[^/]+%.%w+$") or path:match("[^/]+$") or ""
    return fname:gsub("%.[^.]+$", "")
  end
  if field == "description" then
    return task.description or ""
  end
  if field == "heading" then
    -- Not stored in task for v1; return empty string (filter will miss).
    return ""
  end
  if field == "recurrence" then
    return task.fields and task.fields.recurrence or ""
  end
  if field == "id" then
    return task.fields and task.fields.id or ""
  end
  return ""
end

-- ── leaf predicate factory ─────────────────────────────────────────────────────

--- Build a predicate for a single leaf filter spec.
--- @param filter table  leaf filter spec from parse.lua
--- @return fun(task:table, path:string): boolean
local function make_leaf_pred(filter)
  local ft = filter.type

  -- ── status ─────────────────────────────────────────────────────────────────
  if ft == "done" then
    return function(task)
      local entry = task_status_entry(task)
      return entry ~= nil and entry.type == "DONE"
    end
  end

  if ft == "not_done" then
    return function(task)
      local entry = task_status_entry(task)
      return entry == nil or entry.type ~= "DONE"
    end
  end

  if ft == "status_name" then
    local want = filter.value
    return function(task)
      local entry = task_status_entry(task)
      return entry ~= nil and entry.name == want
    end
  end

  if ft == "status_type" then
    local want = filter.value -- already upper-cased by parser
    return function(task)
      local entry = task_status_entry(task)
      return entry ~= nil and entry.type == want
    end
  end

  -- ── recurring ──────────────────────────────────────────────────────────────
  if ft == "is_recurring" then
    return function(task)
      local rec = task.fields and task.fields.recurrence
      return rec ~= nil and rec ~= ""
    end
  end

  if ft == "is_not_recurring" then
    return function(task)
      local rec = task.fields and task.fields.recurrence
      return rec == nil or rec == ""
    end
  end

  -- ── priority ───────────────────────────────────────────────────────────────
  if ft == "priority" then
    local op = filter.operator
    local want = filter.value
    local want_ord = PRIORITY_ORDER[want] or 0
    return function(task)
      local tp = task_priority(task)
      local tp_ord = PRIORITY_ORDER[tp] or 0
      if op == "is" then
        return tp == want
      elseif op == "above" then
        return tp_ord > want_ord
      elseif op == "below" then
        return tp_ord < want_ord
      elseif op == "not_is" then
        return tp ~= want
      end
      return false
    end
  end

  -- ── date filters ───────────────────────────────────────────────────────────
  if ft == "has_date" then
    local field = filter.field
    return function(task)
      local v = task_date_field(task, field)
      return v ~= nil and v ~= ""
    end
  end

  if ft == "no_date" then
    local field = filter.field
    return function(task)
      local v = task_date_field(task, field)
      return v == nil or v == ""
    end
  end

  if ft == "date_invalid" then
    -- A date is "invalid" if present but doesn't match YYYY-MM-DD.
    local field = filter.field
    return function(task)
      local v = task_date_field(task, field)
      if v == nil or v == "" then
        return false
      end
      return not v:match("^%d%d%d%d%-%d%d%-%d%d$")
    end
  end

  if ft == "date" then
    local field = filter.field
    local op = filter.operator
    local date_val = filter.value
    return function(task)
      local tv = task_date_field(task, field)
      if tv == nil or tv == "" then
        return false -- run-time error treated as filter-fail
      end
      local ref = resolve_date(date_val)
      if ref == nil then
        return false
      end
      local c = cmp_date(tv, ref)
      if op == "before" then
        return c < 0
      elseif op == "after" then
        return c > 0
      elseif op == "on" then
        return c == 0
      elseif op == "in" then
        -- 'in' is treated as 'on' for v1 (NL date range not yet supported).
        return c == 0
      end
      return false
    end
  end

  -- ── text field filters ─────────────────────────────────────────────────────
  if ft == "text" then
    local field = filter.field
    local op = filter.operator
    local val = filter.value
    local val_lower = val:lower()
    return function(task, path)
      local tv = task_text_field(task, path or "", field)
      if tv == nil then
        tv = ""
      end
      local tv_lower = tv:lower()
      if op == "includes" then
        return tv_lower:find(val_lower, 1, true) ~= nil
      elseif op == "does_not_include" then
        return tv_lower:find(val_lower, 1, true) == nil
      elseif op == "regex_matches" then
        -- Strip surrounding /…/ delimiters if present.
        local pat = val:match("^/(.+)/$") or val
        local ok, result = pcall(function()
          return tv:find(pat) ~= nil
        end)
        return ok and result
      elseif op == "regex_does_not_match" then
        local pat = val:match("^/(.+)/$") or val
        local ok, result = pcall(function()
          return tv:find(pat) == nil
        end)
        return ok and result
      end
      return false
    end
  end

  -- ── tag filters ────────────────────────────────────────────────────────────
  if ft == "tag" then
    local op = filter.operator
    local val = filter.value
    return function(task)
      local tags = task.tags or {}
      if op == "has" then
        return #tags > 0
      elseif op == "no" then
        return #tags == 0
      elseif op == "includes" then
        if not val then
          return false
        end
        local val_lower = val:lower()
        for _, tag in ipairs(tags) do
          if tag:lower():find(val_lower, 1, true) then
            return true
          end
        end
        return false
      elseif op == "does_not_include" then
        if not val then
          return true
        end
        local val_lower = val:lower()
        for _, tag in ipairs(tags) do
          if tag:lower():find(val_lower, 1, true) then
            return false
          end
        end
        return true
      end
      return false
    end
  end

  -- ── misc filters ───────────────────────────────────────────────────────────
  if ft == "exclude_sub_items" then
    -- Sub-items have non-empty indent.
    return function(task)
      return task.indent == nil or task.indent == ""
    end
  end

  if ft == "urgency" then
    -- Urgency is not computed in v1; always return false so tasks are excluded.
    return function(_)
      return false
    end
  end

  if ft == "random" then
    -- 'random' in the TS plugin means "no filter" (show all).
    return function(_)
      return true
    end
  end

  -- Unknown filter type — exclude task (safe default).
  return function(_)
    return false
  end
end

-- ── node compiler ──────────────────────────────────────────────────────────────

--- Compile an AST filter node into a predicate function.
--- @param node table  filter node from parse.lua
--- @return fun(task:table, path:string): boolean
local function compile_node(node)
  if not node then
    return function(_)
      return true
    end
  end

  local kind = node.kind

  if kind == "leaf" then
    return make_leaf_pred(node.filter)
  end

  if kind == "and" then
    local left = compile_node(node.children[1])
    local right = compile_node(node.children[2])
    return function(task, path)
      return left(task, path) and right(task, path)
    end
  end

  if kind == "or" then
    local left = compile_node(node.children[1])
    local right = compile_node(node.children[2])
    return function(task, path)
      return left(task, path) or right(task, path)
    end
  end

  if kind == "not" then
    local child = compile_node(node.children[1])
    return function(task, path)
      return not child(task, path)
    end
  end

  -- Unknown node kind — pass-through.
  return function(_)
    return true
  end
end

-- ── public API ─────────────────────────────────────────────────────────────────

--- Compile an AST filter node (from parse.lua) into a predicate.
---
--- The returned predicate accepts `(task, path)` and returns `true` if the
--- task passes the filter.
---
--- @param node table  AST filter node (kind = 'leaf'|'and'|'or'|'not')
--- @return fun(task:table, path:string): boolean
function M.compile(node)
  return compile_node(node)
end

--- Compile a list of filter nodes (conjunction: ALL must match).
---
--- @param nodes table[]  list of AST filter nodes
--- @return fun(task:table, path:string): boolean
function M.compile_all(nodes)
  if not nodes or #nodes == 0 then
    return function(_)
      return true
    end
  end
  local preds = {}
  for _, node in ipairs(nodes) do
    preds[#preds + 1] = compile_node(node)
  end
  return function(task, path)
    for _, pred in ipairs(preds) do
      if not pred(task, path) then
        return false
      end
    end
    return true
  end
end

return M
