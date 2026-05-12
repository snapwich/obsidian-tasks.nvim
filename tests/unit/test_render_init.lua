-- tests/unit/test_render_init.lua
-- Unit tests for render/init.lua orchestrator.
-- draw module is mocked; parse/run/layout run for real against a stub index.

local T = MiniTest.new_set()

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

-- ── Mock helpers ──────────────────────────────────────────────────────────────

--- Build a fresh draw mock.  Records every call to draw() and clear().
--- Returns a mock table and a reset function.
local function make_draw_mock()
  local m = {
    draw_calls = {},
    clear_calls = {},
    _state = {},
  }

  function m.draw(bufnr, fence_range, layout_lines)
    m.draw_calls[#m.draw_calls + 1] = {
      bufnr = bufnr,
      fence_range = fence_range,
      layout_lines = layout_lines,
    }
    -- Simulate draw state so orchestrator can query render_state().
    if not m._state[bufnr] then
      m._state[bufnr] = {}
    end
    local fence_first = fence_range[1]
    local n_tasks = 0
    for _, ll in ipairs(layout_lines) do
      if ll.kind == "task" then
        n_tasks = n_tasks + 1
      end
    end
    local insert_at = fence_range[2] + 1
    local em_map = {}
    for i = 1, n_tasks do
      em_map[i] = { src_path = "/mock.md", src_line = i, src_hash = "0000000000000000" }
    end
    m._state[bufnr][fence_first] = {
      fence_range = fence_range,
      inserted_range = n_tasks > 0 and { insert_at, insert_at + n_tasks - 1 } or nil,
      em_map = em_map,
      all_eids = {},
    }
  end

  function m.clear(bufnr)
    m.clear_calls[#m.clear_calls + 1] = { bufnr = bufnr }
    m._state[bufnr] = nil
  end

  function m.render_state(bufnr)
    return m._state[bufnr]
  end

  function m.is_render_line(_bufnr, _lnum)
    return nil
  end

  function m.set_summary(_bufnr, _fence_first, _summary)
    -- No-op in unit tests; the real impl attaches a virt_lines_above extmark.
  end

  function m.reset()
    m.draw_calls = {}
    m.clear_calls = {}
    m._state = {}
  end

  return m
end

--- Build a stub index module whose tasks_in() returns the given task list.
--- Each entry: { task = Task, path = string, line_num = integer }.
--- @param entries table[]
--- @return table  index stub
local function make_index_stub(entries)
  return {
    tasks_in = function(_filter)
      local i = 0
      return function()
        i = i + 1
        local e = entries[i]
        if e then
          return e.task, e.path, e.line_num
        end
      end
    end,
    -- F7: reverse-index maintenance (no-op in unit tests for render/init)
    set_render_paths = function(_bufnr, _paths_set) end,
    clear_render_paths = function(_bufnr) end,
  }
end

--- Install *mock* as the draw module in package.loaded.
--- Returns a cleanup function that restores the original.
--- @param mock table
--- @return fun()
local function install_draw_mock(mock)
  local orig = package.loaded["obsidian-tasks.render.draw"]
  package.loaded["obsidian-tasks.render.draw"] = mock
  return function()
    package.loaded["obsidian-tasks.render.draw"] = orig
  end
end

--- Install *stub* as the index module.
--- @param stub table
--- @return fun()
local function install_index_stub(stub)
  local orig = package.loaded["obsidian-tasks.index"]
  package.loaded["obsidian-tasks.index"] = stub
  return function()
    package.loaded["obsidian-tasks.index"] = orig
  end
end

-- ── Module under test ─────────────────────────────────────────────────────────

-- Reset render/init module state between tests (it holds _buffer_state).
local function get_render_mod()
  -- Force a fresh module load to clear _buffer_state.
  package.loaded["obsidian-tasks.render.init"] = nil
  return require("obsidian-tasks.render.init")
end

-- ── has_tasks_block ───────────────────────────────────────────────────────────

T["has_tasks_block: returns true when buffer has a tasks fence"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "some line", "```tasks", "not done", "```", "end" })
  eq(render.has_tasks_block(bufnr), true)
end

T["has_tasks_block: returns false when no tasks fence"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "# My note", "- [ ] task", "```lua", "code", "```" })
  eq(render.has_tasks_block(bufnr), false)
end

