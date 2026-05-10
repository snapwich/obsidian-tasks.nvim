-- tests/integration/test_watcher.lua
-- Integration tests for the per-workspace libuv file watcher (F7).
--
-- Uses REAL vim.uv.fs_event handles against a tmpdir vault.  The tests are
-- kept synchronous by overriding vim.schedule (to run callbacks immediately)
-- and vim.defer_fn (to capture debounce callbacks for manual drain), then
-- pumping the libuv event loop via vim.uv.run("nowait") + vim.uv.sleep.
-- This avoids the mini.test concurrency pitfall where vim.wait() would cause
-- subsequent test cases (scheduled via vim.schedule) to interleave.
--
-- Why not vim.wait:
--   mini.test pre-queues all test cases with vim.schedule.  vim.wait()
--   processes ALL pending vim.schedule callbacks, so later test cases start
--   running while the current test is still waiting — test state gets clobbered.
--   Using vim.uv.run("nowait") only advances the libuv I/O loop (fs_event,
--   timers) without draining vim.schedule, so no cross-test interleaving.
--
-- Scenarios:
--   S1  external write → real fs_event fires, debounce flush, render refresh
--   S2  watcher=false  → external write → no refresh
--   S3  debounce       → 5 rapid writes coalesce into exactly 1 refresh
--   S4  vault switch   → old watcher stopped, new watcher started
--   S5  graceful degrade → new_fs_event failure → setup OK, warning logged
--
-- Feature verification (full pipeline):
--   External file change → index update → visible render refresh [integration]

local T = MiniTest.new_set()

local uv = vim.uv

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Swap package.loaded[name] for mock; return a cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Force a fresh require (clears module cache entry first).
local function fresh(mod)
  package.loaded[mod] = nil
  return require(mod)
end

--- Write *content* to *path* via libuv (external write, bypasses Neovim buffers).
--- This mimics what obsidian desktop or a git pull would do to vault files.
local function fs_write_file(path, content)
  local fd = uv.fs_open(path, "w", 420) -- 0644
  if not fd then
    error("fs_write_file: could not open " .. tostring(path))
  end
  uv.fs_write(fd, content, -1)
  uv.fs_close(fd)
end

--- Create a fresh tmpdir and return its absolute path.
local function make_tmpdir()
  local p = vim.fn.tempname()
  vim.fn.mkdir(p, "p")
  return p
end

--- Build a minimal workspace table.
local function make_ws(name, root)
  return { name = name, root = root }
end

--- Run *fn* with vim.schedule replaced by a synchronous shim that runs
--- callbacks immediately.  Mirrors the helper in test_watch.lua (unit).
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

