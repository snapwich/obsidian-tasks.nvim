-- lua/obsidian-tasks/render/alias.lua
-- Resolve a note's first frontmatter alias for the rendered backlink suffix.
--
-- Lazy, per-path, mtime-keyed cache: each source file's frontmatter is parsed
-- at most once per (path, mtime).  Used by render/layout.lua via the
-- `resolve_alias` opt to render `[[basename|alias]]` backlink suffixes.

local M = {}

-- abs_path → { mtime = <number|false>, alias = <string|nil> }
local _cache = {}

--- Extract the first alias from a parsed frontmatter table.
--- Handles `aliases` as a list ({ "A", "B" }) or a bare string ("A").
--- @param fm table|nil  merged frontmatter from util/obsidian.parse_frontmatter
--- @return string|nil
local function first_alias(fm)
  if type(fm) ~= "table" then
    return nil
  end
  local aliases = fm.aliases
  if type(aliases) == "string" then
    return aliases ~= "" and aliases or nil
  end
  if type(aliases) == "table" then
    local first = aliases[1]
    if type(first) == "string" and first ~= "" then
      return first
    end
  end
  return nil
end

--- Return the first frontmatter alias of the note at *abs_path*, or nil when
--- the note has no alias / is unreadable.  The result is cached until the
--- file's mtime changes.
---
--- @param abs_path string  absolute path to the markdown file
--- @return string|nil
function M.for_path(abs_path)
  if type(abs_path) ~= "string" or abs_path == "" then
    return nil
  end
  local stat = vim.uv.fs_stat(abs_path)
  local mtime = (stat and stat.mtime.sec) or false
  local cached = _cache[abs_path]
  if cached and cached.mtime == mtime then
    return cached.alias
  end
  local fm = require("obsidian-tasks.util.obsidian").parse_frontmatter(abs_path)
  local alias = first_alias(fm)
  _cache[abs_path] = { mtime = mtime, alias = alias }
  return alias
end

--- Clear the cache.  For test isolation only.
function M._reset()
  _cache = {}
end

return M
