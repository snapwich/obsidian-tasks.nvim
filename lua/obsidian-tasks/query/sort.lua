-- lua/obsidian-tasks/query/sort.lua
-- Comparator factory from a sort_by directive list.
--
-- Each sort_by entry is { key, reverse }.
-- Returns a comparator function suitable for table.sort.
-- Stable sort: tasks at the same rank retain their original index order
-- (caller should pass `_idx` on each task item if needed; see run.lua).

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Priority ordering (higher number = higher priority, sorts to front by default).
--- Mirrors obsidian-tasks TS Priority enum: `none` sits BETWEEN medium and
--- low — see lua/obsidian-tasks/query/filter.lua's PRIORITY_ORDER for the
--- upstream rationale.
local PRIORITY_ORDER = {
  highest = 6,
  high = 5,
  medium = 4,
  none = 3,
  low = 2,
  lowest = 1,
}

--- Return a comparable value for a task's priority (higher = more important).
local function priority_ord(task)
  local p = task.fields and task.fields.priority or "none"
  return PRIORITY_ORDER[p] or 3
end

--- Return a date string for a field, or a sentinel string that sorts last.
local DATE_MAX = "9999-99-99"

local function date_val(task, field)
  if field == "happens" then
    local candidates = {}
    for _, key in ipairs({ "due", "scheduled", "start" }) do
      local v = task.fields and task.fields[key]
      if v and v ~= "" then
        candidates[#candidates + 1] = v
      end
    end
    if #candidates == 0 then
      return DATE_MAX
    end
    table.sort(candidates)
    return candidates[1]
  end
  local v = task.fields and task.fields[field]
  return (v and v ~= "") and v or DATE_MAX
end

--- Return task status entry type string (or empty string if unknown).
local function status_type(task)
  local status = require("obsidian-tasks.task.status")
  local entry = status.by_symbol[task.status_symbol]
  return entry and entry.type or ""
end

-- ── per-key extractor ─────────────────────────────────────────────────────────
-- Each extractor returns a value used in comparison.
-- For string comparisons the comparison is lexicographic.
-- For numeric comparisons (priority) the comparison is numeric.

--- Return { value, kind } where kind is 'str' or 'num'.
--- @param task  table
--- @param path  string
--- @param key   string
--- @return any, string
local function extract(task, path, key)
  if key == "status" then
    -- Sort by status type enum ordering (alphabetical on type string).
    return status_type(task), "str"
  end
  if key == "priority" then
    -- Numeric: higher priority → smaller index (sort desc by default).
    -- We return the raw ordinal; caller handles reversal.
    return priority_ord(task), "num"
  end
  if
    key == "due"
    or key == "scheduled"
    or key == "start"
    or key == "done"
    or key == "created"
    or key == "cancelled"
    or key == "happens"
  then
    return date_val(task, key), "str"
  end
  if key == "path" then
    return path or "", "str"
  end
  if key == "folder" then
    return (path or ""):match("^(.*)/[^/]*$") or "", "str"
  end
  if key == "root" then
    -- Top-level subfolder within the vault.
    -- /vault/sub/note.md → "sub";  /vault/note.md → "" (directly in vault).
    local parts = vim.split(path or "", "/", { plain = true })
    local dirs = {}
    for _, p in ipairs(parts) do
      if p ~= "" then
        dirs[#dirs + 1] = p
      end
    end
    if #dirs <= 2 then
      return "", "str"
    end
    return dirs[2], "str"
  end
  if key == "filename" then
    return (path or ""):match("[^/]+$") or "", "str"
  end
  if key == "backlink" then
    local fname = (path or ""):match("[^/]+$") or ""
    return fname:gsub("%.[^.]+$", ""), "str"
  end
  if key == "description" then
    return (task.description or ""):lower(), "str"
  end
  if key == "heading" then
    return "", "str" -- not tracked in v1
  end
  if key == "tags" then
    -- Sort by first tag alphabetically (or empty string).
    local tags = task.tags or {}
    return tags[1] and tags[1]:lower() or "", "str"
  end
  if key == "urgency" then
    return 0, "num" -- not computed in v1
  end
  if key == "recurrence" or key == "recurring" then
    return (task.fields and task.fields.recurrence or ""):lower(), "str"
  end
  if key == "id" then
    return (task.fields and task.fields.id or ""):lower(), "str"
  end
  if key == "blocking" then
    -- v2 feature; sort by empty string (stable, no-op).
    return "", "str"
  end
  if key == "random" then
    -- Sentinel: random is handled in the comparator (needs a wrapper-cached
    -- value to provide a stable total order to table.sort).  Falling through
    -- here would crash table.sort with "invalid order function".
    return nil, "random"
  end
  return "", "str"
end

-- ── public API ─────────────────────────────────────────────────────────────────

--- Build a comparator from a list of sort_by directives.
---
--- Each item in `sort_by_list`:
---   { key = 'due'|'priority'|..., reverse = bool }
---
--- The returned comparator is for use with `table.sort`.  Items are
--- wrapped as `{ task, path, _idx }` by run.lua for stable sort.
---
--- @param sort_by_list table[]  list of { key, reverse }
--- @return fun(a:table, b:table): boolean
function M.make_comparator(sort_by_list)
  if not sort_by_list or #sort_by_list == 0 then
    -- Stable: preserve original order.
    return function(a, b)
      return a._idx < b._idx
    end
  end

  return function(a, b)
    for _, directive in ipairs(sort_by_list) do
      local av, ak = extract(a.task, a.path, directive.key)
      local bv, _ = extract(b.task, b.path, directive.key)

      -- `random` sentinel: assign a stable random value to each wrapper on
      -- first encounter so successive comparisons see a consistent total
      -- order.  Without caching, table.sort raises "invalid order function".
      if ak == "random" then
        a._random = a._random or math.random()
        b._random = b._random or math.random()
        av, bv, ak = a._random, b._random, "num"
      end

      local less
      if ak == "num" then
        if av ~= bv then
          -- For numeric (priority): higher = more important → sorts first.
          -- Default (non-reverse): highest priority first.
          less = av > bv
        else
          less = nil
        end
      else
        if av ~= bv then
          less = av < bv
        else
          less = nil
        end
      end

      if less ~= nil then
        if directive.reverse then
          return not less
        end
        return less
      end
    end
    -- Tiebreaker: stable sort by original index.
    return a._idx < b._idx
  end
end

return M
