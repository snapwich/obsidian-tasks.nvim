-- tests/integration/test_read_only_revert.lua
-- Integration tests for T6: read-only enforcement on managed regions.
--
-- Verifies acceptance criteria #7 from the F9 feature spec:
--   • Typing on a rendered task line is reverted on next event-loop tick.
--   • Paste straddling a managed region: managed rows revert, prose stays.
--   • Edit in prose: no revert.
--   • Edit inside query fence: no revert.
--   • Plugin-initiated mutations (render/rerender) do not trigger spurious reverts.
--   • Suppress reference counting is correct across nested render calls.
--
-- Uses a stub index (no vault walk required).
-- render.configure({default_folded=false}) keeps folds out of the picture so
-- tests can rely on stable row numbers without needing a window open.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Install a one-task index stub (same task returned from any tasks_in call).
--- Returns a restore function.
local function install_one_task_stub(task_text)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")

  local task_obj = task_parse.parse(task_text or "- [ ] Stub task")
  assert(task_obj, "task_parse.parse returned nil — stub setup error")

  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }

  index_mod.tasks_in = function(_)
    local returned = false
    return function()
      if not returned then
        returned = true
        return task_obj, "/vault/stub.md", 1
      end
      return nil
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Install a zero-task index stub.
--- Returns a restore function.
local function install_zero_task_stub()
  local index_mod = require("obsidian-tasks.index")

  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }

  index_mod.tasks_in = function(_)
    return function()
      return nil
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Flush pending vim.schedule callbacks by waiting up to max_ms.
--- Returns true if condition is satisfied within the timeout.
--- @param max_ms  integer
--- @param cond_fn fun(): boolean
--- @return boolean
local function flush(max_ms, cond_fn)
  return vim.wait(max_ms, cond_fn, 10)
end

--- Flush pending callbacks unconditionally (no condition to check).
local function flush_events(ms)
  vim.wait(ms or 100)
end

--- Get line at 0-indexed row in bufnr.
local function get_line(bufnr, row0)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)
  return lines[1]
end

--- Set line at 0-indexed row in bufnr (single-line replacement).
local function set_line(bufnr, row0, text)
  vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { text })
end

-- ── T1: typing on a rendered task line reverts after one tick ─────────────────

