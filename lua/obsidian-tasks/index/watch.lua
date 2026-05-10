-- lua/obsidian-tasks/index/watch.lua
-- Per-workspace libuv file watcher with debounced index refresh.
--
-- Design:
--   * One `vim.uv.new_fs_event()` handle per directory (Linux fs_event is
--     non-recursive on most distros, so we watch each subdirectory individually).
--   * File-change events are funnelled into a per-workspace debounce queue;
--     `vim.defer_fn` coalesces rapid writes into a single flush.
--   * On flush: `index.refresh_file(path)` for each unique path, then fire
--     `User ObsidianTasksFilesChanged` so sibling module F7-T2 can refresh
--     visible renders.
--   * Errors during directory enumeration or handle creation are logged and
--     silently skipped — the plugin works without file watching.
--   * Newly-created subdirectories (detected via rename events + fs_stat) are
--     immediately watched.

local M = {}

-- ── Internal state ─────────────────────────────────────────────────────────────

--- Per-workspace handle lists.
--- M._handles[workspace.name] = { uv_fs_event_handle, ... }
M._handles = {}

--- Per-workspace debounce state.
--- _debounce[ws_name] = { timer = uv_timer|nil, paths = {[path]=true}, gen = int }
local _debounce = {}

--- Bufnrs that need a refresh deferred until the cursor leaves their render region.
--- _deferred[bufnr] = true
local _deferred = {}

-- ── Helpers ────────────────────────────────────────────────────────────────────

