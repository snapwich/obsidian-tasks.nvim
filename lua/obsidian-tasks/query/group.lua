-- lua/obsidian-tasks/query/group.lua
-- Group-key resolvers: function(task, path) → group_name string.
--
-- Multi-key grouping produces a "/"-joined name, matching the TS plugin's
-- `groupNames` join convention.
--
-- For v1 a task can belong to exactly one group per key.  Tags are an
-- exception: a task with N tags produces N group names (one per tag).
-- run.lua handles the expansion.

local M = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

local DATE_NONE = "No date"

local function date_group(task, field)
  local v
  if field == "happens" then
    local candidates = {}
    for _, key in ipairs({ "due", "scheduled", "start" }) do
      local fv = task.fields and task.fields[key]
      if fv and fv ~= "" then
        candidates[#candidates + 1] = fv
      end
    end
    if #candidates == 0 then
      return DATE_NONE
    end
    table.sort(candidates)
    v = candidates[1]
  else
    v = task.fields and task.fields[field]
  end
  return (v and v ~= "") and v or DATE_NONE
end

--- Group labels mirror upstream's ordering: None sits BETWEEN Medium and Low
--- (matches the Priority enum: Highest=0 < High=1 < Medium=2 < None=3 < Low=4 < Lowest=5).
--- Our 1-based labels make None=4 so it sorts after Medium and before Low.
local PRIORITY_NAMES = {
  highest = "Priority 1: Highest",
  high = "Priority 2: High",
  medium = "Priority 3: Medium",
  none = "Priority 4: None",
  low = "Priority 5: Low",
  lowest = "Priority 6: Lowest",
}

local function priority_group(task)
  local p = task.fields and task.fields.priority or "none"
  return PRIORITY_NAMES[p] or "Priority 4: None"
end

local function status_group(task)
  local status = require("obsidian-tasks.task.status")
  local entry = status.by_symbol[task.status_symbol]
  if entry then
    return entry.name
  end
  -- Unknown symbol: use the raw symbol.
  return task.status_symbol or "Unknown"
end

local function path_group(_task, path)
  return path or "Unknown"
end

local function folder_group(_task, path)
  return (path or ""):match("^(.*)/[^/]*$") or ""
end

local function root_group(_task, path)
  -- First directory below the vault root.  Vault-relative semantics:
  --   daily/2024-03-15.md → "daily"
  --   daily/sub/note.md   → "daily"
  --   note.md             → ""
  local parts = vim.split(path or "", "/", { plain = true })
  local dirs = {}
  for _, p in ipairs(parts) do
    if p ~= "" then
      dirs[#dirs + 1] = p
    end
  end
  if #dirs <= 1 then
    return ""
  end
  return dirs[1]
end

local function filename_group(_task, path)
  local fname = (path or ""):match("[^/]+$") or ""
  -- Parens truncate gsub's 2-return (string, count) to just the string;
  -- without them, the count leaks into `{ filename_group(...) }` callers.
  return (fname:gsub("%.[^.]+$", ""))
end

local function backlink_group(_task, path)
  local fname = (path or ""):match("[^/]+$") or ""
  return (fname:gsub("%.[^.]+$", ""))
end

local function heading_group(_task, _path)
  return "No heading" -- not tracked in v1
end

local function recurrence_group(task)
  local rec = task.fields and task.fields.recurrence
  if rec and rec ~= "" then
    return rec
  end
  return "None"
end

local function id_group(task)
  local id = task.fields and task.fields.id
  if id and id ~= "" then
    return id
  end
  return "No ID"
end

local function urgency_group(task)
  -- Bucket by the integer portion to keep group counts manageable.
  -- Format: "Urgency: 8" for a score of 8.31, etc.
  local u = require("obsidian-tasks.task.urgency").calculate(task)
  return string.format("Urgency: %d", math.floor(u))
end

-- ── single-key resolver ───────────────────────────────────────────────────────

--- Return a list of group name strings for a task under a single group_by key.
--- Most keys produce exactly one name; 'tags' may produce multiple.
---
--- @param task   table
--- @param path   string
--- @param key    string  group_by key
--- @return string[]
local function resolve_key(task, path, key)
  if key == "status" then
    return { status_group(task) }
  end
  if key == "priority" then
    return { priority_group(task) }
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
    return { date_group(task, key) }
  end
  if key == "path" then
    return { path_group(task, path) }
  end
  if key == "folder" then
    return { folder_group(task, path) }
  end
  if key == "root" then
    return { root_group(task, path) }
  end
  if key == "filename" then
    return { filename_group(task, path) }
  end
  if key == "backlink" then
    return { backlink_group(task, path) }
  end
  if key == "heading" then
    return { heading_group(task, path) }
  end
  if key == "tags" then
    local tags = task.tags or {}
    if #tags == 0 then
      return { "No tags" }
    end
    local result = {}
    for _, tag in ipairs(tags) do
      result[#result + 1] = tag
    end
    return result
  end
  if key == "recurrence" or key == "recurring" then
    return { recurrence_group(task) }
  end
  if key == "id" then
    return { id_group(task) }
  end
  if key == "urgency" then
    return { urgency_group(task) }
  end
  if key == "random" then
    -- Random bucket per task.  Useful for "show me one task from each random
    -- partition" workflows.  Bucket is stable within a single render pass
    -- because group/sort resolution happens once per task.
    return { tostring(math.random(1, 1000)) }
  end
  return { "Unknown" }
end

-- ── public API ─────────────────────────────────────────────────────────────────

--- Return a list of group name strings for a task given a list of group_by
--- directives.  For multi-key grouping the names are joined with " / ".
--- Tags may expand to multiple entries, each being a combined name.
---
--- @param task         table
--- @param path         string
--- @param group_by_list table[]  list of { key, reverse }
--- @return string[]   list of group names the task belongs to
function M.resolve(task, path, group_by_list)
  if not group_by_list or #group_by_list == 0 then
    return { "" } -- ungrouped: single empty-string group
  end

  -- For each key, get the list of name segments.
  -- Tags can produce multiple segments → cartesian expansion.
  local segments_per_key = {}
  for _, directive in ipairs(group_by_list) do
    segments_per_key[#segments_per_key + 1] = resolve_key(task, path, directive.key)
  end

  -- Cartesian product of all key segments (usually 1×1×1…).
  local combinations = { {} }
  for _, segs in ipairs(segments_per_key) do
    local new_combos = {}
    for _, combo in ipairs(combinations) do
      for _, seg in ipairs(segs) do
        local new_combo = {}
        for _, part in ipairs(combo) do
          new_combo[#new_combo + 1] = part
        end
        new_combo[#new_combo + 1] = seg
        new_combos[#new_combos + 1] = new_combo
      end
    end
    combinations = new_combos
  end

  local names = {}
  for _, combo in ipairs(combinations) do
    names[#names + 1] = table.concat(combo, " / ")
  end
  return names
end

return M
