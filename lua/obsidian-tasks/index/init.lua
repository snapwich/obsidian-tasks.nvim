-- lua/obsidian-tasks/index/init.lua
-- In-memory task index.
--
-- Internal map shape:
--   _index[abs_path] = {
--     mtime = <number>,
--     nodes = { <node>, ... },         -- full per-file node list (index/nodes)
--     tasks = { { task, line_num }, ... }, -- DERIVED flat task view (kind==task)
--   }
--
-- `nodes` is the first-class structure (tasks + description bullets + blanks,
-- with depth / parent_line).  `tasks` is a derived projection kept for the
-- existing flat task consumers (tasks_in, render source-diagnostics) so the
-- node restructure stays behavior-preserving at the task level.
--
-- All public functions are safe to call from normal Neovim context.
-- Async walks (refresh_all) fire callbacks after the walk completes.

local M = {}

-- ── internal state ────────────────────────────────────────────────────────────

-- Main index: abs_path → { mtime, tasks }
local _index = {}

-- Reverse index: abs_path → set of bufnrs whose renders include tasks from that path.
-- Shape: _reverse_index[abs_path] = { [bufnr] = true, ... }
local _reverse_index = {}

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Canonicalize *abs_path* to the index's key form (vim.fs.normalize — forward
--- slashes).  Vault-scan keys arrive already normalized, but buffer-derived
--- paths (`nvim_buf_get_name` in the BufReadPost/BufWritePost autocmds) are
--- all-backslash on Windows; without one canonical key form the same file gets
--- indexed twice and every task in it renders duplicated.  Applied at every
--- public path-taking entry point so no caller can split a file across keys.
--- (Inlined rather than routed through util/obsidian.normalize because tests
--- stub that adapter module with partial tables.)
--- @param abs_path string|nil
--- @return string|nil
local function canonical(abs_path)
  if type(abs_path) ~= "string" or abs_path == "" then
    return abs_path
  end
  return vim.fs.normalize(abs_path)
end

--- Return the mtime (seconds) for *abs_path*, or nil if stat fails.
--- @param abs_path string
--- @return number|nil
local function get_mtime(abs_path)
  local stat = vim.uv.fs_stat(abs_path)
  return stat and stat.mtime.sec
end

