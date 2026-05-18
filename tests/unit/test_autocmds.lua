-- tests/unit/test_autocmds.lua
-- Unit tests for lua/obsidian-tasks/autocmds.lua.
--
-- All render and obsidian-util calls are mocked; autocmds are wired via
-- autocmds.setup() and triggered with nvim_exec_autocmds.
--
-- F4 edit-through tests (ObsidianNoteWritePre diff+patch+strip) have been
-- removed along with the F4 implementation.

local T = MiniTest.new_set()

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Unique name counter — prevents "Buffer with this name already exists" when
--- a prior test fails before its cleanup.
local _name_seq = 0
local function unique_md_path(prefix)
  _name_seq = _name_seq + 1
  return (prefix or "/vault/test_") .. _name_seq .. ".md"
end

--- Install *mock* at *name* in package.loaded; return a cleanup function.
--- @param name string
--- @param mock table
--- @return fun()
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Force-reload autocmds module so each test starts clean.
--- @return table
local function get_autocmds()
  package.loaded["obsidian-tasks.autocmds"] = nil
  return require("obsidian-tasks.autocmds")
end

--- Build a render mock that records calls and tracks _buffer_state.
--- @param initial_state table?  initial _buffer_state (defaults to {})
--- @return table
local function make_render_mock(initial_state)
  local m = {
    _buffer_state = initial_state or {},
    -- Mirror the real render/init.lua module shape so BufDelete autocmds
    -- that clear linger state don't hit nil-index errors.
    _lingers = {},
    _pending_lingers = {},
    render_calls = {},
    refresh_calls = {},
    rerender_calls = {},
    clear_calls = {},
    _has_tasks = true,
  }

  function m.has_tasks_block(_bufnr)
    return m._has_tasks
  end

  function m.render_buffer(bufnr, ws)
    m.render_calls[#m.render_calls + 1] = { bufnr = bufnr, ws = ws }
    m._buffer_state[bufnr] = {}
  end

  function m.refresh_buffer(bufnr, ws)
    m.refresh_calls[#m.refresh_calls + 1] = { bufnr = bufnr, ws = ws }
  end

  function m.rerender_buffer(bufnr, ws)
    m.rerender_calls[#m.rerender_calls + 1] = { bufnr = bufnr, ws = ws }
  end

  function m.clear_buffer(bufnr)
    m.clear_calls[#m.clear_calls + 1] = { bufnr = bufnr }
    m._buffer_state[bufnr] = nil
  end

  function m.configure(_opts) end

  return m
end

--- Build an obsidian-util mock whose workspace_for_path returns *ws*.
--- @param ws table|nil
--- @return table
local function make_obsidian_mock(ws)
  return {
    workspace_for_path = function(_path)
      return ws
    end,
  }
end

--- Override vim.schedule to invoke callbacks immediately.
--- The original is restored even if *fn* throws.
--- @param fn fun()
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

-- ── BufReadPost: auto_render=false ────────────────────────────────────────────

T["BufReadPost: no render when auto_render=false"] = function()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = false })

  with_sync_schedule(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, unique_md_path())
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    eq(#render.render_calls, 0)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  r1()
  r2()
end

-- ── BufReadPost: non-vault file ───────────────────────────────────────────────

T["BufReadPost: no render when workspace is nil (non-vault file)"] = function()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock(nil) -- not in any vault
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  with_sync_schedule(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, unique_md_path("/outside/note_"))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    eq(#render.render_calls, 0)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  r1()
  r2()
end

-- ── BufReadPost: no tasks block ───────────────────────────────────────────────

T["BufReadPost: no render when buffer has no tasks block"] = function()
  local render = make_render_mock()
  render._has_tasks = false
  local obsidian = make_obsidian_mock({ root = "/vault" })
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  with_sync_schedule(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, unique_md_path())
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# plain note", "- [ ] task" })
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    eq(#render.render_calls, 0)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  r1()
  r2()
end

-- ── BufReadPost: positive path ────────────────────────────────────────────────

T["BufReadPost: renders when auto_render=true, vault found, tasks block present"] = function()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  with_sync_schedule(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, unique_md_path())
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    eq(#render.render_calls, 1)
    eq(render.render_calls[1].bufnr, bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  r1()
  r2()
end

T["BufReadPost: workspace object is passed to render_buffer"] = function()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  with_sync_schedule(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, unique_md_path())
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    MiniTest.expect.equality(render.render_calls[1].ws, ws)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  r1()
  r2()
end

-- ── BufDelete: state cleanup ──────────────────────────────────────────────────

T["BufDelete: calls clear_buffer for the deleted buffer"] = function()
  local render = make_render_mock()
  local r1 = install_mock("obsidian-tasks.render", render)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Simulate an active render for this buffer.
  render._buffer_state[bufnr] = { {} }

  -- Fire BufDelete manually (without actually deleting the buffer — avoids
  -- post-delete API edge cases with scratch buffers).
  vim.api.nvim_exec_autocmds("BufDelete", { buffer = bufnr })

  eq(#render.clear_calls, 1)
  eq(render.clear_calls[1].bufnr, bufnr)
  -- State must be nil after clear.
  eq(render._buffer_state[bufnr], nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
end

T["BufDelete: clears state even when buffer had no prior render"] = function()
  local render = make_render_mock()
  local r1 = install_mock("obsidian-tasks.render", render)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  -- No render state — clear_buffer is still called (it is a no-op on nil state).
  vim.api.nvim_exec_autocmds("BufDelete", { buffer = bufnr })

  eq(#render.clear_calls, 1)
  eq(render.clear_calls[1].bufnr, bufnr)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
end

-- ── BufDelete: no longer clears _pending_rerender (F4 removed) ───────────────

T["BufDelete: no crash when fired (F4 pending_rerender tracking removed)"] = function()
  local render = make_render_mock()
  local r1 = install_mock("obsidian-tasks.render", render)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)

  -- Should not error even though there is no pending_rerender table.
  MiniTest.expect.no_error(function()
    vim.api.nvim_exec_autocmds("BufDelete", { buffer = bufnr })
  end)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
end

-- ── BufWritePost: refresh on save ────────────────────────────────────────────

T["BufWritePost: refreshes buffer with active render"] = function()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  -- Mark as having an active render.
  render._buffer_state[bufnr] = { {} }

  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })

  -- BufWritePost now calls rerender_buffer (fold-state-preserving re-render).
  eq(#render.rerender_calls, 1)
  eq(render.rerender_calls[1].bufnr, bufnr)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

T["BufWritePost: skips buffer without active render"] = function()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  -- No render state.

  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })

  eq(#render.rerender_calls, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

T["BufWritePost: skips when workspace is nil (non-vault file)"] = function()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock(nil)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path("/outside/note_"))
  render._buffer_state[bufnr] = { {} }

  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })

  eq(#render.rerender_calls, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

-- ── FocusGained: refresh visible renders ──────────────────────────────────────

T["FocusGained: refreshes visible vault md buffers with active render"] = function()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  -- Create a buffer, display it in the current window, mark render active.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  render._buffer_state[bufnr] = { {} }

  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)

  vim.api.nvim_exec_autocmds("FocusGained", { pattern = "*" })

  -- Restore original buffer before assertions.
  vim.api.nvim_set_current_buf(orig_buf)

  -- FocusGained now calls rerender_buffer (fold-state-preserving re-render).
  local found = false
  for _, c in ipairs(render.rerender_calls) do
    if c.bufnr == bufnr then
      found = true
    end
  end
  MiniTest.expect.equality(found, true)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

T["FocusGained: skips buffer without active render"] = function()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  -- No render._buffer_state[bufnr].

  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)

  vim.api.nvim_exec_autocmds("FocusGained", { pattern = "*" })

  vim.api.nvim_set_current_buf(orig_buf)

  -- No rerender should have been called for our buffer.
  local found = false
  for _, c in ipairs(render.rerender_calls) do
    if c.bufnr == bufnr then
      found = true
    end
  end
  MiniTest.expect.equality(found, false)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

T["FocusGained: skips non-vault buffer even with active render"] = function()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock(nil) -- not in vault
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path("/outside/note_"))
  render._buffer_state[bufnr] = { {} }

  local orig_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_set_current_buf(bufnr)

  vim.api.nvim_exec_autocmds("FocusGained", { pattern = "*" })

  vim.api.nvim_set_current_buf(orig_buf)

  local found = false
  for _, c in ipairs(render.rerender_calls) do
    if c.bufnr == bufnr then
      found = true
    end
  end
  MiniTest.expect.equality(found, false)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

-- ── Augroup re-setup ──────────────────────────────────────────────────────────

T["setup: re-calling clears previous autocmds"] = function()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })
  local r1 = install_mock("obsidian-tasks.render", render)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  -- First setup with auto_render=true.
  autocmds.setup({ auto_render = true })
  -- Re-setup with auto_render=false — clears the previous augroup.
  autocmds.setup({ auto_render = false })

  with_sync_schedule(function()
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, unique_md_path())
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    vim.api.nvim_exec_autocmds("BufReadPost", { buffer = bufnr })
    -- auto_render=false wins (previous auto_render=true autocmds were cleared).
    eq(#render.render_calls, 0)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  r1()
  r2()
end

return T
