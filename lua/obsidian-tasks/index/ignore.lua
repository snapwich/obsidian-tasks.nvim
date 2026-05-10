-- lua/obsidian-tasks/index/ignore.lua
-- Determine whether a file should be excluded from the task index.

local M = {}

local log = require("obsidian-tasks.log")

--- Return true if the file at *abs_path* should be ignored by the index.
---
--- Checks frontmatter for `tasks-plugin.ignore: true` via obsidian adapter.
--- Also attempts to load `.obsidian/plugins/obsidian-tasks/data.json` for
--- additional ignore rules (best-effort; errors are non-fatal warns).
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

  -- tasks-plugin.ignore may be a nested table key: { ["tasks-plugin"] = { ignore = true } }
  -- or occasionally a flat key: { ["tasks-plugin.ignore"] = true }.
  local plugin_ns = fm["tasks-plugin"]
  if type(plugin_ns) == "table" and plugin_ns.ignore == true then
    return true
  end
  if fm["tasks-plugin.ignore"] == true then
    return true
  end

  return false
end

return M
