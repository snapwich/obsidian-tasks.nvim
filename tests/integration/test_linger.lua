-- tests/integration/test_linger.lua
-- End-to-end tests for the linger-on-filter-exit feature.
--
-- Exercises render._record_pending_linger + render.rerender_buffer to verify:
--   • Toggle followed by rerender promotes a pending entry to a linger.
--   • Linger row is rendered into the buffer with linger=true (dim).
--   • Re-running rerender (e.g. BufWritePost) preserves existing lingers.
--   • Task re-entering the live filter set drops its linger.
--   • Manual refresh (refresh_with_clear_lingers) clears all lingers.
--   • Buffer-scope rule: when the task still appears in another block in the
--     same buffer, no linger is created.
--   • linger_on_filter_exit = false dormantizes the whole feature.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local task_parse = require("obsidian-tasks.task.parse")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Install an index stub whose returned task set can be swapped at any time
--- via tasks_setter({ task, ... }) so we can simulate "task X exited the
--- filter" between renders.  Returns the setter + a restore function.
local function install_tasks_stub()
  local index_mod = require("obsidian-tasks.index")
  local saved_tasks_in = index_mod.tasks_in
  local saved_set = index_mod.set_render_paths
  local saved_clear = index_mod.clear_render_paths
  local saved_reverse = index_mod.reverse_index

  local current = {} -- list of { task, path, line_nr }
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      local row = current[i]
      if not row then
        return nil
      end
      return row.task, row.path, row.line_nr
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.reverse_index = function()
    return {}
  end

  local setter = function(rows)
    current = rows
  end
  local restore = function()
    index_mod.tasks_in = saved_tasks_in
    index_mod.set_render_paths = saved_set
    index_mod.clear_render_paths = saved_clear
    index_mod.reverse_index = saved_reverse
  end
  return setter, restore
end

--- Parse a task line and attach orchestrator metadata (mimics what query/run
--- does when feeding the index iterator to the layout pipeline).
local function make_task(line, path, line_nr)
  local t = task_parse.parse(line)
  assert(t, "expected parseable task: " .. line)
  return { task = t, path = path or "/vault/a.md", line_nr = line_nr or 1 }
end

--- Count the lingered task lines in a buffer's render state (line_map carries
--- a linger=true flag for promoted rows).
local function count_linger_lines(bufnr)
  local state = render._buffer_state[bufnr] or {}
  local n = 0
  for _, blk in ipairs(state) do
    for _, meta in pairs(blk.line_map or {}) do
      if meta.linger then
        n = n + 1
      end
    end
  end
  return n
end

local function reset_linger_state(bufnr)
  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
end

-- Default opts mirror config.lua defaults; some tests override per-case.
local function configure(opts)
  render.configure(vim.tbl_extend("force", {
    default_folded = true,
    linger_on_filter_exit = true,
    linger_hl_group = "ObsidianTasksLinger",
  }, opts or {}))
end

-- ── Tests ─────────────────────────────────────────────────────────────────────

T["linger: toggled task lingers after rerender (not done filter exits)"] = function()
  configure()
  local set_tasks, restore = install_tasks_stub()

  -- Initial state: one Todo task. The render must show it.
  local row = make_task("- [ ] task A", "/vault/a.md", 3)
  set_tasks({ row })

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Simulate: user toggles the task → status becomes Done. The cmd would call
  -- _record_pending_linger; we replicate that directly here.
  local done_task = task_parse.parse("- [x] task A")
  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, done_task)

  -- Live filter now excludes the task (it's done).
  set_tasks({})

  render.rerender_buffer(bufnr, nil)

  eq(#(render._lingers[bufnr] or {}), 1)
  eq(count_linger_lines(bufnr), 1)

  reset_linger_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

T["linger: BufWritePost-style rerender preserves existing lingers"] = function()
  configure()
  local set_tasks, restore = install_tasks_stub()

  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, task_parse.parse("- [x] task A"))
  set_tasks({})
  render.rerender_buffer(bufnr, nil)
  eq(#(render._lingers[bufnr] or {}), 1)

  -- Simulate a save event (rerender_buffer called via BufWritePost flow).
  -- The linger must survive — pending is empty, existing linger stays.
  render.rerender_buffer(bufnr, nil)
  eq(#(render._lingers[bufnr] or {}), 1)
  eq(count_linger_lines(bufnr), 1)

  reset_linger_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

T["linger: task re-entering live set drops the linger"] = function()
  configure()
  local set_tasks, restore = install_tasks_stub()

  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Linger it.
  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, task_parse.parse("- [x] task A"))
  set_tasks({})
  render.rerender_buffer(bufnr, nil)
  eq(#(render._lingers[bufnr] or {}), 1)

  -- User un-toggles in the source: task re-enters the live filter set.
  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  render.rerender_buffer(bufnr, nil)
  eq(render._lingers[bufnr], nil)
  eq(count_linger_lines(bufnr), 0)

  reset_linger_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

T["linger: refresh_with_clear_lingers wipes all lingered rows"] = function()
  configure()
  local set_tasks, restore = install_tasks_stub()

  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, task_parse.parse("- [x] task A"))
  set_tasks({})
  render.rerender_buffer(bufnr, nil)
  eq(#(render._lingers[bufnr] or {}), 1)

  render.refresh_with_clear_lingers(bufnr, nil)
  eq(render._lingers[bufnr], nil)
  eq(count_linger_lines(bufnr), 0)

  reset_linger_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

T["linger: buffer-scope rule — task still in another block → no linger"] = function()
  configure()
  local set_tasks, restore = install_tasks_stub()

  -- Two blocks: one filters `not done`, the other has no filter so it always
  -- shows the task even after completion.  Toggling the task should NOT
  -- linger it because it remains visible in the second block.
  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "",
    "```tasks",
    "```",
  })
  render.render_buffer(bufnr, nil)

  -- Toggle: status becomes Done.  The task no longer matches `not done` but
  -- the second (unfiltered) block still shows it.
  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, task_parse.parse("- [x] task A"))
  set_tasks({ make_task("- [x] task A", "/vault/a.md", 3) })
  render.rerender_buffer(bufnr, nil)

  -- buffer-scope rule: task remains visible (live) in block 2 → no linger.
  eq(render._lingers[bufnr], nil)
  eq(count_linger_lines(bufnr), 0)

  reset_linger_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

T["linger: linger_on_filter_exit=false is dormant"] = function()
  configure({ linger_on_filter_exit = false })
  local set_tasks, restore = install_tasks_stub()

  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- _record_pending_linger should silently no-op.
  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, task_parse.parse("- [x] task A"))
  eq(render._pending_lingers[bufnr], nil)

  -- And the rerender doesn't promote anything.
  set_tasks({})
  render.rerender_buffer(bufnr, nil)
  eq(render._lingers[bufnr], nil)
  eq(count_linger_lines(bufnr), 0)

  reset_linger_state(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

T["linger: clear_state drops linger state (BufReadPre path)"] = function()
  configure()
  local set_tasks, restore = install_tasks_stub()

  set_tasks({ make_task("- [ ] task A", "/vault/a.md", 3) })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  render._record_pending_linger(bufnr, "/vault/a.md", 3, nil, task_parse.parse("- [x] task A"))
  set_tasks({})
  render.rerender_buffer(bufnr, nil)
  eq(#(render._lingers[bufnr] or {}), 1)

  render.clear_state(bufnr)
  eq(render._lingers[bufnr], nil)
  eq(render._pending_lingers[bufnr], nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  restore()
end

return T
