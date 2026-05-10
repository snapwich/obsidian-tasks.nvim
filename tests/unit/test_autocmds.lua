-- tests/unit/test_autocmds.lua
-- Unit tests for lua/obsidian-tasks/autocmds.lua.
--
-- All render and obsidian-util calls are mocked; autocmds are wired via
-- autocmds.setup() and triggered with nvim_exec_autocmds.

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
    render_calls = {},
    refresh_calls = {},
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

  function m.clear_buffer(bufnr)
    m.clear_calls[#m.clear_calls + 1] = { bufnr = bufnr }
    m._buffer_state[bufnr] = nil
  end

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

  eq(#render.refresh_calls, 1)
  eq(render.refresh_calls[1].bufnr, bufnr)

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

  eq(#render.refresh_calls, 0)

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

  eq(#render.refresh_calls, 0)

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

  -- Test buffer must have been refreshed.
  local found = false
  for _, c in ipairs(render.refresh_calls) do
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

  -- No refresh should have been called for our buffer.
  local found = false
  for _, c in ipairs(render.refresh_calls) do
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
  for _, c in ipairs(render.refresh_calls) do
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

-- ── Helpers for F4 edit-through tests ────────────────────────────────────────

--- Build a draw mock whose render_state returns *state_map*.
--- *state_map* is the value returned by draw.render_state(bufnr): a table
--- keyed by fence_first with block records, or nil for "no active render".
--- @param state_map table|nil
--- @return table
local function make_draw_mock(state_map)
  local m = {
    clear_calls = {},
  }

  function m.render_state(_bufnr)
    return state_map
  end

  function m.clear(bufnr_arg)
    m.clear_calls[#m.clear_calls + 1] = { bufnr = bufnr_arg }
    -- Wipe the state so subsequent render_state calls return nil.
    state_map = nil
  end

  function m.is_render_line(_b, _l)
    return nil
  end

  return m
end

--- Build a draw state map (returned by draw.render_state) with one block.
--- The block has the given *inserted_range* (or nil if no tasks were drawn).
--- @param fence_first integer  0-indexed fence start line
--- @param inserted_range table|nil  { first, last } 0-indexed
--- @return table  state map keyed by fence_first
local function make_draw_state(fence_first, inserted_range)
  return {
    [fence_first] = {
      fence_range = { fence_first, fence_first + 2 },
      inserted_range = inserted_range,
      em_map = {},
      all_eids = {},
    },
  }
end

--- Build an edit mock that records calls and returns *diff_result*.
--- @param diff_result table|nil  { patches, deletions, inserts } (defaults to empty)
--- @return table
local function make_edit_mock(diff_result)
  local m = {
    diff_calls = {},
    patch_calls = {},
    deletion_calls = {},
    insert_calls = {},
  }
  local result = diff_result or { patches = {}, deletions = {}, inserts = {} }

  function m.diff(bufnr_arg, range)
    m.diff_calls[#m.diff_calls + 1] = { bufnr = bufnr_arg, range = range }
    return result
  end

  function m.apply_patch(patch)
    m.patch_calls[#m.patch_calls + 1] = patch
  end

  function m.apply_deletion(del)
    m.deletion_calls[#m.deletion_calls + 1] = del
  end

  function m.apply_insert(ins)
    m.insert_calls[#m.insert_calls + 1] = ins
  end

  return m
end

-- ── User:ObsidianNoteWritePre: no-op when no render ──────────────────────────

T["ObsidianNoteWritePre: no-op when draw state is nil"] = function()
  local draw = make_draw_mock(nil)
  local edit = make_edit_mock()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())

  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- diff must not be called, clear_buffer must not be called.
  eq(#edit.diff_calls, 0)
  eq(#render.clear_calls, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

-- ── User:ObsidianNoteWritePre: diff + apply + strip ──────────────────────────

T["ObsidianNoteWritePre: calls diff with inserted_range when render is active"] = function()
  local state = make_draw_state(0, { 3, 3 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())

  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- diff must have been called once with the correct range.
  eq(#edit.diff_calls, 1)
  eq(edit.diff_calls[1].bufnr, bufnr)
  eq(edit.diff_calls[1].range, { 3, 3 })

  -- clear_buffer must have been called.
  eq(#render.clear_calls, 1)
  eq(render.clear_calls[1].bufnr, bufnr)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

T["ObsidianNoteWritePre: applies patches returned by diff"] = function()
  local diff_result = {
    patches = { { src_path = "/vault/a.md", src_line = 5, new_text = "- [x] Done" } },
    deletions = {},
    inserts = {},
  }
  local state = make_draw_state(0, { 3, 3 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock(diff_result)
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  eq(#edit.patch_calls, 1)
  eq(edit.patch_calls[1].src_path, "/vault/a.md")
  eq(edit.patch_calls[1].src_line, 5)
  eq(edit.patch_calls[1].new_text, "- [x] Done")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

T["ObsidianNoteWritePre: applies deletions returned by diff"] = function()
  local diff_result = {
    patches = {},
    deletions = { { src_path = "/vault/b.md", src_line = 7 } },
    inserts = {},
  }
  local state = make_draw_state(0, { 3, 3 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock(diff_result)
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  eq(#edit.deletion_calls, 1)
  eq(edit.deletion_calls[1].src_path, "/vault/b.md")
  eq(edit.deletion_calls[1].src_line, 7)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

T["ObsidianNoteWritePre: forwards inserts returned by diff"] = function()
  local diff_result = {
    patches = {},
    deletions = {},
    inserts = { { after_lnum = 4, new_text = "- [ ] New task" } },
  }
  local state = make_draw_state(0, { 3, 4 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock(diff_result)
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  eq(#edit.insert_calls, 1)
  eq(edit.insert_calls[1].after_lnum, 4)
  eq(edit.insert_calls[1].new_text, "- [ ] New task")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

T["ObsidianNoteWritePre: skips diff for block with nil inserted_range"] = function()
  -- A block with nil inserted_range means no task lines were drawn.
  local state = make_draw_state(0, nil)
  local draw = make_draw_mock(state)
  local edit = make_edit_mock()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- diff not called (no task lines to diff), but clear_buffer still called.
  eq(#edit.diff_calls, 0)
  eq(#render.clear_calls, 1)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

-- ── User:ObsidianNoteWritePre + BufWritePost: re-render flow ─────────────────

T["BufWritePost: re-renders buffer after ObsidianNoteWritePre strip (auto_render=true)"] = function()
  local state = make_draw_state(0, { 3, 3 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock()
  local render = make_render_mock()
  local ws = { root = "/vault" }
  local obsidian = make_obsidian_mock(ws)

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())

  -- Fire the pre-write event (strips render, records pending re-render).
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- Fire BufWritePost (should trigger re-render via pending table).
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })

  eq(#render.render_calls, 1)
  eq(render.render_calls[1].bufnr, bufnr)
  MiniTest.expect.equality(render.render_calls[1].ws, ws)

  -- Pending entry must be consumed (no double re-render on next BufWritePost).
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
  eq(#render.render_calls, 1)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

T["BufWritePost: no re-render when auto_render=false"] = function()
  local state = make_draw_state(0, { 3, 3 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = false })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())

  -- Strip still happens (auto_render=false does not skip strip).
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })
  eq(#render.clear_calls, 1)

  -- But BufWritePost must NOT re-render.
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
  eq(#render.render_calls, 0)
  eq(#render.refresh_calls, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

T["BufWritePost: no re-render after strip when workspace is nil (non-vault file)"] = function()
  local state = make_draw_state(0, { 3, 3 })
  local draw = make_draw_mock(state)
  local edit = make_edit_mock()
  local render = make_render_mock()
  local obsidian = make_obsidian_mock(nil) -- non-vault

  local r1 = install_mock("obsidian-tasks.render.draw", draw)
  local r2 = install_mock("obsidian-tasks.render.edit", edit)
  local r3 = install_mock("obsidian-tasks.render", render)
  local r4 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = true })

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path("/outside/note_"))

  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })

  -- No re-render: workspace was nil so pending entry was never set.
  eq(#render.render_calls, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
  r3()
  r4()
end

-- ── ObsidianNoteWritePre: multi-block regression test ────────────────────────

-- Regression guard for the cross-block deletion bug: in a two-block buffer,
-- each per-block diff call must NOT emit a deletion for tasks in the OTHER block.
-- Uses real draw + mocked edit so deletions are captured and checked.

T["ObsidianNoteWritePre: no spurious cross-block deletions in two-block buffer"] = function()
  -- Use the REAL edit.diff (not a mock) to exercise the block_em_map scoping fix.
  -- Spy on apply_deletion so disk writes are suppressed but calls are captured.
  local deletion_calls = {}
  local real_edit = require("obsidian-tasks.render.edit")
  local edit_spy = {
    diff = real_edit.diff,
    apply_patch = function(_p) end,
    apply_deletion = function(d)
      deletion_calls[#deletion_calls + 1] = d
    end,
    apply_insert = function(_i) end,
  }
  local r1 = install_mock("obsidian-tasks.render.edit", edit_spy)
  local r2 = install_mock("obsidian-tasks.util.obsidian", make_obsidian_mock({ root = "/vault" }))

  local draw_mod = require("obsidian-tasks.render.draw")

  -- Buffer with two fence blocks.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "```tasks", -- 0
    "not done", -- 1
    "```", -- 2
    "", -- 3
    "```tasks", -- 4
    "done", -- 5
    "```", -- 6
  })

  -- Draw block A (fence 0-2) → task inserted at line 3.
  local task_a = "- [ ] Task A"
  draw_mod.draw(bufnr, { 0, 2 }, {
    {
      kind = "task",
      text = task_a,
      src_path = "/vault/a.md",
      src_line = 10,
      src_hash = vim.fn.sha256(task_a):sub(1, 16),
    },
  })

  -- After block A, block B fence is now at lines 5-7 (shifted by 1 inserted task).
  local task_b = "- [ ] Task B"
  draw_mod.draw(bufnr, { 5, 7 }, {
    {
      kind = "task",
      text = task_b,
      src_path = "/vault/b.md",
      src_line = 20,
      src_hash = vim.fn.sha256(task_b):sub(1, 16),
    },
  })
  -- task_b is now at line 8.

  -- Fire ObsidianNoteWritePre with NO user edits → both tasks are unchanged.
  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = false })
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- The real diff scoped to each block's em_map must produce 0 deletions.
  -- Before the fix (all-blocks tracked), diff(bufnr, {3,3}) would see task_b's
  -- extmark at row 8 (outside range), fail both claims, and emit a spurious
  -- DELETION for /vault/b.md:20 — and vice-versa for the second diff call.
  eq(#deletion_calls, 0)

  -- Both task lines must be stripped from the buffer (original 7 lines remain).
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#lines, 7)
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(l:find("Task A", 1, true), nil)
    MiniTest.expect.equality(l:find("Task B", 1, true), nil)
  end

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

-- ── ObsidianNoteWritePre + strip: integration (real draw module) ─────────────

-- Verifies actual buffer lines are removed; uses real draw + render modules,
-- mocked edit (no source file writes) and obsidian-util (workspace detection).
-- Each test creates its own bufnr so draw state is isolated.

T["ObsidianNoteWritePre: strips render task lines from buffer, leaves fence intact"] = function()
  local edit = make_edit_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })
  local r1 = install_mock("obsidian-tasks.render.edit", edit)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  -- Use currently-loaded draw and render modules (no force-reload — that would
  -- corrupt shared module state and break other test files).
  local draw_mod = require("obsidian-tasks.render.draw")

  -- Create a buffer with fence lines only.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })

  -- Draw a single task line using the real draw module.
  local task_text = "- [ ] Integration strip test"
  local layout_lines = {
    {
      kind = "task",
      text = task_text,
      src_path = "/vault/source.md",
      src_line = 5,
      src_hash = vim.fn.sha256(task_text):sub(1, 16),
    },
  }
  draw_mod.draw(bufnr, { 0, 2 }, layout_lines)

  -- Verify task line was inserted (buffer should now have 4 lines).
  local before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#before >= 4, true)
  local task_found = false
  for _, l in ipairs(before) do
    if l:find("Integration strip test", 1, true) then
      task_found = true
    end
  end
  MiniTest.expect.equality(task_found, true)

  -- Set up autocmds with the real render module accessible.
  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = false })

  -- Fire ObsidianNoteWritePre — should strip the task line.
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- Buffer should now have only the 3 fence lines.
  local after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#after, 3)
  eq(after[1], "```tasks")
  eq(after[2], "not done")
  eq(after[3], "```")

  -- Draw state must be cleared.
  MiniTest.expect.equality(draw_mod.render_state(bufnr), nil)

  -- Cleanup.
  draw_mod.clear(bufnr) -- no-op (already cleared); safe to call
  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

T["ObsidianNoteWritePre: frontmatter preserved after in-place modification + strip"] = function()
  -- Simulate obsidian.nvim modifying frontmatter in-place (no line count change)
  -- before our User event fires; verify frontmatter change AND render strip coexist.
  local edit = make_edit_mock()
  local obsidian = make_obsidian_mock({ root = "/vault" })
  local r1 = install_mock("obsidian-tasks.render.edit", edit)
  local r2 = install_mock("obsidian-tasks.util.obsidian", obsidian)

  local draw_mod = require("obsidian-tasks.render.draw")

  -- Buffer with frontmatter + tasks fence.
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, unique_md_path())
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "---",
    "tags: []",
    "---",
    "",
    "```tasks",
    "not done",
    "```",
  })

  -- Draw a task after the fence (fence is lines 4-6, 0-indexed).
  local task_text = "- [ ] Frontmatter test task"
  local layout_lines = {
    {
      kind = "task",
      text = task_text,
      src_path = "/vault/source.md",
      src_line = 3,
      src_hash = vim.fn.sha256(task_text):sub(1, 16),
    },
  }
  draw_mod.draw(bufnr, { 4, 6 }, layout_lines)

  -- Simulate obsidian.nvim updating frontmatter in-place (line 2 modified, no line count change).
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "tags: [work]" })

  -- Fire ObsidianNoteWritePre.
  local autocmds = get_autocmds()
  autocmds.setup({ auto_render = false })
  vim.api.nvim_exec_autocmds("User", { pattern = "ObsidianNoteWritePre", data = { buf = bufnr } })

  -- Frontmatter tag update must be preserved.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(lines[2], "tags: [work]")

  -- Task line must be stripped; buffer has frontmatter (3) + blank (1) + fence (3) = 7 total.
  eq(#lines, 7)
  -- No task line in buffer.
  for _, l in ipairs(lines) do
    MiniTest.expect.equality(l:find("Frontmatter test task", 1, true), nil)
  end

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  r1()
  r2()
end

return T