--- Run *fn* with vim.defer_fn replaced by a capture-only shim.  Captured
--- callbacks are stored in the returned queue; drain() runs them all
--- synchronously.  Mirrors the helper in test_watch.lua (unit).
---
--- @param fn fun(queue: table, drain: fun())
local function with_captured_defer(fn)
  local queue = {}
  local orig = vim.defer_fn

  vim.defer_fn = function(cb, _delay)
    queue[#queue + 1] = { fn = cb }
    -- Return a fake timer handle that watch.lua calls :stop() / :close() on.
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

--- Pump the libuv event loop *n* times with short sleeps between iterations.
--- This advances libuv I/O (fs_event callbacks, file-stat, etc.) without
--- draining vim.schedule — so other test cases remain queued and do not run.
---
--- After the OS delivers a file-change notification (inotify/kqueue), calling
--- this allows the fs_event callback to fire.  Combined with with_sync_schedule,
--- the callback's vim.schedule work executes immediately during the pump.
---
--- @param n        integer  number of loop iterations (default 3)
--- @param sleep_ms integer  ms to sleep between iterations (default 20)
local function pump_uv(n, sleep_ms)
  n = n or 3
  sleep_ms = sleep_ms or 20
  for _ = 1, n do
    uv.sleep(sleep_ms)
    uv.run("nowait")
  end
end

--- Install the standard mocks needed by integration watcher tests and return
--- a cleanup function plus the refresh_buf_calls tracking table.
---
--- Uses the *real* obsidian-tasks.index module (reset to empty state) so
--- index.refresh_file actually reads disk and reverse_index() is real.
---
--- Mocked modules:
---   obsidian-tasks           → { opts = { watcher_debounce_ms = N } }
---   obsidian-tasks.index.ignore → always not-ignored (no obsidian.nvim dep)
---   obsidian-tasks.render    → stub with refresh_buffer call counter
---
--- Also stubs nvim_buf_is_valid and nvim_get_current_buf so _refresh_or_defer
--- always takes the "refresh now" path rather than deferring to cursor-move.
---
--- @param debounce_ms   number     debounce window (used in opts mock)
--- @param bufnr         integer|nil scratch buf to register in reverse index
--- @param source_paths  string[]|nil source paths to associate with bufnr
--- @return fun()   cleanup — call after test and before assertions
--- @return table   refresh_buf_calls — list of bufnrs passed to refresh_buffer
local function setup_watch_mocks(debounce_ms, bufnr, source_paths)
  debounce_ms = debounce_ms or 100

  -- Reset real index to a clean state.
  local index = require("obsidian-tasks.index")
  index._reset()

  -- Pre-populate reverse index: when index.reverse_index(path) is called
  -- inside the debounce flush, it will return { bufnr }.
  if bufnr and source_paths then
    local paths_set = {}
    for _, p in ipairs(source_paths) do
      paths_set[p] = true
    end
    index.set_render_paths(bufnr, paths_set)
  end

  local refresh_buf_calls = {}

  local r_opts = install_mock("obsidian-tasks", {
    opts = { watcher_debounce_ms = debounce_ms },
  })
  local r_ignore = install_mock("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })
  local r_render = install_mock("obsidian-tasks.render", {
    _buffer_state = {}, -- empty → cursor never in render region
    refresh_buffer = function(b)
      refresh_buf_calls[#refresh_buf_calls + 1] = b
    end,
  })

  -- nvim_buf_is_valid → always true to prevent early bail in _refresh_or_defer.
  local orig_valid = vim.api.nvim_buf_is_valid
  vim.api.nvim_buf_is_valid = function(_)
    return true
  end
  -- Current buf is always different from our test bufnr so the
  -- cursor-in-render-region check returns false and refresh fires immediately.
  local orig_cur_buf = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return 99999
  end

  local function cleanup()
    r_opts()
    r_ignore()
    r_render()
    vim.api.nvim_buf_is_valid = orig_valid
    vim.api.nvim_get_current_buf = orig_cur_buf
    index._reset()
  end

  return cleanup, refresh_buf_calls
end

-- ── S1: external write → render refreshes (full pipeline) ────────────────────
--
-- Full pipeline verified:
--   file write → real libuv fs_event → vim.schedule (overridden) →
--   schedule_flush → vim.defer_fn (captured) → drain →
--   index.refresh_file (real disk read) → reverse_index → render.refresh_buffer
--
-- "Real fs_event": vim.uv.new_fs_event() is NOT mocked; it watches the real
-- tmpdir.  Only the Neovim scheduler is overridden to make the test synchronous.

T["S1: external write → real fs_event fires → render refresh"] = function()
  local DEBOUNCE = 100 -- ms (used in opts mock; actual timing is bypassed by captures)
  local tmpdir = make_tmpdir()
  local src = tmpdir .. "/note.md"

  -- Create source file with initial content.
  fs_write_file(src, "# Note\n- [ ] Initial task\n")

  local bufnr = vim.api.nvim_create_buf(false, true)
  local cleanup, refresh_calls = setup_watch_mocks(DEBOUNCE, bufnr, { src })

  local watch = fresh("obsidian-tasks.index.watch")
  local ws = make_ws("s1_ws", tmpdir)

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      watch.start(ws) -- real fs_event handles registered
      uv.sleep(50) -- allow OS to register the inotify watch

      -- External write: triggers inotify → libuv queues fs_event callback.
      fs_write_file(src, "# Note\n- [ ] Updated task\n")

      -- Pump libuv: fs_event fires, vim.schedule runs immediately,
      -- schedule_flush queues a vim.defer_fn callback.
      pump_uv(3, 30)
      -- NOTE: do NOT call watch.stop() here — stop() clears _debounce state,
      -- which would cause the gen-check in the flush to bail.
    end)

    -- Drain the captured debounce flush: calls index.refresh_file,
    -- reverse_index → [bufnr], then render.refresh_buffer(bufnr).
    -- Must happen BEFORE watch.stop() so _debounce state is intact.
    drain()
  end)

  -- Stop after drain so debounce state was available for the flush.
  watch.stop(ws)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(tmpdir, "rf")

  -- Full-pipeline assertion: refresh was called for the correct buffer.
  MiniTest.expect.equality(#refresh_calls >= 1, true)
  eq(refresh_calls[1], bufnr)
end

-- ── S2: opts.watcher = false → no refresh fires ───────────────────────────────
--
-- When the watcher is not started, an external write must not reach
-- render.refresh_buffer regardless of how long we wait.

T["S2: watcher disabled → external write → no refresh"] = function()
  local DEBOUNCE = 100
  local tmpdir = make_tmpdir()
  local src = tmpdir .. "/note.md"

  fs_write_file(src, "# Note\n- [ ] Initial\n")

  local bufnr = vim.api.nvim_create_buf(false, true)
  local cleanup, refresh_calls = setup_watch_mocks(DEBOUNCE, bufnr, { src })

  -- Deliberately do NOT call watch.start() — watcher is disabled.
  local watch = fresh("obsidian-tasks.index.watch")
  _ = watch -- available but not started

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      -- External write.
      fs_write_file(src, "# Note\n- [ ] Changed\n")
      -- Pump libuv — no active handle → no fs_event callback fires.
      pump_uv(3, 30)
    end)
    -- Drain captures nothing (no handle was active).
    drain()
  end)

  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(tmpdir, "rf")

  eq(#refresh_calls, 0)
end

-- ── S3: 5 rapid writes coalesce into 1 refresh ────────────────────────────────
--
-- Multiple fs_events for the same file within the debounce window accumulate
-- in the same path set.  The generation counter ensures only the last flush
-- fires; earlier deferred callbacks bail out via the gen check.

T["S3: 5 rapid writes within debounce → exactly 1 refresh"] = function()
  local DEBOUNCE = 100
  local tmpdir = make_tmpdir()
  local src = tmpdir .. "/note.md"

  fs_write_file(src, "# Note\n- [ ] Write 0\n")

  local bufnr = vim.api.nvim_create_buf(false, true)
  local cleanup, refresh_calls = setup_watch_mocks(DEBOUNCE, bufnr, { src })

  local watch = fresh("obsidian-tasks.index.watch")
  local ws = make_ws("s3_ws", tmpdir)

  with_captured_defer(function(_, drain)
    with_sync_schedule(function()
      watch.start(ws)
      uv.sleep(50)

      -- 5 rapid writes in a tight loop.
      -- All inotify events are queued in the fd buffer before we pump libuv.
      for i = 1, 5 do
        fs_write_file(src, "# Note\n- [ ] Write " .. i .. "\n")
      end

      -- Pump once: all ready events fire; each calls schedule_flush with the
      -- same path → 5 deferred callbacks queued, each generation superseding
      -- the previous.
      pump_uv(3, 30)
      -- NOTE: do NOT call watch.stop() here — see S1 comment.
    end)

    -- Drain: callbacks 1-N bail (gen check), only the last flush fires.
    -- Flush: 1 unique path → 1 refresh_file → 1 reverse_index → 1 refresh_buffer.
    drain()
  end)

  -- Stop after drain.
  watch.stop(ws)
  cleanup()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(tmpdir, "rf")

  -- Whether inotify coalesces or not, exactly 1 refresh per path per flush.
  eq(#refresh_calls, 1)
  eq(refresh_calls[1], bufnr)
end

-- ── S4: vault switch — old watcher stops, new watcher starts ──────────────────
--
-- The plugin watches workspace A.  After User:ObsidianWorkpspaceSet fires with
-- workspace B, the A watcher is closed and B is watched instead.
-- Write to B → refresh fires.  Write to A → no refresh.

T["S4: vault switch → B watched, A ignored"] = function()
  local DEBOUNCE = 100
  local tmpdir_a = make_tmpdir()
  local tmpdir_b = make_tmpdir()
  local src_a = tmpdir_a .. "/a.md"
  local src_b = tmpdir_b .. "/b.md"

  fs_write_file(src_a, "# A\n- [ ] Task A\n")
  fs_write_file(src_b, "# B\n- [ ] Task B\n")

  local bufnr_a = vim.api.nvim_create_buf(false, true)
  local bufnr_b = vim.api.nvim_create_buf(false, true)

  -- Setup mocks without pre-registering paths (we do that manually below).
  local cleanup, refresh_calls = setup_watch_mocks(DEBOUNCE, nil, nil)

  -- Register both buffers in the (already-reset) real reverse index.
  local index = require("obsidian-tasks.index")
  index.set_render_paths(bufnr_a, { [src_a] = true })
  index.set_render_paths(bufnr_b, { [src_b] = true })

  local ws_a = make_ws("ws_a_s4", tmpdir_a)
  local ws_b = make_ws("ws_b_s4", tmpdir_b)

  local watch = fresh("obsidian-tasks.index.watch")

  -- Register the ObsidianWorkpspaceSet autocmd.
  -- _G.Obsidian is nil in tests so setup() won't start an immediate watcher.
  local orig_obsidian = _G.Obsidian
  _G.Obsidian = nil
  watch.setup()
  _G.Obsidian = orig_obsidian

  -- ── Phase 1: watch A, then switch to B ──────────────────────────────────

  with_captured_defer(function(_, drain_phase1)
    with_sync_schedule(function()
      watch.start(ws_a) -- real handles for tmpdir_a
      uv.sleep(50)

      -- Switch workspace: autocmd stops A's handles, starts B's handles.
      vim.api.nvim_exec_autocmds("User", {
        pattern = "ObsidianWorkpspaceSet",
        data = { workspace = ws_b },
      })

      uv.sleep(50) -- allow B's inotify watches to register

      -- Write to B → fs_event for ws_b fires.
      fs_write_file(src_b, "# B\n- [ ] Updated B\n")
      pump_uv(3, 30)
    end)
    drain_phase1()
  end)

  local b_refreshed = (function()
    for _, b in ipairs(refresh_calls) do
      if b == bufnr_b then
        return true
      end
    end
    return false
  end)()

  -- ── Phase 2: write to A — no handles → no refresh ───────────────────────

  local snap = #refresh_calls

  with_captured_defer(function(_, drain_phase2)
    with_sync_schedule(function()
      -- A's handles are stopped; writing to tmpdir_a produces no libuv event.
      fs_write_file(src_a, "# A\n- [ ] Updated A\n")
      pump_uv(3, 30)
    end)
    drain_phase2()
  end)

  local a_fired = (function()
    for i = snap + 1, #refresh_calls do
      if refresh_calls[i] == bufnr_a then
        return true
      end
    end
    return false
  end)()

  -- Cleanup.
  watch.stop(ws_b)
  pcall(vim.api.nvim_del_augroup_by_name, "obsidian_tasks_watcher")
  cleanup()
  vim.api.nvim_buf_delete(bufnr_a, { force = true })
  vim.api.nvim_buf_delete(bufnr_b, { force = true })
  vim.fn.delete(tmpdir_a, "rf")
  vim.fn.delete(tmpdir_b, "rf")

  MiniTest.expect.equality(b_refreshed, true)
  MiniTest.expect.equality(a_fired, false)
end

-- ── S5: graceful degradation — fs_event init failure ──────────────────────────
--
-- When vim.uv.new_fs_event() returns nil (inotify exhausted, permission denied,
-- etc.) watch.start() must complete without raising an error and must emit a
-- warning via log.warn.  The plugin continues without file watching.

T["S5: new_fs_event returns nil → setup completes, warning logged"] = function()
  local warn_msgs = {}
  local r_log = install_mock("obsidian-tasks.log", {
    warn = function(msg)
      warn_msgs[#warn_msgs + 1] = msg
    end,
  })

  -- Stub fs_scandir to return nil so collect_dirs returns just [root].
  local orig_scandir = uv.fs_scandir
  uv.fs_scandir = function(_)
    return nil
  end

  -- Stub new_fs_event to simulate resource exhaustion.
  local orig_fs_event = uv.new_fs_event
  uv.new_fs_event = function()
    return nil
  end

  local tmpdir = make_tmpdir()
  local watch = fresh("obsidian-tasks.index.watch")
  local ws = make_ws("s5_ws", tmpdir)

  local ok, err = pcall(function()
    watch.start(ws)
  end)

  -- Restore stubs before assertions.
  uv.new_fs_event = orig_fs_event
  uv.fs_scandir = orig_scandir
  r_log()
  vim.fn.delete(tmpdir, "rf")

  -- watch.start() must not throw.
  MiniTest.expect.equality(ok, true)
  if not ok then
    error(tostring(err))
  end

  -- A warning mentioning the watcher failure must have been emitted.
  local found_warn = false
  for _, msg in ipairs(warn_msgs) do
    if msg:match("new_fs_event") or msg:match("watcher") then
      found_warn = true
      break
    end
  end
  MiniTest.expect.equality(found_warn, true)

  -- Plugin continues: _handles entry exists but is empty (no active handles).
  local handles = watch._handles[ws.name]
  MiniTest.expect.equality(type(handles), "table")
  eq(#handles, 0)
end

return T
