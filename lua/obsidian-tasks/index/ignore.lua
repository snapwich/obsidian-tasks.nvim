-- lua/obsidian-tasks/index/ignore.lua
-- Determine whether a file should be excluded from the task index.

local M = {}

local log = require("obsidian-tasks.log")

--- Decide ignore from already-parsed frontmatter.
---
--- Pure: takes the frontmatter table directly so a caller that has already read
--- the file (the single-read indexer path) need not re-read it.  `fm == nil`
--- (read error) is treated as not-ignored, matching is_ignored.
---
--- tasks-plugin.ignore may be a nested table key
--- (`{ ["tasks-plugin"] = { ignore = true } }`) or a flat dotted key
--- (`{ ["tasks-plugin.ignore"] = true }`).
---
--- @param fm table|nil  parsed frontmatter
--- @return boolean
function M.is_ignored_fm(fm)
  if fm == nil then
    return false
  end
  local plugin_ns = fm["tasks-plugin"]
  if type(plugin_ns) == "table" and plugin_ns.ignore == true then
    return true
  end
  if fm["tasks-plugin.ignore"] == true then
    return true
  end
  return false
end

--- Return true if the file at *abs_path* should be ignored by the index.
---
--- Checks frontmatter for `tasks-plugin.ignore: true` via obsidian adapter.
---
--- @param abs_path string  absolute path to the markdown file
--- @return boolean
function M.is_ignored(abs_path)
  local obsidian = require("obsidian-tasks.util.obsidian")

  -- ── frontmatter check ─────────────────────────────────────────────────────
  local fm, errs = obsidian.parse_frontmatter(abs_path)
  if fm == nil then
    -- Unreadable file — log the first error and treat as not ignored so the
    -- caller's error handling (stat before open) can decide what to do.
    if errs and #errs > 0 then
      log.warn(("index.ignore: cannot read frontmatter for %s: %s"):format(abs_path, errs[1]))
    end
    return false
  end

  return M.is_ignored_fm(fm)
end

return M
