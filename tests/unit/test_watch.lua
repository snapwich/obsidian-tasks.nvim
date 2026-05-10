-- tests/unit/test_watch.lua
-- Unit tests for index/watch.lua.
--
-- Strategy:
--   * Debounce-queue logic tested via M._push_event (bypasses libuv handles).
--   * vim.defer_fn is overridden so flush fns can be triggered synchronously.
--   * vim.schedule is overridden to run callbacks immediately.
--   * index.refresh_file is stubbed; call count asserts debounce coalescing.
--   * Graceful degradation: mock vim.uv.new_fs_event → failure paths.
--   * Workspace-switch autocmd tested with nvim_exec_autocmds.

local T = MiniTest.new_set()

-- ── helpers ────────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Install *mock* at *name* in package.loaded; return a cleanup fn.
local function install_mock(name, mock)
  local prev = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = prev
  end
end

--- Force a fresh require (clears module cache).
local function fresh(mod)
  package.loaded[mod] = nil
  return require(mod)
end

--- Run *fn* with vim.schedule replaced by a synchronous version that executes
--- callbacks immediately.  Original is always restored.
local function with_sync_schedule(fn)
  local orig = vim.schedule
  vim.schedule = function(cb)
    cb()
  end
  local ok, err = pcall(fn)
  vim.schedule = orig
  if not ok then
    error(err, 2)
  end
end