T["revert: edit on rendered task line reverts to canonical text"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] My task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  -- After render with 1 task:
  --   row 0: ```tasks
  --   row 1: not done
  --   row 2: ```
  --   row 3: - [ ] My task [[stub]]  ← rendered task (0-indexed row 3)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#lines >= 4, true)

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  MiniTest.expect.equality(canonical:find("My task") ~= nil, true)

  -- Corrupt the task line.
  set_line(bufnr, task_row, "CORRUPTED")
  eq(get_line(bufnr, task_row), "CORRUPTED")

  -- Wait for the scheduled revert to fire and re-render.
  local reverted = flush(500, function()
    local cur = get_line(bufnr, task_row)
    return cur ~= nil and cur ~= "CORRUPTED"
  end)

  MiniTest.expect.equality(reverted, true)

  -- Line should be back to the canonical task text.
  local final = get_line(bufnr, task_row)
  MiniTest.expect.equality(final ~= nil and final:find("My task") ~= nil, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T2: prose edit is not reverted ───────────────────────────────────────────

T["revert: edit in prose above query block is NOT reverted"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] My task")

  local bufnr = make_buf({
    "Prose paragraph above.",
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  -- Row 0 is prose (not managed).
  set_line(bufnr, 0, "EDITED PROSE")

  -- Wait; the prose edit should persist — no revert scheduled.
  flush_events(200)

  eq(get_line(bufnr, 0), "EDITED PROSE")

  -- Revert state: no pending revert.
  eq(revert._debug_state(bufnr).scheduled, false)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T3: edit inside query fence is not reverted ───────────────────────────────

T["revert: edit inside query fence is NOT reverted"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] My task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  -- Row 1 is the query line (inside fence, not in managed region).
  set_line(bufnr, 1, "EDITED QUERY")

  flush_events(200)

  -- Query edit should persist.
  eq(get_line(bufnr, 1), "EDITED QUERY")
  eq(revert._debug_state(bufnr).scheduled, false)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T4: plugin-initiated render does not trigger spurious revert ──────────────

T["revert: rerender_buffer does not schedule spurious revert"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] My task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  -- Explicitly re-render (simulates BufWritePost handler).
  render.rerender_buffer(bufnr, nil)

  -- No spurious revert should be scheduled.
  eq(revert._debug_state(bufnr).scheduled, false)

  -- Also flush to make sure nothing fires later.
  flush_events(100)
  eq(revert._debug_state(bufnr).scheduled, false)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T5: suppress counter across nested clear/render calls ────────────────────

T["revert: suppress counter balanced after render_buffer"] = function()
  render.configure({ default_folded = false })
  local restore = install_zero_task_stub()

  local bufnr = make_buf({
    "```tasks",
    "```",
  })

  -- Before render: suppress count = 0.
  eq(revert._debug_state(bufnr).suppress, 0)

  render.render_buffer(bufnr, nil)

  -- After render: suppress must be back to 0 (balanced increments).
  eq(revert._debug_state(bufnr).suppress, 0)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["revert: suppress counter balanced after rerender_buffer"] = function()
  render.configure({ default_folded = false })
  local restore = install_zero_task_stub()

  local bufnr = make_buf({
    "```tasks",
    "```",
  })

  render.render_buffer(bufnr, nil)

  eq(revert._debug_state(bufnr).suppress, 0)

  render.rerender_buffer(bufnr, nil)

  -- After rerender: suppress must be back to 0.
  eq(revert._debug_state(bufnr).suppress, 0)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["revert: suppress counter balanced after clear_buffer"] = function()
  render.configure({ default_folded = false })
  local restore = install_zero_task_stub()

  local bufnr = make_buf({
    "```tasks",
    "```",
  })

  render.render_buffer(bufnr, nil)

  eq(revert._debug_state(bufnr).suppress, 0)

  render.clear_buffer(bufnr)

  -- After clear: suppress must be back to 0.
  eq(revert._debug_state(bufnr).suppress, 0)

  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T6: listener attached after render_buffer ─────────────────────────────────

T["revert: listener attached after render_buffer"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] My task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  eq(revert._debug_state(bufnr).attached, false)

  render.render_buffer(bufnr, nil)

  eq(revert._debug_state(bufnr).attached, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T7: paste straddling managed region — prose part survives ─────────────────
-- This verifies that rerender_buffer (which powers the revert) correctly keeps
-- the non-managed portion of a paste while reverting the managed rows.

T["revert: paste straddling boundary — managed rows revert, prose rows stay"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] Keep me")

  --   row 0: prose line
  --   row 1: ```tasks
  --   row 2: not done
  --   row 3: ```
  -- After render with 1 task:
  --   row 4: - [ ] Keep me [[stub]]   ← managed
  local bufnr = make_buf({
    "Original prose",
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#lines >= 5, true)

  local task_row = 4 -- 0-indexed (prose + fence + query + close + task)

  -- Simulate paste: replace rows 0..task_row (inclusive) with new content.
  -- The paste includes a new prose line and then extends into the managed row.
  -- Per spec: managed rows revert; non-managed rows keep the edit.
  vim.api.nvim_buf_set_lines(bufnr, 0, task_row + 1, false, {
    "NEW PROSE LINE",
    "```tasks",
    "not done",
    "```",
    "CORRUPTED TASK",
  })

  -- Wait for revert: the corrupted task row should restore to canonical text.
  -- After rerender: line count same, task line restored.
  local reverted = flush(500, function()
    local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- Scan all lines for the corrupted text.
    for _, l in ipairs(all) do
      if l == "CORRUPTED TASK" then
        return false
      end
    end
    return true
  end)

  MiniTest.expect.equality(reverted, true)

  -- The new prose line should still be in the buffer after revert.
  local found_new_prose = false
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l == "NEW PROSE LINE" then
      found_new_prose = true
      break
    end
  end
  MiniTest.expect.equality(found_new_prose, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T8: sequential reverts — debounce flag resets between cycles ─────────────
-- Regression guard: removing `_scheduled[bufnr] = nil` inside the vim.schedule
-- callback would cause the second edit to silently skip the revert.
-- The flush(N, cond_fn) helper drains scheduled callbacks (unlike vim.wait(N)
-- with no condition), so both cycles are fully exercised.

T["revert: two sequential edit cycles both revert (debounce flag resets)"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] Cycle task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  MiniTest.expect.equality(canonical ~= nil and canonical:find("Cycle task") ~= nil, true)

  -- First corruption and revert cycle.
  set_line(bufnr, task_row, "CORRUPTED 1")
  local reverted1 = flush(500, function()
    local cur = get_line(bufnr, task_row)
    return cur ~= nil and cur ~= "CORRUPTED 1"
  end)
  MiniTest.expect.equality(reverted1, true)

  -- Confirm task text restored after first cycle.
  local mid = get_line(bufnr, task_row)
  MiniTest.expect.equality(mid ~= nil and mid:find("Cycle task") ~= nil, true)

  -- Debounce flag must have reset; second corruption must also revert.
  set_line(bufnr, task_row, "CORRUPTED 2")
  eq(get_line(bufnr, task_row), "CORRUPTED 2")

  local reverted2 = flush(500, function()
    local cur = get_line(bufnr, task_row)
    return cur ~= nil and cur ~= "CORRUPTED 2"
  end)
  MiniTest.expect.equality(reverted2, true)

  local final = get_line(bufnr, task_row)
  MiniTest.expect.equality(final ~= nil and final:find("Cycle task") ~= nil, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T9: snapshot adjusts after prose insertion above managed region ───────────
-- Regression guard: removing the snapshot-shift block at revert.lua:121-134
-- would cause on_lines to miss edits on the shifted managed rows, silently
-- letting corruption persist.

T["revert: snapshot shifts after prose insertion above managed region"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] Shift task")

  --   row 0: ```tasks
  --   row 1: not done
  --   row 2: ```
  -- After render with 1 task:
  --   row 3: - [ ] Shift task [[stub]]  ← managed
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  render.render_buffer(bufnr, nil)

  local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#lines_before >= 4, true)
  MiniTest.expect.equality(get_line(bufnr, 3):find("Shift task") ~= nil, true)

  -- Insert a prose line at the top (row 0).  This is NOT in a managed region
  -- so no revert fires, but the snapshot must shift so row 4 is now managed.
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted prose" })

  -- No revert should have been scheduled.
  flush_events(150)
  eq(revert._debug_state(bufnr).scheduled, false)

  -- Task is now at row 4 (shifted down by the insertion).
  local task_row_new = 4
  local shifted_line = get_line(bufnr, task_row_new)
  MiniTest.expect.equality(shifted_line ~= nil and shifted_line:find("Shift task") ~= nil, true)

  -- Corrupt the task at its new position.
  -- Without snapshot adjustment this would NOT trigger a revert.
  set_line(bufnr, task_row_new, "SNAPSHOT MISS")

  local reverted = flush(500, function()
    local cur = get_line(bufnr, task_row_new)
    return cur ~= nil and cur ~= "SNAPSHOT MISS"
  end)

  MiniTest.expect.equality(reverted, true)

  local final = get_line(bufnr, task_row_new)
  MiniTest.expect.equality(final ~= nil and final:find("Shift task") ~= nil, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T10: undojoin — pressing u after revert skips the CORRUPTED state ─────────
-- Task acceptance criterion: pressing u after a managed-region revert should
-- NOT cycle through the corrupted intermediate state.  undojoin merges the
-- revert change with the user's preceding edit so pressing u undoes them as a
-- single unit, returning to the pre-corruption buffer state.

T["revert: undojoin — pressing u after revert does not show CORRUPTED state"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] Undo task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  -- Open the buffer in a floating window so normal-mode undo works.
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
    style = "minimal",
  })

  render.render_buffer(bufnr, nil)

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  MiniTest.expect.equality(canonical ~= nil and canonical:find("Undo task") ~= nil, true)

  -- Corrupt the managed row.
  set_line(bufnr, task_row, "CORRUPTED")

  -- Wait for the revert to fire (flush drains vim.schedule callbacks).
  local reverted = flush(500, function()
    local cur = get_line(bufnr, task_row)
    return cur ~= nil and cur ~= "CORRUPTED"
  end)
  MiniTest.expect.equality(reverted, true)

  -- Buffer is back to canonical after revert.  Now press u.
  -- With undojoin: the revert was merged with the user's corruption, so pressing
  -- u undoes both in one step → returns to the pre-corruption state (canonical).
  -- Without undojoin: u would undo only the revert → CORRUPTED would reappear.
  vim.api.nvim_set_current_win(win)
  vim.cmd("normal! u")

  -- Allow any on_lines triggered by the undo to settle.
  flush_events(100)

  -- The CORRUPTED text must not be visible in the buffer at any row.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local corrupted_found = false
  for _, l in ipairs(buf_lines) do
    if l == "CORRUPTED" then
      corrupted_found = true
      break
    end
  end
  MiniTest.expect.equality(corrupted_found, false)

  pcall(vim.api.nvim_win_close, win, true)
  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