--- Extract a YYYY-MM-DD date from a file's basename when present.
--- Used by the use_filename_as_scheduled_date setting (upstream parity).
--- Matches both `YYYY-MM-DD.md` and `prefix-YYYY-MM-DD.md` forms.
--- @param abs_path string
--- @return string|nil  "YYYY-MM-DD" or nil
local function date_from_basename(abs_path)
  local base = abs_path:match("[^/]+$") or ""
  -- Strip optional .md extension.
  base = base:gsub("%.md$", "")
  -- Search for YYYY-MM-DD anywhere in the (extension-stripped) basename.
  local y, mo, d = base:match("(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil
  end
  local mn = tonumber(mo)
  local dn = tonumber(d)
  if mn < 1 or mn > 12 or dn < 1 or dn > 31 then
    return nil
  end
  return string.format("%s-%s-%s", y, mo, d)
end

--- Build the per-task post-processing hook applied during node parsing.
--- Encapsulates the two task-level concerns that were previously inline:
---   * global_filter — drop tasks whose description lacks the filter string.
---   * DateFallback  — inherit the filename's date as `scheduled` when absent.
--- @param abs_path string
--- @return fun(task: table): boolean|nil  return false to drop the task
local function make_on_task(abs_path)
  local opts = require("obsidian-tasks").opts
  local global_filter = opts and opts.global_filter
  local use_filename_date = opts and opts.use_filename_as_scheduled_date
  local filename_date = use_filename_date and date_from_basename(abs_path) or nil

  return function(task)
    if global_filter and global_filter ~= "" then
      if not task.description:find(global_filter, 1, true) then
        return false
      end
    end
    if filename_date and (task.fields.scheduled == nil or task.fields.scheduled == "") then
      task.fields.scheduled = filename_date
    end
    return true
  end
end

--- Full-read *abs_path* and parse it into the unified node list.
--- @param abs_path string
--- @return table[]  node list (may be empty)
local function parse_file(abs_path)
  local nodes = require("obsidian-tasks.index.nodes")
  return nodes.parse_file(abs_path, { on_task = make_on_task(abs_path) })
end

--- Project a node list to the flat task view consumed by tasks_in and render's
--- source diagnostics: a list of { task = Task, line_num = integer }.
--- @param nodes table[]
--- @return table[]
local function tasks_from_nodes(nodes)
  local tasks = {}
  for _, n in ipairs(nodes) do
    if n.kind == "task" then
      tasks[#tasks + 1] = { task = n.task, line_num = n.line_num }
    end
  end
  return tasks
end

--- Build a complete index entry for *abs_path* from a node list.
--- @param mtime number
--- @param nodes table[]
--- @return table  { mtime, nodes, tasks }
local function make_entry(mtime, nodes)
  return { mtime = mtime, nodes = nodes, tasks = tasks_from_nodes(nodes) }
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Re-parse a single file and update the index.
--- No-op if the file's mtime is unchanged since last parse.
---
--- Respects ignore rules (via index/ignore.lua) and global_filter.
---
--- @param abs_path string  absolute path to the markdown file
function M.refresh_file(abs_path)
  abs_path = canonical(abs_path)
  local mtime = get_mtime(abs_path)

  -- File no longer on disk: drop the entry and skip the ignore check
  -- (parse_frontmatter on a missing file logs a misleading "cannot read
  -- frontmatter" warn, and the entry would otherwise persist with nil mtime
  -- and re-trigger the warn on every refresh_all_indexed_mtime).
  if mtime == nil then
    _index[abs_path] = nil
    return
  end

  local ignore = require("obsidian-tasks.index.ignore")
  if ignore.is_ignored(abs_path) then
    _index[abs_path] = nil
    return
  end

  -- mtime no-op: if entry exists and mtime hasn't changed, skip.
  local entry = _index[abs_path]
  if entry and entry.mtime == mtime then
    return
  end

  local nodes = parse_file(abs_path)
  _index[abs_path] = make_entry(mtime, nodes)
end

--- Re-parse every currently-indexed file synchronously, bypassing the
--- mtime no-op check so external edits made within the same second resolution
--- are picked up.  Files no longer on disk are dropped.
---
--- Does NOT discover new files (that would require a vault walk via
--- refresh_all).  Used by `<leader>tr` for an on-demand refresh.
function M.refresh_all_indexed_sync()
  local paths = {}
  for path in pairs(_index) do
    paths[#paths + 1] = path
  end
  for _, path in ipairs(paths) do
    _index[path] = nil -- bypass mtime no-op
    M.refresh_file(path)
  end
end

--- Re-parse every currently-indexed file synchronously, honouring the
--- per-file mtime no-op check so unchanged files cost only one `fs_stat`.
---
--- Used by the FocusGained autocmd to pick up external edits (Obsidian
--- desktop app, `git pull`, syncthing) cheaply on every focus event.  Unlike
--- refresh_all_indexed_sync this does NOT bypass the mtime gate, so it is safe
--- to run unconditionally — a vault of unchanged files costs N stat calls.
---
--- Does NOT discover new files (that would require a vault walk via
--- refresh_all).  Files no longer on disk are dropped.
function M.refresh_all_indexed_mtime()
  local paths = {}
  for path in pairs(_index) do
    paths[#paths + 1] = path
  end
  for _, path in ipairs(paths) do
    M.refresh_file(path)
  end
end

--- Full vault walk: re-parse every file via async search.
---
--- *on_done* is called (with no arguments) once the walk finishes.
---
--- @param workspace  table   workspace object with `.root`
--- @param on_done    fun()?  optional callback when walk is complete
function M.refresh_all(workspace, on_done)
  local scan = require("obsidian-tasks.index.scan")

  -- Accumulate per-path entries during the walk; merge once it completes so a
  -- partial walk never leaves the index half-updated.
  local pending = {} -- abs_path → { mtime, nodes, tasks }

  scan.walk_files(workspace, function(abs_path, nodes)
    local mtime = get_mtime(abs_path)
    pending[canonical(abs_path)] = make_entry(mtime, nodes)
  end, function(_code)
    -- Files outside this workspace root never appear in the discovery results,
    -- so they are untouched; discovered files replace their prior entry.
    -- (scan.walk_files already drops ignored files before emitting.)
    for abs_path, entry in pairs(pending) do
      _index[abs_path] = entry
    end
    if on_done then
      on_done()
    end
  end, make_on_task)
end

--- Iterate Task objects in the index, optionally filtered by a path predicate.
---
--- @param path_filter fun(abs_path: string): boolean | nil
---   When provided, only tasks from files where `path_filter(abs_path)` is
---   truthy are yielded.  Pass nil to iterate all indexed tasks.
--- @return fun(): table|nil, string|nil, integer|nil
---   iterator returning (task, abs_path, line_num)
function M.tasks_in(path_filter)
  -- Collect all matching entries first, then return an iterator.
  -- entry.tasks is the DERIVED flat task view ({ task, line_num }) projected
  -- from the kind=="task" nodes; this iterator's shape is unchanged by the
  -- node restructure (the blast-radius firewall for query/sort/group/render).
  local result = {}
  for abs_path, entry in pairs(_index) do
    if path_filter == nil or path_filter(abs_path) then
      for _, item in ipairs(entry.tasks) do
        result[#result + 1] = { task = item.task, path = abs_path, line_num = item.line_num }
      end
    end
  end
  local i = 0
  return function()
    i = i + 1
    local item = result[i]
    if item then
      return item.task, item.path, item.line_num
    end
  end
end

--- Return the full per-file NODE list for *abs_path* (the first-class node
--- model: tasks + description bullets + blanks, with depth / parent_line).
---
--- This is the structured accessor query/tree.lua uses to slice a matched
--- task's descendant subtree.  Unlike tasks_in (the flat task-view firewall),
--- it exposes the complete hierarchy.  Returns an empty list when the path is
--- not indexed (never nil), so callers can iterate unconditionally.
---
--- @param abs_path string  absolute path
--- @return table[]  node list (the entry's own table; do NOT mutate)
function M.nodes_for(abs_path)
  local entry = _index[canonical(abs_path)]
  return (entry and entry.nodes) or {}
end

--- Drop the index entry for *abs_path*.
--- Next call to refresh_file will re-parse from disk.
---
--- @param abs_path string
function M.invalidate(abs_path)
  _index[canonical(abs_path)] = nil
end

--- Return a list of bufnrs whose render results currently include tasks from *path*.
---
--- The reverse index is maintained by render/init.lua via M.set_render_paths /
--- M.clear_render_paths — callers must not populate it manually.
---
--- @param path string  absolute path
--- @return integer[]  list of buffer numbers (may be empty)
function M.reverse_index(path)
  local set = _reverse_index[canonical(path)]
  if not set then
    return {}
  end
  local result = {}
  for bufnr in pairs(set) do
    result[#result + 1] = bufnr
  end
  return result
end

--- Record that *bufnr*'s current render includes tasks from the paths in
--- *paths_set* (a { [abs_path] = true } table).
---
--- Called by render/init.lua after render_buffer completes.  Any previous
--- path associations for *bufnr* are removed first so the index stays accurate
--- across re-renders.
---
--- @param bufnr     integer
--- @param paths_set table   { [abs_path] = true }
function M.set_render_paths(bufnr, paths_set)
  -- Remove this bufnr from all existing reverse-index entries.
  for _, set in pairs(_reverse_index) do
    set[bufnr] = nil
  end
  -- Add it for the new set of paths.
  for path in pairs(paths_set) do
    local key = canonical(path)
    if not _reverse_index[key] then
      _reverse_index[key] = {}
    end
    _reverse_index[key][bufnr] = true
  end
end

--- Remove all reverse-index associations for *bufnr*.
---
--- Called by render/init.lua when a buffer's render is cleared.
---
--- @param bufnr integer
function M.clear_render_paths(bufnr)
  for _, set in pairs(_reverse_index) do
    set[bufnr] = nil
  end
end

--- Direct access to the internal index for testing.
--- Not part of the public API — do not use outside tests.
--- @return table
function M._raw()
  return _index
end

--- Reset the index (for testing).
--- @return nil
function M._reset()
  _index = {}
  _reverse_index = {}
end

--- Direct access to the internal reverse index for testing.
--- Not part of the public API — do not use outside tests.
--- @return table
function M._raw_reverse()
  return _reverse_index
end

--- Exposed for unit testing of the use_filename_as_scheduled_date helper.
--- @param abs_path string
--- @return string|nil
function M._date_from_basename(abs_path)
  return date_from_basename(abs_path)
end

return M