--- Run *fn* with vim.defer_fn replaced by a version that captures scheduled
--- functions into *queue* rather than starting a real timer.  Each entry in
--- *queue* is { fn = <function>, delay = <ms> }.  The returned drain() flushes
--- all queued fns synchronously.
---
--- @param fn    fun(queue: table, drain: fun())
local function with_captured_defer(fn)
  local queue = {}
  local orig = vim.defer_fn

  vim.defer_fn = function(cb, delay)
    local entry = { fn = cb, delay = delay }
    queue[#queue + 1] = entry
    -- Return a fake timer handle (stop/close are no-ops)
    return setmetatable({}, {
      __index = function(_, k)
        if k == "stop" or k == "close" then
          return function() end
        end
        return nil
      end,
    })
  end

  local function drain()
    while #queue > 0 do
      local item = table.remove(queue, 1)
      item.fn()
    end
  end

  local ok, err = pcall(fn, queue, drain)
  vim.defer_fn = orig
  if not ok then
    error(err, 2)
  end
end

--- Build a minimal fake workspace.
local function make_ws(name, root)
  return { name = name or "test", root = root or "/vault/test" }
end

-- ── Debounce: single event fires refresh once ──────────────────────────────────

T["debounce: single event triggers one refresh_file call"] = function()
  local refresh_calls = {}
  local r1 = install_mock("obsidian-tasks.index", {
    refresh_file = function(p)
      refresh_calls[#refresh_calls + 1] = p
    end,
  })
  local r2 = install_mock("obsidian-tasks", {
    opts = { watcher_debounce_ms = 300 },
  })

  local watch = fresh("obsidian-tasks.index.watch")

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      watch._push_event("ws1", "/vault/note.md", 300)
    end)

    eq(#refresh_calls, 0) -- not fired yet (timer pending)

    drain() -- flush the queued timer fn

    eq(#refresh_calls, 1)
    eq(refresh_calls[1], "/vault/note.md")
  end)

  r1()
  r2()
end

-- ── Debounce: multiple events within window coalesce into one flush ─────────────

T["debounce: 5 rapid events coalesce into 1 refresh per path"] = function()
  local refresh_calls = {}
  local r1 = install_mock("obsidian-tasks.index", {
    refresh_file = function(p)
      refresh_calls[#refresh_calls + 1] = p
    end,
  })
  local r2 = install_mock("obsidian-tasks", {
    opts = { watcher_debounce_ms = 300 },
  })

  local watch = fresh("obsidian-tasks.index.watch")

  with_captured_defer(function(queue, drain)
    with_sync_schedule(function()
      -- 5 rapid events on the SAME path
      for _ = 1, 5 do
        watch._push_event("ws1", "/vault/note.md", 300)
      end
    end)

    -- 5 pushes → 5 timers queued (each cancels the previous via gen counter)
    -- Only the last flush should process paths; earlier ones bail via gen check.
    drain() -- drain all 5 queued fns

    -- Despite 5 events, refresh_file should be called exactly once
    eq(#refresh_calls, 1)
    eq(refresh_calls[1], "/vault/note.md")

    -- The queue should also be empty now (paths were drained)
    local state = watch._debounce_state()
    eq(next(state["ws1"].paths), nil)
  end)

  r1()
  r2()
end

-- ── Debounce: multiple distinct paths each get refresh_file ────────────────────

T["debounce: distinct paths each produce a refresh_file call"] = function()
  local refresh_calls = {}
  local r1 = install_mock("obsidian-tasks.index", {
    refresh_file = function(p)
      refresh_calls[#refresh_calls + 1] = p
    end,
  })
  local r2 = install_mock("obsidian-tasks", {
    opts = { watcher_debounce_ms = 300 },
  })

  local watch = fresh("obsidian-tasks.index.watch")

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      watch._push_event("ws1", "/vault/a.md", 300)
      watch._push_event("ws1", "/vault/b.md", 300)
      watch._push_event("ws1", "/vault/a.md", 300) -- duplicate of a.md
    end)

    drain()

    -- a.md and b.md each appear once despite 3 events
    table.sort(refresh_calls)
    eq(#refresh_calls, 2)
    eq(refresh_calls[1], "/vault/a.md")
    eq(refresh_calls[2], "/vault/b.md")
  end)

  r1()
  r2()
end

-- ── Debounce: ObsidianTasksFilesChanged event fires after flush ─────────────────

T["debounce: ObsidianTasksFilesChanged autocmd fires after flush"] = function()
  local r1 = install_mock("obsidian-tasks.index", {
    refresh_file = function(_) end,
  })
  local r2 = install_mock("obsidian-tasks", {
    opts = { watcher_debounce_ms = 100 },
  })

  local watch = fresh("obsidian-tasks.index.watch")

  local received_paths = nil
  local augroup = vim.api.nvim_create_augroup("test_watch_event", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = augroup,
    pattern = "ObsidianTasksFilesChanged",
    callback = function(ev)
      received_paths = ev.data and ev.data.paths
    end,
  })

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      watch._push_event("ws_event_test", "/vault/changed.md", 100)
    end)

    drain()

    eq(type(received_paths), "table")
    eq(#received_paths, 1)
    eq(received_paths[1], "/vault/changed.md")
  end)

  vim.api.nvim_del_augroup_by_id(augroup)
  r1()
  r2()
end

-- ── Graceful degradation: new_fs_event returns nil ─────────────────────────────

T["graceful degradation: new_fs_event returns nil → warns and continues"] = function()
  local warn_msgs = {}
  local r_log = install_mock("obsidian-tasks.log", {
    warn = function(msg)
      warn_msgs[#warn_msgs + 1] = msg
    end,
  })

  -- Stub fs_scandir to return a scan that yields no entries (empty root)
  local orig_fs_scandir = vim.uv.fs_scandir
  vim.uv.fs_scandir = function(_)
    return nil
  end

  local orig_fs_event = vim.uv.new_fs_event
  vim.uv.new_fs_event = function()
    return nil -- simulate inotify exhaustion or permission denied
  end

  local watch = fresh("obsidian-tasks.index.watch")
  local ws = make_ws("degrade_ws", "/vault/degrade")

  -- Should not throw
  local ok, err = pcall(function()
    watch.start(ws)
  end)

  vim.uv.new_fs_event = orig_fs_event
  vim.uv.fs_scandir = orig_fs_scandir
  r_log()

  eq(ok, true)
  -- A warning should have been emitted (new_fs_event returned nil)
  local found_warn = false
  for _, msg in ipairs(warn_msgs) do
    if msg:match("new_fs_event") or msg:match("watcher") then
      found_warn = true
      break
    end
  end
  eq(found_warn, true)
end

-- ── Graceful degradation: handle:start throws ──────────────────────────────────

T["graceful degradation: handle:start raises error → warns and continues"] = function()
  local warn_msgs = {}
  local r_log = install_mock("obsidian-tasks.log", {
    warn = function(msg)
      warn_msgs[#warn_msgs + 1] = msg
    end,
  })

  local orig_fs_scandir = vim.uv.fs_scandir
  vim.uv.fs_scandir = function(_)
    return nil
  end

  local orig_fs_event = vim.uv.new_fs_event
  vim.uv.new_fs_event = function()
    -- Return a fake handle whose :start() throws
    local fake = {}
    function fake:start(_path, _flags, _cb)
      error("ENOSPC: no inotify watches available")
    end
    function fake:close() end
    function fake:is_closing()
      return false
    end
    return fake
  end

  local watch = fresh("obsidian-tasks.index.watch")
  local ws = make_ws("enospc_ws", "/vault/enospc")

  local ok, err = pcall(function()
    watch.start(ws)
  end)

  vim.uv.new_fs_event = orig_fs_event
  vim.uv.fs_scandir = orig_fs_scandir
  r_log()

  eq(ok, true)

  -- Warning should mention the failure
  local found = false
  for _, msg in ipairs(warn_msgs) do
    if msg:match("watcher") or msg:match("ENOSPC") or msg:match("failed") then
      found = true
      break
    end
  end
  eq(found, true)
end

-- ── M.stop: cancels pending timer and clears handles ───────────────────────────

T["stop: clears handles and cancels pending debounce timer"] = function()
  local refresh_calls = {}
  local r1 = install_mock("obsidian-tasks.index", {
    refresh_file = function(p)
      refresh_calls[#refresh_calls + 1] = p
    end,
  })
  local r2 = install_mock("obsidian-tasks", {
    opts = { watcher_debounce_ms = 300 },
  })

  local watch = fresh("obsidian-tasks.index.watch")
  local ws = make_ws("stop_ws", "/vault/stop")

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      watch._push_event("stop_ws", "/vault/stop/note.md", 300)
    end)

    -- Stop before drain → debounce state is cleared
    watch.stop(ws)

    -- The deferred flush still runs (timer was fake), but gen check bails it out.
    drain()

    -- refresh_file must NOT have been called after stop
    eq(#refresh_calls, 0)

    -- Debounce state for this workspace should be gone
    local state = watch._debounce_state()
    eq(state["stop_ws"], nil)
  end)

  r1()
  r2()
end

-- ── M.setup: wires ObsidianWorkpspaceSet autocmd ───────────────────────────────

T["setup: ObsidianWorkpspaceSet autocmd fires M.start for new workspace"] = function()
  local r_log = install_mock("obsidian-tasks.log", {
    warn = function(_) end,
  })

  -- Prevent real collect_dirs + handle creation by stubbing fs_scandir
  local orig_fs_scandir = vim.uv.fs_scandir
  vim.uv.fs_scandir = function(_)
    return nil -- no subdirectories
  end

  -- Stub new_fs_event → fake handle that does nothing
  local orig_fs_event = vim.uv.new_fs_event
  local created_handles = {}
  vim.uv.new_fs_event = function()
    local h = {}
    created_handles[#created_handles + 1] = h
    function h:start(_path, _flags, _cb) end
    function h:stop() end
    function h:close() end
    function h:is_closing()
      return false
    end
    return h
  end

  -- Clear _G.Obsidian so setup() does not trigger immediate start
  local orig_obsidian = _G.Obsidian
  _G.Obsidian = nil

  local watch = fresh("obsidian-tasks.index.watch")

  -- Call setup to register the autocmd
  watch.setup()

  -- Reset handles so we can tell when start() is called
  watch._handles = {}
  created_handles = {}

  -- Fire the workspace-switch event
  local ws = make_ws("new_ws", "/vault/new")
  vim.api.nvim_exec_autocmds("User", {
    pattern = "ObsidianWorkpspaceSet",
    data = { workspace = ws },
  })

  -- After the autocmd, handles should have been created for new_ws
  -- (one handle for the root dir itself, since fs_scandir returns nil for children)
  eq(type(watch._handles["new_ws"]), "table")

  _G.Obsidian = orig_obsidian
  vim.uv.new_fs_event = orig_fs_event
  vim.uv.fs_scandir = orig_fs_scandir
  r_log()
end

-- ── init.setup wires watcher when opts.watcher = true ─────────────────────────

T["init.setup: watcher started when opts.watcher=true"] = function()
  local watch_setup_called = false
  local r_watch = install_mock("obsidian-tasks.index.watch", {
    setup = function()
      watch_setup_called = true
    end,
  })
  -- Stub other deps so setup() doesn't blow up
  local r_config = install_mock("obsidian-tasks.config", {
    merge = function(_)
      return { watcher = true, statuses = nil }
    end,
  })
  local r_status = install_mock("obsidian-tasks.task.status", {
    merge = function(_) end,
  })
  local r_autocmds = install_mock("obsidian-tasks.autocmds", {
    setup = function(_) end,
  })
  local r_cmd = install_mock("obsidian-tasks.cmd", {
    setup = function() end,
  })

  local ot = fresh("obsidian-tasks")
  ot.setup({ watcher = true })

  eq(watch_setup_called, true)

  r_watch()
  r_config()
  r_status()
  r_autocmds()
  r_cmd()
end

T["init.setup: watcher NOT started when opts.watcher=false"] = function()
  local watch_setup_called = false
  local r_watch = install_mock("obsidian-tasks.index.watch", {
    setup = function()
      watch_setup_called = true
    end,
  })
  local r_config = install_mock("obsidian-tasks.config", {
    merge = function(_)
      return { watcher = false, statuses = nil }
    end,
  })
  local r_status = install_mock("obsidian-tasks.task.status", {
    merge = function(_) end,
  })
  local r_autocmds = install_mock("obsidian-tasks.autocmds", {
    setup = function(_) end,
  })
  local r_cmd = install_mock("obsidian-tasks.cmd", {
    setup = function() end,
  })

  local ot = fresh("obsidian-tasks")
  ot.setup({ watcher = false })

  eq(watch_setup_called, false)

  r_watch()
  r_config()
  r_status()
  r_autocmds()
  r_cmd()
end

return T