T["has_tasks_block: empty buffer returns false"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({})
  eq(render.has_tasks_block(bufnr), false)
end

T["has_tasks_block: returns false for plain code fence"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "```", "some code", "```" })
  eq(render.has_tasks_block(bufnr), false)
end

-- ── find_blocks ───────────────────────────────────────────────────────────────

T["find_blocks: single block returns one entry"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local blocks = render.find_blocks(bufnr)
  eq(#blocks, 1)
  eq(blocks[1].fence_start, 1)
  eq(blocks[1].query_start, 2)
  eq(blocks[1].query_end, 2)
  eq(blocks[1].fence_end, 3)
end

T["find_blocks: two blocks returns two entries"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({
    "```tasks", -- 1
    "not done", -- 2
    "```", -- 3
    "", -- 4
    "```tasks", -- 5
    "done", -- 6
    "```", -- 7
  })
  local blocks = render.find_blocks(bufnr)
  eq(#blocks, 2)
  eq(blocks[1].fence_start, 1)
  eq(blocks[1].fence_end, 3)
  eq(blocks[2].fence_start, 5)
  eq(blocks[2].fence_end, 7)
end

T["find_blocks: empty query block"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "```tasks", "```" })
  local blocks = render.find_blocks(bufnr)
  eq(#blocks, 1)
  eq(blocks[1].fence_start, 1)
  eq(blocks[1].query_start, 2)
  eq(blocks[1].query_end, 1) -- query_start > query_end means empty
  eq(blocks[1].fence_end, 2)
end

T["find_blocks: no blocks returns empty list"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "# heading", "- [ ] task", "" })
  local blocks = render.find_blocks(bufnr)
  eq(#blocks, 0)
end

T["find_blocks: multi-line query"] = function()
  local render = get_render_mod()
  local bufnr = make_buf({ "```tasks", "not done", "sort by due", "limit 10", "```" })
  local blocks = render.find_blocks(bufnr)
  eq(#blocks, 1)
  eq(blocks[1].query_start, 2)
  eq(blocks[1].query_end, 4)
  eq(blocks[1].fence_end, 5)
end

-- ── render_buffer: 0-block buffer ────────────────────────────────────────────

T["render_buffer: no-op when buffer has no tasks block"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore = install_draw_mock(draw_mock)

  local bufnr = make_buf({ "# plain note", "- [ ] todo" })
  render.render_buffer(bufnr)

  -- draw() should never have been called.
  eq(#draw_mock.draw_calls, 0)
  restore()
end

T["render_buffer: clear not called when buffer has no tasks block"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore = install_draw_mock(draw_mock)

  local bufnr = make_buf({ "no tasks here" })
  render.render_buffer(bufnr)

  -- clear() is called once as part of initial clear, but render stops early.
  -- The guard is `has_tasks_block`, checked before clear.
  eq(#draw_mock.draw_calls, 0)
  restore()
end

-- ── render_buffer: 1-block buffer ────────────────────────────────────────────

T["render_buffer: calls draw once for single block"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  eq(#draw_mock.draw_calls, 1)
  eq(draw_mock.draw_calls[1].bufnr, bufnr)
  -- fence_range should be 0-indexed: fence starts at line 0
  eq(draw_mock.draw_calls[1].fence_range[1], 0)
  eq(draw_mock.draw_calls[1].fence_range[2], 2)

  restore_draw()
  restore_idx()
end

T["render_buffer: layout_lines contain label and footer for empty result"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  local layout_lines = draw_mock.draw_calls[1].layout_lines
  -- Should have at least label and footer kinds.
  local kinds = {}
  for _, ll in ipairs(layout_lines) do
    kinds[ll.kind] = true
  end
  MiniTest.expect.equality(kinds["label"] == true, true)
  MiniTest.expect.equality(kinds["footer"] == true, true)

  restore_draw()
  restore_idx()
end

T["render_buffer: populates _buffer_state after render"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  MiniTest.expect.equality(render._buffer_state[bufnr] ~= nil, true)
  eq(#render._buffer_state[bufnr], 1)

  restore_draw()
  restore_idx()
end

-- ── render_buffer: 2-block buffer ────────────────────────────────────────────

T["render_buffer: calls draw twice for two blocks"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({
    "```tasks", -- 1
    "not done", -- 2
    "```", -- 3
    "", -- 4
    "```tasks", -- 5
    "done", -- 6
    "```", -- 7
  })
  render.render_buffer(bufnr)

  eq(#draw_mock.draw_calls, 2)

  restore_draw()
  restore_idx()
end

T["render_buffer: second block fence adjusted for inserted lines"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)

  -- Index with one task so block A produces one inserted line.
  local parse_mod = require("obsidian-tasks.task.parse")
  local task_line = "- [ ] Buy milk"
  local t = parse_mod.parse(task_line)
  assert(t ~= nil)
  local restore_idx = install_index_stub(make_index_stub({
    { task = t, path = "/vault/note.md", line_num = 10 },
  }))

  local bufnr = make_buf({
    "```tasks", -- 1 → 0-indexed 0
    "not done", -- 2 → 0-indexed 1
    "```", -- 3 → 0-indexed 2
    "", -- 4 → 0-indexed 3
    "```tasks", -- 5 → 0-indexed 4
    "done", -- 6 → 0-indexed 5
    "```", -- 7 → 0-indexed 6
  })
  render.render_buffer(bufnr)

  -- Block A: fence at {0, 2} (no previous insertions).
  -- Block B: fence was at {4, 6} originally. After block A inserts 1 task,
  -- lines shift by 1, so block B fence is now at {5, 7}.
  local call_a = draw_mock.draw_calls[1]
  local call_b = draw_mock.draw_calls[2]
  eq(call_a.fence_range[1], 0)
  eq(call_a.fence_range[2], 2)
  eq(call_b.fence_range[1], 5)
  eq(call_b.fence_range[2], 7)

  restore_draw()
  restore_idx()
end

T["render_buffer: _buffer_state has two entries for two blocks"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "",
    "```tasks",
    "done",
    "```",
  })
  render.render_buffer(bufnr)

  MiniTest.expect.equality(render._buffer_state[bufnr] ~= nil, true)
  eq(#render._buffer_state[bufnr], 2)

  restore_draw()
  restore_idx()
end

-- ── render_buffer idempotency ─────────────────────────────────────────────────

T["render_buffer: idempotent — second render produces same draw call count"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  render.render_buffer(bufnr)
  local first_draw_count = #draw_mock.draw_calls

  -- Second render: clear + redraw.
  render.render_buffer(bufnr)
  local second_draw_count = #draw_mock.draw_calls - first_draw_count

  eq(first_draw_count, second_draw_count)

  restore_draw()
  restore_idx()
end

T["render_buffer: idempotent — second render layout_lines equal to first"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  render.render_buffer(bufnr)
  local first_lines = draw_mock.draw_calls[1].layout_lines

  render.render_buffer(bufnr)
  local second_lines = draw_mock.draw_calls[2].layout_lines

  -- Same number of layout lines.
  eq(#first_lines, #second_lines)
  -- Same kinds in order.
  for i = 1, #first_lines do
    eq(first_lines[i].kind, second_lines[i].kind)
  end

  restore_draw()
  restore_idx()
end

-- ── render_buffer: error path ─────────────────────────────────────────────────

T["render_buffer: error in run produces INTERNAL ERROR label, no crash"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)

  -- Inject a run module that always throws.
  local orig_run = package.loaded["obsidian-tasks.query.run"]
  package.loaded["obsidian-tasks.query.run"] = {
    run = function(_, _)
      error("simulated run failure")
    end,
  }
  -- Provide a real index stub so tasks_in works.
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  -- Must not throw.
  MiniTest.expect.no_error(function()
    render.render_buffer(bufnr)
  end)

  -- draw() must still have been called.
  MiniTest.expect.equality(#draw_mock.draw_calls >= 1, true)

  -- The layout_lines should contain a label with INTERNAL ERROR.
  local layout_lines = draw_mock.draw_calls[1].layout_lines
  local found_error = false
  for _, ll in ipairs(layout_lines) do
    if ll.kind == "label" and type(ll.text) == "string" and ll.text:find("INTERNAL ERROR", 1, true) then
      found_error = true
    end
  end
  MiniTest.expect.equality(found_error, true)

  -- Restore.
  package.loaded["obsidian-tasks.query.run"] = orig_run
  restore_draw()
  restore_idx()
end

-- ── render_buffer: lazy index init ───────────────────────────────────────────
--
-- These tests mock index.refresh_all to drive the one-shot semantics
-- synchronously without relying on vim.schedule timing.

--- Build an index mock that supports refresh_all.
--- @param initial_entries table[]  initial task entries (may be empty)
--- @return table index_mock, table mutable_entries (can be filled later)
local function make_lazy_index_mock(initial_entries)
  local entries = initial_entries or {}
  local mock = {
    refresh_all_calls = 0,
    captured_on_done = nil,
    entries = entries,
  }

  function mock.tasks_in(_filter)
    local i = 0
    return function()
      i = i + 1
      local e = mock.entries[i]
      if e then
        return e.task, e.path, e.line_num
      end
    end
  end

  function mock.refresh_all(_workspace, on_done)
    mock.refresh_all_calls = mock.refresh_all_calls + 1
    mock.captured_on_done = on_done
  end

  -- F7: reverse-index maintenance (no-op in unit tests for render/init)
  function mock.set_render_paths(_bufnr, _paths_set) end
  function mock.clear_render_paths(_bufnr) end

  return mock
end

T["lazy init: refresh_all fires when index empty and workspace given"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local idx_mock = make_lazy_index_mock({})
  local restore_idx = install_index_stub(idx_mock)

  local workspace = { root = "/vault" }
  local bufnr = make_buf({ "```tasks", "not done", "```" })

  render.render_buffer(bufnr, workspace)

  -- refresh_all should have been called exactly once.
  eq(idx_mock.refresh_all_calls, 1)
  -- An on_done callback was captured.
  MiniTest.expect.equality(idx_mock.captured_on_done ~= nil, true)
  -- A draw still happened (empty results rendered immediately).
  MiniTest.expect.equality(#draw_mock.draw_calls >= 1, true)

  restore_draw()
  restore_idx()
end

T["lazy init: refresh_all NOT called again on recursive re-render (guard prevents loop)"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local idx_mock = make_lazy_index_mock({})
  local restore_idx = install_index_stub(idx_mock)

  local workspace = { root = "/vault" }
  local bufnr = make_buf({ "```tasks", "not done", "```" })

  -- First call: guard not set yet, refresh_all fires.
  render.render_buffer(bufnr, workspace)
  eq(idx_mock.refresh_all_calls, 1)

  -- Simulate the recursive re-render that on_done/vim.schedule would trigger.
  -- The guard (_lazy_init_started[workspace]) must prevent a second refresh_all.
  render.render_buffer(bufnr, workspace)
  eq(idx_mock.refresh_all_calls, 1) -- still 1, not 2

  restore_draw()
  restore_idx()
end

T["lazy init: second render produces normal result when index is now populated"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local idx_mock = make_lazy_index_mock({})
  local restore_idx = install_index_stub(idx_mock)

  local workspace = { root = "/vault" }
  local bufnr = make_buf({ "```tasks", "not done", "```" })

  -- First render: empty index → refresh_all fired.
  render.render_buffer(bufnr, workspace)
  eq(idx_mock.refresh_all_calls, 1)
  -- First draw has 0 tasks.
  local first_task_count = 0
  for _, ll in ipairs(draw_mock.draw_calls[1].layout_lines) do
    if ll.kind == "task" then
      first_task_count = first_task_count + 1
    end
  end
  eq(first_task_count, 0)

  -- Simulate the vault walk completing: populate the index and re-render.
  local parse_mod = require("obsidian-tasks.task.parse")
  local t = parse_mod.parse("- [ ] Buy milk")
  assert(t ~= nil)
  idx_mock.entries = { { task = t, path = "/vault/note.md", line_num = 1 } }

  -- Second render (as on_done callback would trigger via vim.schedule).
  render.render_buffer(bufnr, workspace)

  -- refresh_all still 1 (guard in place), but now tasks appear in layout.
  eq(idx_mock.refresh_all_calls, 1)
  local second_draw = draw_mock.draw_calls[2]
  MiniTest.expect.equality(second_draw ~= nil, true)
  local second_task_count = 0
  for _, ll in ipairs(second_draw.layout_lines) do
    if ll.kind == "task" then
      second_task_count = second_task_count + 1
    end
  end
  eq(second_task_count, 1) -- the "Buy milk" task rendered

  restore_draw()
  restore_idx()
end

T["lazy init: no refresh_all when workspace not given"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local idx_mock = make_lazy_index_mock({})
  local restore_idx = install_index_stub(idx_mock)

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  -- No workspace argument → must not call refresh_all.
  render.render_buffer(bufnr) -- workspace omitted
  eq(idx_mock.refresh_all_calls, 0)

  restore_draw()
  restore_idx()
end

-- ── clear_buffer ──────────────────────────────────────────────────────────────

T["clear_buffer: calls draw.clear and drops buffer state"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- State should exist.
  MiniTest.expect.equality(render._buffer_state[bufnr] ~= nil, true)

  render.clear_buffer(bufnr)

  -- draw.clear called (once during render_buffer + once in clear_buffer).
  MiniTest.expect.equality(#draw_mock.clear_calls >= 2, true)
  -- Buffer state dropped.
  eq(render._buffer_state[bufnr], nil)

  restore_draw()
  restore_idx()
end

-- ── refresh_buffer ────────────────────────────────────────────────────────────

T["refresh_buffer: re-renders buffer producing same draw call structure"] = function()
  local render = get_render_mod()
  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)
  local first_count = #draw_mock.draw_calls

  render.refresh_buffer(bufnr)
  local second_count = #draw_mock.draw_calls - first_count

  eq(first_count, second_count)

  restore_draw()
  restore_idx()
end

-- ── configure / default_folded ────────────────────────────────────────────────

T["configure: stores opts in M._opts"] = function()
  local render = get_render_mod()
  render.configure({ default_folded = false, watcher = true })
  MiniTest.expect.equality(render._opts.default_folded, false)
  MiniTest.expect.equality(render._opts.watcher, true)
end

T["configure: default_folded defaults to true when not configured"] = function()
  local render = get_render_mod()
  -- Fresh module has default _opts = { default_folded = true }
  MiniTest.expect.equality(render._opts.default_folded, true)
end

T["render_buffer: skips apply_folds when default_folded = false"] = function()
  local render = get_render_mod()
  render.configure({ default_folded = false })

  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  -- Mock the folds module to track whether apply_folds was called.
  local folds_apply_called = false
  local orig_folds = package.loaded["obsidian-tasks.render.folds"]
  package.loaded["obsidian-tasks.render.folds"] = {
    apply_folds = function(_bufnr, _block_list)
      folds_apply_called = true
    end,
    capture_fold_state = function(_bufnr, _fence_lnum)
      return "open"
    end,
    open_fold = function(_bufnr, _lnum_1) end,
  }

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  package.loaded["obsidian-tasks.render.folds"] = orig_folds
  restore_draw()
  restore_idx()

  -- apply_folds must NOT have been called when default_folded = false.
  MiniTest.expect.equality(folds_apply_called, false)
end

T["render_buffer: calls apply_folds when default_folded = true (default)"] = function()
  local render = get_render_mod()
  render.configure({ default_folded = true })

  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  -- Mock the folds module to track whether apply_folds was called.
  local folds_apply_called = false
  local orig_folds = package.loaded["obsidian-tasks.render.folds"]
  package.loaded["obsidian-tasks.render.folds"] = {
    apply_folds = function(_bufnr, _block_list)
      folds_apply_called = true
    end,
    capture_fold_state = function(_bufnr, _fence_lnum)
      return "open"
    end,
    open_fold = function(_bufnr, _lnum_1) end,
  }

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  package.loaded["obsidian-tasks.render.folds"] = orig_folds
  restore_draw()
  restore_idx()

  -- apply_folds MUST have been called when default_folded = true.
  MiniTest.expect.equality(folds_apply_called, true)
end

T["rerender_buffer: calls clear_buffer then render_buffer"] = function()
  local render = get_render_mod()
  render.configure({ default_folded = true })

  local draw_mock = make_draw_mock()
  local restore_draw = install_draw_mock(draw_mock)
  local restore_idx = install_index_stub(make_index_stub({}))

  -- Mock folds module to avoid window operations in headless tests.
  local orig_folds = package.loaded["obsidian-tasks.render.folds"]
  package.loaded["obsidian-tasks.render.folds"] = {
    apply_folds = function() end,
    capture_fold_state = function()
      return "open"
    end,
    open_fold = function() end,
  }

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  -- First render.
  render.render_buffer(bufnr)
  local first_draw_count = #draw_mock.draw_calls

  -- rerender_buffer: clears then re-renders.
  render.rerender_buffer(bufnr)
  local second_draw_count = #draw_mock.draw_calls - first_draw_count

  package.loaded["obsidian-tasks.render.folds"] = orig_folds
  restore_draw()
  restore_idx()

  -- Both renders should produce the same number of draw calls (1 for 1 block).
  eq(first_draw_count, 1)
  eq(second_draw_count, 1)
end

return T
