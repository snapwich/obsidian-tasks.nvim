-- tests/integration/test_linger_generic_trigger.lua
-- RED-phase integration tests for the P6 broadened linger trigger.
--
-- Tests exercise the full flush → _would_move → _record_pending_linger pipeline.
-- All tests that depend on the broadened trigger are FAILING against the current
-- stub (M._would_move always returns { moves = false }, so no lingers are ever
-- recorded by the flush path).
--
-- Once the P6 GREEN task (ot-ckin) implements M._would_move, these tests pass.
--
-- Locked decisions exercised:
--   Q8   linger-wins dedup: linger holds prior position on next rerender.
--   Q9   multi-buffer: only the editing buffer's linger is recorded.
--   P6   Skip-lingering optimisation: description-only edits with no group/sort
--        impact do not record a linger.
--   P6   <leader>tr (refresh_with_clear_lingers) clears broadened lingers
--        (regression guard — passes immediately since the clear mechanism
--        is already implemented and the linger structure is unchanged).
--   P6   Per-block-query dedup: linger in block 1 does not suppress live
--        render of the same task in block 2.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local edit_mod = require("obsidian-tasks.render.edit")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

local function get_line(bufnr, row0)
  return vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
end

local function set_line(bufnr, row0, text)
  vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { text })
end

--- Index stub that reads tasks directly from a source file on disk.
--- Tasks are returned with their 1-indexed line numbers.
local function install_file_task_stub(src_path)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
    reverse_index = index_mod.reverse_index,
  }
  index_mod.tasks_in = function(_)
    local content = {}
    local src_buf = vim.fn.bufnr(src_path, false)
    if src_buf ~= -1 and vim.api.nvim_buf_is_loaded(src_buf) then
      content = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
    else
      local ok, lines = pcall(vim.fn.readfile, src_path)
      content = ok and lines or {}
    end
    local i = 0
    return function()
      while true do
        i = i + 1
        local line = content[i]
        if line == nil then
          return nil
        end
        local task = task_parse.parse(line)
        if task then
          return task, src_path, i
        end
      end
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.reverse_index = function()
    return {}
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
    index_mod.reverse_index = saved.reverse_index
  end
end

