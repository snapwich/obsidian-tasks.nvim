-- lua/obsidian-tasks/util/obsidian.lua
-- Adapter wrapping the obsidian.nvim API surface.
-- All obsidian.nvim access from the rest of our code MUST go through here.
-- API mismatches localize to this file when obsidian.nvim renames or refactors.

local M = {}

-- ── module guard ──────────────────────────────────────────────────────────────

--- Assert that obsidian.nvim is initialised (Obsidian global must be set).
--- Raised on first call to any adapter function before obsidian.nvim is ready.
local function check_guard()
  if not Obsidian then
    error("obsidian-tasks: requires obsidian.nvim to be set up first", 2)
  end
end

-- ── workspace helpers ─────────────────────────────────────────────────────────

--- Return the current obsidian.nvim workspace object.
--- @return table  Obsidian.workspace ({ root, name, ... })
function M.current_workspace()
  check_guard()
  return Obsidian.workspace
end

--- Find the workspace that owns the given absolute path.
--- @param abs_path string
--- @return table|nil  workspace or nil
function M.workspace_for_path(abs_path)
  check_guard()
  return require("obsidian.api").find_workspace(abs_path)
end

--- Activate a workspace by name or workspace object.
--- @param name_or_obj string|table
function M.set_workspace(name_or_obj)
  check_guard()
  require("obsidian").Workspace.set(name_or_obj)
end

--- Return the full list of configured obsidian.nvim workspaces.
--- @return table[]
function M.workspaces()
  check_guard()
  return Obsidian.workspaces
end

-- ── file / search ─────────────────────────────────────────────────────────────

--- Async walk of all Markdown files under workspace.root.
--- Wraps obsidian.search.find_async; calls on_match only for *.md paths.
--- @param workspace  table    workspace object (must have .root)
--- @param on_match   fun(path: string)
--- @param on_exit    fun(code: integer)
function M.find_files_async(workspace, on_match, on_exit)
  check_guard()
  local search = require("obsidian.search")
  search.find_async(workspace.root, "", {}, function(path)
    -- Filter to markdown files only
    if type(path) == "string" and path:match("%.md$") then
      on_match(path)
    end
  end, on_exit)
end

--- Async content search across workspace files.
--- on_match receives MatchData: { path.text, lines.text, line_number, submatches }.
--- @param workspace  table
--- @param pattern    string
--- @param on_match   fun(match: table)
--- @param on_exit    fun(code: integer)
function M.search_async(workspace, pattern, on_match, on_exit)
  check_guard()
  local search = require("obsidian.search")
  search.search_async(workspace.root, pattern, {}, on_match, on_exit)
end

-- ── frontmatter ───────────────────────────────────────────────────────────────

--- Parse the YAML frontmatter of a file at the given path.
--- obsidian.frontmatter.parse expects ONLY the YAML region (between `---`
--- delimiters), not the full file. We slice that region here before calling.
--- Returns (ret, metadata, errors) where:
---   ret      = validated/known keys (id, tags, aliases, ...)
---   metadata = all other user YAML keys
---   errors   = list of validation error strings
--- We merge ret+metadata into one table so callers get the full picture.
--- @param path string  absolute path to the file
--- @return table|nil  merged frontmatter (ret ∪ metadata), or nil on read error
--- @return table      errors list (empty on success; non-empty on parse or read error)
function M.parse_frontmatter(path)
  check_guard()
  local lines = {}
  local ok, err_msg = pcall(function()
    local f = io.open(path, "r")
    if not f then
      error("cannot open file: " .. tostring(path))
    end
    for line in f:lines() do
      lines[#lines + 1] = line
    end
    f:close()
  end)
  if not ok then
    return nil, { err_msg }
  end

  if lines[1] ~= "---" then
    return {}, {}
  end
  local fm_lines = {}
  for i = 2, #lines do
    if lines[i] == "---" then
      break
    end
    fm_lines[#fm_lines + 1] = lines[i]
  end

  local frontmatter = require("obsidian.frontmatter")
  local ret, metadata, errors = frontmatter.parse(fm_lines, path)
  return vim.tbl_extend("force", metadata or {}, ret or {}), errors or {}
end

-- ── path shorthand ────────────────────────────────────────────────────────────

--- Construct an obsidian.nvim Path object.
--- obsidian.path returns the Path constructor table directly (not nested under .Path).
--- @param p string|table
--- @return table  Path object
function M.path(p)
  check_guard()
  return require("obsidian.path").new(p)
end

-- ── workspace path filter ────────────────────────────────────────────────────

--- Build a path_filter predicate scoped to a workspace root.
--- Handles Path objects (tostring) and ensures trailing-slash so
--- "/vault" does not match "/vault-other/file.md".
--- @param workspace_root string|table  workspace.root (Path object or string)
--- @return fun(abs_path: string): boolean
function M.workspace_path_filter(workspace_root)
  local root = tostring(workspace_root)
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  return function(abs_path)
    return abs_path:find(root, 1, true) == 1
  end
end

return M
