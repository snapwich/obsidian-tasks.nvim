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

local status = require("obsidian-tasks.task.status")

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
--- Matches obsidian-tasks TS Priority enum (Priority.ts):
---   Highest=0 > High=1 > Medium=2 > None=3 > Low=4 > Lowest=5
--- We use inverted (higher value = higher priority) but preserve the
--- relative ordering: `none` sits BETWEEN medium and low, NOT below lowest.
local PRIORITY_ORDER = {
  highest = 6,
  high = 5,
  medium = 4,
  none = 3,
  low = 2,
  lowest = 1,
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
--- @param path string  vault-relative file path (run.lua strips workspace root)
--- @param field string  canonical field name
--- @return string|nil
local function task_text_field(task, path, field)
  if field == "path" then
    return path
  end
  if field == "folder" then
    -- Everything up to (but not including) the filename.  For a vault-root
    -- file like `note.md`, the match fails and we return "".
    return path:match("^(.*)/[^/]*$") or ""
  end
  if field == "root" then
    -- First directory below the vault root.  Vault-relative semantics:
    --   daily/2024-03-15.md → "daily"
    --   daily/sub/note.md   → "daily" (first dir only)
    --   note.md             → ""      (file directly in vault root)
    local parts = vim.split(path, "/", { plain = true })
    local dirs = {}
    for _, p in ipairs(parts) do
      if p ~= "" then
        dirs[#dirs + 1] = p
      end
    end
    if #dirs <= 1 then
      return "" -- only a filename (no directory above it)
    end
    return dirs[1]
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
    -- Nearest ATX heading above the task's source line, recorded by the
    -- indexer (nil when the task sits above any heading).
    return task.heading or ""
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
  -- Upstream parity: `done` matches every status type except those still
  -- "actively pending" (TODO, IN_PROGRESS, ON_HOLD).  CANCELLED, DONE, NON_TASK
  -- and any custom completed-bucket types all match `done`.  `not done` is the
  -- inverse — including the "unknown type" case (treated as pending).
  if ft == "done" then
    return function(task)
      return not status.is_pending(task_status_entry(task))
    end
  end

  if ft == "not_done" then
    return function(task)
      return status.is_pending(task_status_entry(task))
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
    local ref_end = filter.value_end -- two-date range upper-bound, optional
    return function(task)
      local tv = task_date_field(task, field)
      if tv == nil or tv == "" then
        return false -- run-time error treated as filter-fail
      end
      local ref = resolve_date(date_val)
      if ref == nil then
        return false
      end
      -- Two-date range: the upper-bound semantically combines with the
      -- operator.  Map operator + range:
      --   in            → ref <= tv <= ref_end
      --   on            → same as `in` (point-or-range)
      --   before        → tv < ref
      --   after         → tv > ref_end
      --   on_or_before  → tv <= ref_end
      --   on_or_after   → tv >= ref
      if ref_end then
        local lower = cmp_date(tv, ref)
        local upper = cmp_date(tv, ref_end)
        if op == "before" then
          return lower < 0
        elseif op == "after" then
          return upper > 0
        elseif op == "on_or_before" then
          return upper <= 0
        elseif op == "on_or_after" then
          return lower >= 0
        else -- on / in / fallback
          return lower >= 0 and upper <= 0
        end
      end
      local c = cmp_date(tv, ref)
      if op == "before" then
        return c < 0
      elseif op == "after" then
        return c > 0
      elseif op == "on" then
        return c == 0
      elseif op == "on_or_before" then
        return c <= 0
      elseif op == "on_or_after" then
        return c >= 0
      elseif op == "in" then
        -- Single-date `in`: treat as `on` for back-compat with prior v1 behaviour.
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
    local urgency_mod = require("obsidian-tasks.task.urgency")
    local op = filter.operator -- "above" / "below"
    local threshold = tonumber(filter.value) or 0
    return function(task)
      local u = urgency_mod.calculate(task)
      if op == "above" then
        return u > threshold
      elseif op == "below" then
        return u < threshold
      end
      return false
    end
  end

  if ft == "random" then
    -- 'random' in the TS plugin means "no filter" (show all).
    return function(_)
      return true
    end
  end

  -- ── dependency filters ──────────────────────────────────────────────────
  -- Split a comma-separated `depends_on` field into a list of trimmed ids.
  local function split_dep_list(s)
    if not s or s == "" then
      return {}
    end
    local out = {}
    for part in (s .. ","):gmatch("([^,]+),") do
      local trimmed = part:match("^%s*(.-)%s*$")
      if trimmed ~= "" then
        out[#out + 1] = trimmed
      end
    end
    return out
  end

  if ft == "id_is" then
    local want = filter.value
    return function(task)
      return task.fields and task.fields.id == want
    end
  end

  if ft == "depends_on" then
    local want = filter.value
    return function(task)
      for _, dep in ipairs(split_dep_list(task.fields and task.fields.depends_on)) do
        if dep == want then
          return true
        end
      end
      return false
    end
  end

  -- `is blocking` / `is blocked` need access to the full index for reverse
  -- lookup.  The maps are built once per query-run (when this leaf predicate
  -- is compiled), not per task — a full-index walk inside the predicate body
  -- would be O(N²).  The index module exports tasks_in() to enumerate tasks.
  local function build_dependency_maps()
    local index = require("obsidian-tasks.index")
    local blockers = {} -- id → true (any other task lists this id in its depends_on)
    local id_to_done = {} -- id → boolean (is the task with this id done?)
    for t in index.tasks_in(nil) do
      if t.fields and t.fields.id and t.fields.id ~= "" then
        id_to_done[t.fields.id] = not status.is_pending(status.by_symbol[t.status_symbol])
      end
      if t.fields and t.fields.depends_on then
        for _, dep in ipairs(split_dep_list(t.fields.depends_on)) do
          blockers[dep] = true
        end
      end
    end
    return blockers, id_to_done
  end

  if ft == "is_blocking" or ft == "is_not_blocking" then
    local blockers = build_dependency_maps()
    return function(task)
      local id = task.fields and task.fields.id
      if not id or id == "" then
        return ft == "is_not_blocking"
      end
      local blocking = blockers[id] == true
      if ft == "is_blocking" then
        return blocking
      else
        return not blocking
      end
    end
  end

  if ft == "is_blocked" or ft == "is_not_blocked" then
    local _, id_to_done = build_dependency_maps()
    return function(task)
      local deps = split_dep_list(task.fields and task.fields.depends_on)
      if #deps == 0 then
        return ft == "is_not_blocked"
      end
      -- A task is blocked iff ANY of its declared dependencies is still
      -- not-done.  When a dependency id isn't present in id_to_done at all
      -- (the dependency task is missing from the index), treat it as
      -- still-not-done — the conservative answer is "blocked".
      for _, dep in ipairs(deps) do
        if id_to_done[dep] ~= true then
          return ft == "is_blocked"
        end
      end
      return ft == "is_not_blocked"
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