--- Build a dashboard buffer + tmpfile + index stub and return a cleanup fn.
--- query_lines: list of query lines (without fence markers).
--- task_text: the single task line written to the source file.
local function setup_grouped_dashboard(task_text, query_lines)
  render.configure({
    default_folded = false,
    linger_on_filter_exit = true,
    linger_hl_group = "ObsidianTasksLinger",
  })
  local src_path = make_tmpfile({ task_text })
  local restore = install_file_task_stub(src_path)

  local buf_lines = { "```tasks" }
  for _, ql in ipairs(query_lines) do
    buf_lines[#buf_lines + 1] = ql
  end
  buf_lines[#buf_lines + 1] = "```"

  local bufnr = make_buf(buf_lines)
  render.render_buffer(bufnr, nil)

  local cleanup = function()
    render._lingers[bufnr] = nil
    render._pending_lingers[bufnr] = nil
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local src_buf = vim.fn.bufnr(src_path, false)
    if src_buf ~= -1 then
      vim.api.nvim_buf_delete(src_buf, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end

  -- Task row is immediately after the closing fence:
  --   row 0          = ```tasks
  --   rows 1..N      = query lines
  --   row N+1        = ```
  --   row N+2        = first task (group header is a virt_line above it)
  local task_row = #query_lines + 2

  return bufnr, src_path, task_row, cleanup
end

--- Return the number of pending linger entries for bufnr.
local function pending_count(bufnr)
  return #(render._pending_lingers[bufnr] or {})
end

--- Return the number of promoted linger entries for bufnr.
local function linger_count(bufnr)
  return #(render._lingers[bufnr] or {})
end

--- Count task lines in the buffer's render state that have linger=true.
local function linger_line_count(bufnr)
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

-- ── 1. Due-date edit on group-by-due dashboard ────────────────────────────────
-- Editing a task's due date so it would move to a different group MUST
-- record a pending linger after flush.
--
-- RED: _would_move stub returns { moves = false } → no linger recorded.
-- The assertion eq(pending_count(bufnr), 1) FAILS.

T["linger_generic: due-date edit on group-by-due dashboard records pending linger"] = function()
  local bufnr, _, task_row, cleanup =
    setup_grouped_dashboard("- [ ] Task A 📅 2026-01-01", { "not done", "group by due" })

  -- Simulate cw: replace the due date with one in a different group.
  local canonical = get_line(bufnr, task_row)
  local edited = canonical:gsub("2026%-01%-01", "2026-02-01")
  assert(edited ~= canonical, "expected the date to be found and replaced in rendered text")
  set_line(bufnr, task_row, edited)

  edit_mod.flush(bufnr)

  -- RED: stub returns no-move, so pending_count should be 0 but we assert 1.
  eq(pending_count(bufnr), 1, "due-date edit crossing a group boundary must record a pending linger")

  cleanup()
end

-- ── 2. Tag edit on group-by-tag dashboard ─────────────────────────────────────
-- Editing an inline tag so it would move to a different tag group MUST
-- record a pending linger.
--
-- RED: _would_move stub → no linger recorded → assertion FAILS.

T["linger_generic: tag edit on group-by-tag dashboard records pending linger"] = function()
  local bufnr, _, task_row, cleanup = setup_grouped_dashboard("- [ ] Task B #alpha", { "not done", "group by tags" })

  -- Simulate cw: replace tag #alpha with #beta (different group).
  local canonical = get_line(bufnr, task_row)
  local edited = canonical:gsub("#alpha", "#beta")
  assert(edited ~= canonical, "expected the tag to be found and replaced in rendered text")
  set_line(bufnr, task_row, edited)

  edit_mod.flush(bufnr)

  -- RED: no linger recorded by stub.
  eq(pending_count(bufnr), 1, "tag edit crossing a group boundary must record a pending linger")

  cleanup()
end

-- ── 3. Description-only edit on no-group dashboard ────────────────────────────
-- Editing only the description when the query has no group-by or sort-by on
-- description must NOT record a linger (skip-lingering optimisation).
--
-- GREEN: this test PASSES immediately since the stub returns moves=false,
-- which means no linger is recorded — matching the expected behavior.

T["linger_generic: description-only edit on no-group dashboard records no linger"] = function()
  local bufnr, _, task_row, cleanup = setup_grouped_dashboard("- [ ] Buy milk", { "not done" })

  -- Simulate cw: change description.
  local canonical = get_line(bufnr, task_row)
  local edited = canonical:gsub("Buy milk", "Buy oat milk")
  assert(edited ~= canonical, "expected the description to be found and replaced in rendered text")
  set_line(bufnr, task_row, edited)

  edit_mod.flush(bufnr)

  -- No group-by / sort-by on description → no visual move → no linger.
  eq(pending_count(bufnr), 0, "description-only edit must not record a pending linger")

  cleanup()
end

-- ── 4. Multi-buffer: linger only in editing buffer ───────────────────────────
-- When the same source task appears in two dashboard buffers and the user
-- edits it inline in buffer A, a linger must be recorded only in buffer A.
-- Buffer B re-renders fresh (Q9).
--
-- RED: no linger recorded by stub → assertion for bufA FAILS.
-- The assertion for bufB (no linger) passes trivially.

T["linger_generic: flush in bufA records linger in bufA only, not bufB"] = function()
  render.configure({
    default_folded = false,
    linger_on_filter_exit = true,
    linger_hl_group = "ObsidianTasksLinger",
  })

  local src_path = make_tmpfile({ "- [ ] Shared task 📅 2026-01-01" })
  local restore = install_file_task_stub(src_path)

  local function make_dash_buf()
    local b = make_buf({ "```tasks", "not done", "group by due", "```" })
    render.render_buffer(b, nil)
    return b
  end

  local bufA = make_dash_buf()
  local bufB = make_dash_buf()

  -- Edit the task inline in bufA (task_row = 4 for 2-line query).
  local task_row = 4
  local canonical = get_line(bufA, task_row)
  local edited = canonical:gsub("2026%-01%-01", "2026-02-01")
  assert(edited ~= canonical, "expected date to be replaceable in bufA")
  set_line(bufA, task_row, edited)

  edit_mod.flush(bufA)

  -- RED: stub → no linger in bufA; assertion below FAILS.
  eq(pending_count(bufA), 1, "editing buffer A must record a pending linger in bufA")
  -- Regression guard: bufB must have NO linger (Q9 multi-buffer isolation).
  eq(pending_count(bufB), 0, "non-editing buffer B must not have any pending lingers")

  -- Cleanup.
  render._lingers[bufA] = nil
  render._pending_lingers[bufA] = nil
  render._lingers[bufB] = nil
  render._pending_lingers[bufB] = nil
  render.clear_buffer(bufA)
  render.clear_buffer(bufB)
  restore()
  revert._cleanup(bufA)
  revert._cleanup(bufB)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufA, { force = true })
  vim.api.nvim_buf_delete(bufB, { force = true })
  vim.fn.delete(src_path)
end

-- ── 5. refresh_with_clear_lingers clears broadened lingers ───────────────────
-- Regression guard: <leader>tr must clear lingers that were recorded by the
-- broadened trigger (same _lingers structure as the status-flip path).
--
-- GREEN: this test PASSES immediately — the clear mechanism is unchanged and
-- works regardless of how the linger was originally recorded.  This test
-- guards against future regressions where a P6 refactor might break the clear.

T["linger_generic: refresh_with_clear_lingers clears broadened lingers (regression guard)"] = function()
  render.configure({
    default_folded = false,
    linger_on_filter_exit = true,
    linger_hl_group = "ObsidianTasksLinger",
  })

  local index_mod = require("obsidian-tasks.index")
  local task_parse_mod = require("obsidian-tasks.task.parse")
  local saved_tasks_in = index_mod.tasks_in
  local saved_srp = index_mod.set_render_paths
  local saved_crp = index_mod.clear_render_paths
  local saved_ri = index_mod.reverse_index
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.reverse_index = function()
    return {}
  end

  -- First: task is live.
  local current_tasks = {
    { task = task_parse_mod.parse("- [ ] Linger test 📅 2026-01-01"), path = "/vault/a.md", line_nr = 1 },
  }
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      local row = current_tasks[i]
      if not row then
        return nil
      end
      return row.task, row.path, row.line_nr
    end
  end

  local bufnr = make_buf({ "```tasks", "not done", "group by due", "```" })
  render.render_buffer(bufnr, nil)

  -- Directly record a pending linger (bypassing would_move, simulating a
  -- successful broadened trigger recording a linger entry).
  local done_task = task_parse_mod.parse("- [ ] Linger test 📅 2026-02-01")
  render._record_pending_linger(bufnr, "/vault/a.md", 1, nil, done_task)

  -- Make the task disappear from the live set so the linger gets promoted.
  current_tasks = {}
  render.rerender_buffer(bufnr, nil)

  -- Linger should now be promoted.
  eq(linger_count(bufnr) >= 1, true, "linger should be promoted after rerender")

  -- Call refresh_with_clear_lingers (simulates <leader>tr).
  render.refresh_with_clear_lingers(bufnr, nil)

  -- All linger state must be cleared.
  eq(render._lingers[bufnr], nil, "refresh_with_clear_lingers must clear _lingers")
  eq(render._pending_lingers[bufnr], nil, "refresh_with_clear_lingers must clear _pending_lingers")
  eq(linger_line_count(bufnr), 0, "no linger lines should remain in buffer state after clear")

  -- Cleanup.
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_srp
  index_mod.clear_render_paths = saved_crp
  index_mod.reverse_index = saved_ri
  render.clear_buffer(bufnr)
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── 6. Per-block-query dedup: linger in block 1 does not suppress block 2 ────
-- When a dashboard has two ```tasks blocks, a linger recorded for block 1
-- (because the task moved groups in that block's query context) must not
-- suppress the live render of the same task in block 2.
--
-- RED: the broadened trigger is a stub → no linger recorded for block 1 →
-- assertion that block 1 has a lingered task FAILS.
-- The assertion that block 2 still has a live task passes trivially.

T["linger_generic: per-block-query dedup: linger in block 1 does not suppress live in block 2"] = function()
  render.configure({
    default_folded = false,
    linger_on_filter_exit = true,
    linger_hl_group = "ObsidianTasksLinger",
  })

  local src_path = make_tmpfile({ "- [ ] Task C 📅 2026-01-01" })
  local restore = install_file_task_stub(src_path)

  -- Two blocks:
  --   Block 1: "not done\ngroup by due"  (grouped; task is in group "2026-01-01")
  --   Block 2: "not done"                (ungrouped; always shows the task)
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "group by due",
    "```",
    "",
    "```tasks",
    "not done",
    "```",
  })
  render.render_buffer(bufnr, nil)

  -- Block 1's task row is at fence_end(row 3) + 1 = row 4.
  local task_row_b1 = 4
  local canonical = get_line(bufnr, task_row_b1)
  local edited = canonical:gsub("2026%-01%-01", "2026-02-01")
  assert(edited ~= canonical, "expected date to be replaceable in block 1 task row")
  set_line(bufnr, task_row_b1, edited)

  edit_mod.flush(bufnr)

  -- Check pending lingers after flush.
  -- RED: no linger recorded → assertion that block 1 produced a linger FAILS.
  eq(pending_count(bufnr) >= 1, true, "due-date edit in block 1 must record a pending linger for that block")

  -- Also verify that after rerender, block 2 still shows the live task
  -- (i.e., the linger in block 1 does not leak into block 2).
  -- Update source so the rerender reads the edited task.
  -- (The flush already wrote the new date to src_path.)
  render.rerender_buffer(bufnr, nil)

  -- Block 2 should still have a live (non-lingered) task row.
  local buf_state = render._buffer_state[bufnr] or {}
  local block2_has_live = false
  if buf_state[2] then
    for _, meta in pairs(buf_state[2].line_map or {}) do
      if not meta.linger then
        block2_has_live = true
      end
    end
  end
  eq(block2_has_live, true, "block 2 must still render a live task row after a linger in block 1")

  -- Cleanup.
  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

return T