--- Recursively collect all directories under *dir* (dir itself included).
--- Subdirectories that cannot be read (permission denied, etc.) are silently
--- skipped — partial enumeration is better than no watcher at all.
---
--- @param dir string  absolute directory path
--- @return string[]
local function collect_dirs(dir)
  local result = { dir }
  local ok, scan = pcall(vim.uv.fs_scandir, dir)
  if not ok or not scan then
    return result
  end
  while true do
    local name, kind = vim.uv.fs_scandir_next(scan)
    if not name then
      break
    end
    if kind == "directory" then
      local child = dir .. "/" .. name
      local sub = collect_dirs(child)
      for _, d in ipairs(sub) do
        result[#result + 1] = d
      end
    end
  end
  return result
end

--- Return true if the current window's cursor sits inside a render-inserted
--- task region of *bufnr*.
---
--- Only relevant when *bufnr* is the current buffer; returns false otherwise.
--- Skipping non-current buffers is intentional: there is no "active cursor"
--- in a background buffer, so it is always safe to refresh those immediately.
---
--- @param bufnr integer
--- @return boolean
local function _cursor_in_render_region(bufnr)
  if vim.api.nvim_get_current_buf() ~= bufnr then
    return false
  end
  local render = require("obsidian-tasks.render")
  local buf_state = render._buffer_state[bufnr]
  if not buf_state then
    return false
  end
  -- cursor() is 1-indexed; convert to 0-indexed for comparison with render_range.
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cursor[1] - 1
  for _, block in ipairs(buf_state) do
    local rr = block.render_range
    if rr and cursor_line >= rr[1] and cursor_line <= rr[2] then
      return true
    end
  end
  return false
end

--- Refresh *bufnr* now (if valid) or defer until cursor leaves the render
--- region.  Must be called from the Neovim main loop (not a libuv callback).
---
--- @param bufnr integer
local function _refresh_or_defer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if _cursor_in_render_region(bufnr) then
    _deferred[bufnr] = true
    return
  end
  local render = require("obsidian-tasks.render")
  render.refresh_buffer(bufnr)
end

--- Push *path* into the debounce queue for *ws_name* and schedule a flush
--- after *delay_ms* milliseconds. Any previously pending flush is cancelled
--- and a new one is scheduled (debounce-reset behaviour).
---
--- A generation counter guards against stale flush callbacks that were already
--- queued by `vim.defer_fn` before a reschedule arrived.
---
--- @param ws_name  string
--- @param path     string  absolute path of the changed file
--- @param delay_ms number  debounce window in milliseconds
local function schedule_flush(ws_name, path, delay_ms)
  if not _debounce[ws_name] then
    _debounce[ws_name] = { timer = nil, paths = {}, gen = 0 }
  end
  local d = _debounce[ws_name]

  -- Accumulate the affected path.
  d.paths[path] = true

  -- Cancel any pending timer (stop + close wrapped in pcall in case the handle
  -- was already closed by vim.defer_fn's internal cleanup).
  if d.timer then
    pcall(function()
      d.timer:stop()
      d.timer:close()
    end)
    d.timer = nil
  end

  -- Advance the generation so stale flush callbacks bail out.
  d.gen = d.gen + 1
  local my_gen = d.gen

  d.timer = vim.defer_fn(function()
    -- Bail if this flush was superseded by a later reschedule.
    local entry = _debounce[ws_name]
    if not entry or entry.gen ~= my_gen then
      return
    end

    -- Drain the path set atomically.
    local paths_snapshot = entry.paths
    entry.paths = {}
    entry.timer = nil

    local unique = {}
    for p in pairs(paths_snapshot) do
      unique[#unique + 1] = p
    end
    if #unique == 0 then
      return
    end

    -- Refresh index for each changed file.
    local index = require("obsidian-tasks.index")
    for _, p in ipairs(unique) do
      index.refresh_file(p)
    end

    -- Collect affected bufnrs (deduplicated) from the reverse index.
    local affected = {}
    for _, p in ipairs(unique) do
      for _, bufnr in ipairs(index.reverse_index(p)) do
        affected[bufnr] = true
      end
    end

    -- Refresh each affected buffer exactly once.
    -- Buffers where the cursor is inside the render region are deferred until
    -- the cursor moves out (CursorMoved) or the buffer is written (BufWritePost).
    for bufnr in pairs(affected) do
      _refresh_or_defer(bufnr)
    end

    -- Notify listeners (e.g. integration tests) that files changed.
    -- Use pcall so a missing or broken handler never crashes the watcher.
    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "ObsidianTasksFilesChanged",
      data = { paths = unique },
    })
  end, delay_ms)
end

--- Watch a single directory *dir* for workspace *ws_name*.
---
--- The fs_event callback runs in the libuv default loop (not safe for Neovim
--- API calls); all Neovim-API work is deferred via `vim.schedule`.
---
--- Returns the libuv handle on success, or nil if the handle could not be
--- created or started (error is logged).
---
--- @param dir     string
--- @param ws_name string
--- @return userdata|nil
local function watch_dir(dir, ws_name)
  local handle = vim.uv.new_fs_event()
  if not handle then
    require("obsidian-tasks.log").warn("watcher: vim.uv.new_fs_event() returned nil for " .. tostring(dir))
    return nil
  end

  local started, start_err = pcall(function()
    handle:start(dir, {}, function(err_msg, filename, _events)
      -- Errors from the OS (e.g. inotify watch removed) are non-fatal.
      if err_msg then
        return
      end

      vim.schedule(function()
        local full_path = filename and (dir .. "/" .. filename) or dir

        -- Rename events may signal a newly-created subdirectory.
        -- Check with fs_stat and, if it is a directory, start watching it.
        if filename then
          local stat = vim.uv.fs_stat(full_path)
          if stat and stat.type == "directory" then
            local new_h = watch_dir(full_path, ws_name)
            if new_h and M._handles[ws_name] then
              M._handles[ws_name][#M._handles[ws_name] + 1] = new_h
            end
            return
          end
        end

        -- Only markdown files need index refresh.
        if not (type(full_path) == "string" and full_path:match("%.md$")) then
          return
        end

        local opts = require("obsidian-tasks").opts
        local delay = (opts and opts.watcher_debounce_ms) or 300
        schedule_flush(ws_name, full_path, delay)
      end)
    end)
  end)

  if not started then
    require("obsidian-tasks.log").warn("watcher: failed to watch " .. tostring(dir) .. ": " .. tostring(start_err))
    pcall(function()
      handle:close()
    end)
    return nil
  end

  return handle
end

-- ── Public API ─────────────────────────────────────────────────────────────────

--- Start per-directory watchers for *workspace*.
---
--- Performs a synchronous recursive directory walk under `workspace.root` and
--- creates one `vim.uv.new_fs_event()` per directory.  Errors at any stage
--- (EACCES, ENOSPC for inotify watches, invalid root, …) are logged and the
--- affected directory is skipped — the plugin continues without full coverage
--- rather than failing loudly.
---
--- @param workspace table  workspace object with `.root` (string) and `.name` (string)
function M.start(workspace)
  -- Always stop existing watchers for this workspace first to avoid leaks.
  M.stop(workspace)

  local log = require("obsidian-tasks.log")
  local root = workspace and workspace.root

  if type(root) ~= "string" or root == "" then
    log.warn("watcher: invalid workspace root, watcher disabled")
    return
  end

  -- Enumerate directories; degrade gracefully if enumeration fails.
  local dirs
  local ok, err = pcall(function()
    dirs = collect_dirs(root)
  end)
  if not ok then
    log.warn("watcher: directory enumeration failed: " .. tostring(err))
    return
  end

  -- Create handles for each directory.
  local handles = {}
  for _, dir in ipairs(dirs) do
    local h = watch_dir(dir, workspace.name)
    if h then
      handles[#handles + 1] = h
    end
  end

  M._handles[workspace.name] = handles
end

--- Stop all watchers for *workspace* and cancel any pending debounce timer.
---
--- @param workspace table  workspace object with `.name` (string)
function M.stop(workspace)
  local name = workspace and workspace.name
  if not name then
    return
  end

  -- Close all libuv handles.
  local handles = M._handles[name]
  if handles then
    for _, h in ipairs(handles) do
      pcall(function()
        if not h:is_closing() then
          h:stop()
          h:close()
        end
      end)
    end
    M._handles[name] = nil
  end

  -- Cancel any pending debounce timer.
  local d = _debounce[name]
  if d then
    if d.timer then
      pcall(function()
        d.timer:stop()
        d.timer:close()
      end)
    end
    _debounce[name] = nil
  end
end

--- Register the autocmd listener and optionally start watching the current
--- workspace immediately.  Must be called from `init.setup()`.
---
--- Subscribes to `User:ObsidianWorkpspaceSet` (note: typo is intentional —
--- it matches the event name emitted by obsidian.nvim).
function M.setup()
  local group = vim.api.nvim_create_augroup("obsidian_tasks_watcher", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    -- Intentional typo: matches obsidian.nvim's actual event name.
    pattern = "ObsidianWorkpspaceSet",
    callback = function(ev)
      local new_ws = (type(ev.data) == "table" and ev.data.workspace)
        or (type(Obsidian) == "table" and Obsidian.workspace)
      if not new_ws then
        return
      end

      -- Stop all current per-workspace watchers.
      for ws_name in pairs(M._handles) do
        M.stop({ name = ws_name })
      end

      M.start(new_ws)
    end,
  })

  -- Drain deferred refreshes when cursor moves: if the cursor has left the
  -- render region of a deferred buffer, refresh it now.
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    callback = function()
      local cur_bufnr = vim.api.nvim_get_current_buf()
      if not _deferred[cur_bufnr] then
        return
      end
      -- Cursor has moved — re-check whether it is still inside a render region.
      if not _cursor_in_render_region(cur_bufnr) then
        _deferred[cur_bufnr] = nil
        if vim.api.nvim_buf_is_valid(cur_bufnr) then
          require("obsidian-tasks.render").refresh_buffer(cur_bufnr)
        end
      end
    end,
  })

  -- Also drain on write: the buffer write event guarantees the cursor left
  -- or that the user explicitly saved — safe to refresh immediately.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function()
      local cur_bufnr = vim.api.nvim_get_current_buf()
      if _deferred[cur_bufnr] then
        _deferred[cur_bufnr] = nil
        if vim.api.nvim_buf_is_valid(cur_bufnr) then
          require("obsidian-tasks.render").refresh_buffer(cur_bufnr)
        end
      end
    end,
  })

  -- If obsidian.nvim is already initialised when our plugin sets up, start
  -- watching immediately (defer so callers finish their own setup first).
  if type(Obsidian) == "table" and Obsidian.workspace then
    vim.schedule(function()
      M.start(Obsidian.workspace)
    end)
  end
end

-- ── Test hooks ─────────────────────────────────────────────────────────────────
-- Exposed for unit tests; not part of the public API.

--- Direct access to the debounce state table (for tests).
--- @return table
function M._debounce_state()
  return _debounce
end

--- Directly push a path into the debounce queue (for tests that don't want
--- to mock libuv handles).
--- @param ws_name  string
--- @param path     string
--- @param delay_ms number
function M._push_event(ws_name, path, delay_ms)
  schedule_flush(ws_name, path, delay_ms)
end

--- Direct access to the deferred-refresh set (for tests).
--- Returns the live table — callers may mutate it to simulate state.
--- @return table  { [bufnr] = true, ... }
function M._deferred_state()
  return _deferred
end

--- Reset the deferred-refresh set (for tests).
function M._reset_deferred()
  _deferred = {}
end

return M
