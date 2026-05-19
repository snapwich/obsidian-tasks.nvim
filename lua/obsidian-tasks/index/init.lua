-- lua/obsidian-tasks/index/init.lua
-- In-memory task index.
--
-- Internal map shape:
--   _index[abs_path] = { mtime = <number>, tasks = { Task, ... } }
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

--- Read and parse all task lines from *abs_path* synchronously.
--- Returns a list of { task = Task, line_num = integer } entries (may be empty).
--- @param abs_path string
--- @return table[]
local function parse_file(abs_path)
  local parse = require("obsidian-tasks.task.parse")
  local heading = require("obsidian-tasks.index.heading")
  local opts = require("obsidian-tasks").opts
  local global_filter = opts and opts.global_filter
  local use_filename_date = opts and opts.use_filename_as_scheduled_date
  local filename_date = use_filename_date and date_from_basename(abs_path) or nil

  local tasks = {}
  local ok = pcall(function()
    local f = io.open(abs_path, "r")
    if not f then
      return
    end
    local line_num = 0
    -- Running ATX heading: each task inherits the nearest heading above it.
    local current_heading = nil
    for line in f:lines() do
      line_num = line_num + 1
      local h = heading.parse(line)
      if h ~= nil then
        current_heading = h
      end
      local task = (h == nil) and parse.parse(line) or nil
      if task then
        task.heading = current_heading
        -- global_filter: post-parse exclusion
        if global_filter and global_filter ~= "" then
          if not task.description:find(global_filter, 1, true) then
            task = nil
          end
        end
        if task then
          -- DateFallback: inherit the filename's date as scheduled when the
          -- task does not have its own scheduled date.
          if filename_date and (task.fields.scheduled == nil or task.fields.scheduled == "") then
            task.fields.scheduled = filename_date
          end
          tasks[#tasks + 1] = { task = task, line_num = line_num }
        end
      end
    end
    f:close()
  end)
  if not ok then
    return {}
  end
  return tasks
end

-- ── public API ────────────────────────────────────────────────────────────────

--- Re-parse a single file and update the index.
--- No-op if the file's mtime is unchanged since last parse.
---
--- Respects ignore rules (via index/ignore.lua) and global_filter.
---
--- @param abs_path string  absolute path to the markdown file
function M.refresh_file(abs_path)
  local ignore = require("obsidian-tasks.index.ignore")

  -- Ignored files are always dropped.
  if ignore.is_ignored(abs_path) then
    _index[abs_path] = nil
    return
  end

  local mtime = get_mtime(abs_path)

  -- mtime no-op: if entry exists and mtime hasn't changed, skip.
  local entry = _index[abs_path]
  if entry and mtime and entry.mtime == mtime then
    return
  end

  -- tasks is a list of { task, line_num } entries.
  local tasks = parse_file(abs_path)
  _index[abs_path] = { mtime = mtime, tasks = tasks }
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
  local ignore = require("obsidian-tasks.index.ignore")

  -- Accumulate tasks per path during the walk.
  local pending = {} -- abs_path → { mtime, tasks = {} }

  scan.walk(workspace, function(task, abs_path, line_num)
    if not pending[abs_path] then
      local mtime = get_mtime(abs_path)
      pending[abs_path] = { mtime = mtime, tasks = {} }
    end
    pending[abs_path].tasks[#pending[abs_path].tasks + 1] = { task = task, line_num = line_num }
  end, function(_code)
    -- Merge pending into _index.
    -- Files that were previously indexed but returned no tasks in the new walk
    -- are removed only if they were visited (i.e., they appeared in search results
    -- for *this* workspace root). Files outside this workspace are untouched.
    for abs_path, entry in pairs(pending) do
      if not ignore.is_ignored(abs_path) then
        _index[abs_path] = entry
      end
    end
    if on_done then
      on_done()
    end
  end)
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
  -- Each entry in the index is { task = Task, line_num = integer }.
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

--- Drop the index entry for *abs_path*.
--- Next call to refresh_file will re-parse from disk.
---
--- @param abs_path string
function M.invalidate(abs_path)
  _index[abs_path] = nil
end

--- Return a list of bufnrs whose render results currently include tasks from *path*.
---
--- The reverse index is maintained by render/init.lua via M.set_render_paths /
--- M.clear_render_paths — callers must not populate it manually.
---
--- @param path string  absolute path
--- @return integer[]  list of buffer numbers (may be empty)
function M.reverse_index(path)
  local set = _reverse_index[path]
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
    if not _reverse_index[path] then
      _reverse_index[path] = {}
    end
    _reverse_index[path][bufnr] = true
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
