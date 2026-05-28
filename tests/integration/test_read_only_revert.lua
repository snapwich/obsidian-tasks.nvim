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
--   • undojoin: pressing u after a revert does not reveal the corrupted state.
--   • Sequential reverts: the debounce flag resets between cycles.
--   • Snapshot adjustment: prose insertions above the managed region are tracked.
--
-- Uses a stub index (no vault walk required).
-- render.configure({default_folded=false}) keeps folds out of the picture so
-- tests can rely on stable row numbers without needing a window open.
--
-- NOTE on async vs synchronous:
--   mini.test runs each case inside a vim.schedule callback.  When a case calls
--   vim.wait(N, cond_fn), other queued case-callbacks fire and steal the event
--   loop, so assertions after the wait are never reached — the test silently
--   "passes" as a no-op.  All revert assertions therefore use
--   revert._flush_pending(bufnr), which runs the revert synchronously without
--   yielding to the event loop, making every assertion reachable and deterministic.

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

--- Get line at 0-indexed row in bufnr.
local function get_line(bufnr, row0)
  local lines = vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)
  return lines[1]
end

--- Set line at 0-indexed row in bufnr (single-line replacement).
local function set_line(bufnr, row0, text)
  vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { text })
end

-- ── T1: typing on a rendered task line reverts synchronously ──────────────────
-- Uses an empty-line (DELETE) edit — the unambiguous revert path.
--
-- With the P5 flush wiring, single-line edits that preserve task structure
-- (MUTATE / REPAIR_AND_MUTATE) are propagated to source by flush() rather than
-- reverted.  DELETE (empty or whitespace-only new_text) is NOT propagated by
-- flush — it has no meaningful source representation — so do_revert always
-- restores the canonical managed row for this classification.
--
-- Using DELETE here avoids the semantic conflict flagged in the architect review:
-- a non-empty unstructured string would be classified REPAIR_AND_MUTATE (flush
-- attempts a write that re-adds the missing prefix) rather than reverting.  An
-- empty line is classified DELETE, flush skips it, and do_revert rerenders
-- canonical text — the intent of this test.

T["revert: blank (DELETE) edit on rendered task line reverts to canonical text"] = function()
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

  -- Blank out the task line (DELETE classification: new_text is empty →
  -- flush does not propagate empty rows; do_revert restores canonical text).
  -- on_lines fires synchronously and sets _scheduled.
  set_line(bufnr, task_row, "")
  eq(get_line(bufnr, task_row), "")
  eq(revert._debug_state(bufnr).scheduled, true)

  -- Run the revert synchronously (bypasses vim.schedule so assertions are reachable).
  revert._flush_pending(bufnr)

  -- Line must be back to the canonical task text.
  local final = get_line(bufnr, task_row)
  MiniTest.expect.equality(final ~= nil and final:find("My task") ~= nil, true)
  eq(revert._debug_state(bufnr).scheduled, false)

  -- After a revert the buffer text matches canonical and the plugin owns all
  -- mutations, so the modified flag must be clear.  (Buffer hygiene contract.)
  eq(vim.bo[bufnr].modified, false)

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

  -- Row 0 is prose (not managed).  on_lines fires synchronously.
  set_line(bufnr, 0, "EDITED PROSE")

  -- No revert must be scheduled (checked immediately — on_lines is synchronous).
  eq(revert._debug_state(bufnr).scheduled, false)
  eq(get_line(bufnr, 0), "EDITED PROSE")

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

  -- No revert scheduled.
  eq(revert._debug_state(bufnr).scheduled, false)
  eq(get_line(bufnr, 1), "EDITED QUERY")

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
  -- The suppress wrapping in render/init.lua must prevent on_lines from
  -- seeing the rerender's buffer mutations.
  render.rerender_buffer(bufnr, nil)

  -- No spurious revert must be scheduled.
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
-- Verifies that the full flush+revert flow keeps non-managed (prose) portions
-- of a straddling paste while resolving the managed row.
--
-- Previous version (pre-flush-layer) called revert._flush_pending alone, which
-- exercised only the rerender path.  With the flush layer landed (P5+), the
-- managed row is now classified by flush() first.  "CORRUPTED TASK" has no
-- bullet/checkbox so it classifies as REPAIR_AND_MUTATE; the stub source path
-- doesn't exist on disk, so flush's per-file write fails and (per Q15) reverts
-- the row to canonical.  Either way the user-visible outcome — "CORRUPTED
-- TASK" gone, "NEW PROSE LINE" survives — is the same.

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

  local task_row = 4

  -- Paste: replace rows 0..task_row (inclusive) with new content.
  vim.api.nvim_buf_set_lines(bufnr, 0, task_row + 1, false, {
    "NEW PROSE LINE",
    "```tasks",
    "not done",
    "```",
    "CORRUPTED TASK",
  })

  -- on_lines fires synchronously: the paste touched the managed row.
  eq(revert._debug_state(bufnr).scheduled, true)

  -- Drain the FULL pipeline: flush first (so the new flush-layer flow is
  -- exercised), then revert.  flush attempts the REPAIR_AND_MUTATE write,
  -- which fails on the fake stub source path → Q15 per-file revert.
  local edit_mod = require("obsidian-tasks.render.edit")
  edit_mod.flush(bufnr)
  revert._flush_pending(bufnr)

  local all = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local corrupted_found = false
  local new_prose_found = false
  for _, l in ipairs(all) do
    if l == "CORRUPTED TASK" then
      corrupted_found = true
    end
    if l == "NEW PROSE LINE" then
      new_prose_found = true
    end
  end
  MiniTest.expect.equality(corrupted_found, false, "managed row must not show 'CORRUPTED TASK' after flush+revert")
  MiniTest.expect.equality(new_prose_found, true, "non-managed prose line must survive flush+revert")

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T8: sequential reverts — debounce flag resets between cycles ─────────────
-- Regression guard for mutation: removing `_scheduled[bufnr] = nil` inside
-- do_revert would cause every second edit to silently skip the revert.
-- Two synchronous _flush_pending cycles catch this without async waits.
--
-- Uses a blank-line (DELETE) edit so that the edit-flush layer does not attempt
-- to propagate it to source (flush skips DELETE rows) and do_revert always
-- has the final say.  Arbitrary non-blank text would be classified as
-- REPAIR_AND_MUTATE and the flush layer would try to write it to source —
-- using blank text avoids this semantic conflict without changing the test intent.

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

  -- First DELETE (blank-line) edit and revert cycle.
  set_line(bufnr, task_row, "")
  eq(revert._debug_state(bufnr).scheduled, true)
  revert._flush_pending(bufnr)
  eq(revert._debug_state(bufnr).scheduled, false)

  local mid = get_line(bufnr, task_row)
  MiniTest.expect.equality(mid ~= nil and mid:find("Cycle task") ~= nil, true)

  -- Second DELETE: debounce flag must have been reset by _flush_pending.
  -- Without the `_scheduled[bufnr] = nil` reset in do_revert this would no-op.
  set_line(bufnr, task_row, "")
  eq(revert._debug_state(bufnr).scheduled, true)
  revert._flush_pending(bufnr)
  eq(revert._debug_state(bufnr).scheduled, false)

  local final = get_line(bufnr, task_row)
  MiniTest.expect.equality(final ~= nil and final:find("Cycle task") ~= nil, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T9: snapshot adjusts after prose insertion above managed region ───────────
-- Regression guard for mutation: removing the snapshot-shift block in revert.lua
-- would cause on_lines to use stale (pre-shift) positions and miss edits on the
-- managed row after it has been displaced by a prose insertion.

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

  MiniTest.expect.equality(#vim.api.nvim_buf_get_lines(bufnr, 0, -1, false) >= 4, true)
  MiniTest.expect.equality(get_line(bufnr, 3):find("Shift task") ~= nil, true)

  -- Insert a prose line at the top (row 0).  on_lines fires synchronously.
  -- This is NOT in the managed region so no revert fires, but the snapshot
  -- must shift so row 4 (not row 3) is now treated as managed.
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "inserted prose" })
  eq(revert._debug_state(bufnr).scheduled, false) -- prose edit, no revert

  -- Task is now at row 4 (shifted down by +1).
  local task_row_new = 4
  MiniTest.expect.equality(get_line(bufnr, task_row_new):find("Shift task") ~= nil, true)

  -- Corrupt the task at its new (shifted) position.
  -- Without snapshot adjustment this would NOT trigger a revert.
  set_line(bufnr, task_row_new, "SNAPSHOT MISS")
  eq(revert._debug_state(bufnr).scheduled, true) -- managed row touched

  revert._flush_pending(bufnr)

  local final = get_line(bufnr, task_row_new)
  MiniTest.expect.equality(final ~= nil and final:find("Shift task") ~= nil, true)

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T10: undojoin — pressing u after revert skips the CORRUPTED state ─────────
-- Task acceptance criterion: pressing u after a managed-region revert must NOT
-- cycle through the corrupted intermediate state.  undojoin merges the revert
-- change with the user's preceding edit so pressing u undoes them as one unit,
-- returning to the pre-corruption buffer state.

-- Uses a blank-line (DELETE) edit so that the edit-flush layer does not attempt
-- to propagate it to source (flush skips DELETE rows) and do_revert always
-- has the final say.  See T8 comment for rationale.
T["revert: undojoin — pressing u after revert does not show CORRUPTED state"] = function()
  render.configure({ default_folded = false })
  local restore = install_one_task_stub("- [ ] Undo task")

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
  })

  -- Open the buffer in a floating window (required for normal! u and for
  -- undojoin to apply to the correct current buffer).
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

  -- Blank out the managed row (DELETE classification).
  -- bufnr is current (entered via open_win above).
  set_line(bufnr, task_row, "")
  eq(revert._debug_state(bufnr).scheduled, true)

  -- Run the revert synchronously.  do_revert calls undojoin with bufnr current,
  -- merging the revert into the user's preceding change.
  revert._flush_pending(bufnr)

  -- Buffer is back to canonical.  Now press u.
  -- With undojoin: pressing u undoes the merged block (blank + revert) in one
  -- step → returns to the pre-blank state (canonical task text).
  -- Without undojoin: u would undo only the revert → blank line would reappear.
  vim.api.nvim_set_current_win(win)
  vim.cmd("normal! u")

  -- Blank line must not be present anywhere in the buffer after undo.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local blank_task_found = false
  for _, l in ipairs(buf_lines) do
    -- The managed task row should never be blank after undo.
    if l == "" and #l == 0 then
      blank_task_found = true
      break
    end
  end
  -- After undo, task row should contain the canonical task text again.
  local task_line = get_line(bufnr, task_row)
  MiniTest.expect.equality(task_line ~= nil and task_line:find("Undo task") ~= nil, true)

  pcall(vim.api.nvim_win_close, win, true)
  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── T13: pure insert at managed region boundary — revert covers both ─────────
-- Regression test for the `o` / `O`-on-folded-fence corruption.
-- Pressing `o` on a closed query-fence fold lands the new blank line at the
-- first row of the rendered region (the row immediately after the closing
-- fence).  Without the snapshot-shift fix, the revert deleted the pre-edit
-- range and left the user's blank + one trailing rendered task behind, then
-- cascaded corruption into every block below.

T["revert: pure insert at region start row — both inserted row and managed rows revert"] = function()
  render.configure({ default_folded = false })

  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  -- Two-block stub so we can verify the second block's positions also recover.
  local task_a = task_parse.parse("- [ ] Block A task")
  local task_b = task_parse.parse("- [ ] Block B task")
  assert(task_a and task_b)
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }
  -- Each tasks_in() call returns the same single task — block A and block B
  -- each get one row.  Per-call iterator so two render passes both see a task.
  index_mod.tasks_in = function(_)
    local returned = false
    return function()
      if not returned then
        returned = true
        return task_a, "/vault/stub.md", 1
      end
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end

  local bufnr = make_buf({
    "```tasks", -- row 0  (block A fence start)
    "not done", -- row 1
    "```", -- row 2
    "", -- row 3  (separator)
    "```tasks", -- row 4  (block B fence start)
    "not done", -- row 5
    "```", -- row 6
    "## Notes", -- row 7  trailing prose (keeps block B off EOF, no sentinel)
  })

  render.render_buffer(bufnr, nil)
  -- After render:
  --   row 0-2 : block A fence
  --   row 3   : block A's rendered task   ← managed region [3, 3]
  --   row 4   : ""
  --   row 5-7 : block B fence
  --   row 8   : block B's rendered task   ← managed region [8, 8]
  --   row 9   : "## Notes"

  local pre_line_count = vim.api.nvim_buf_line_count(bufnr)
  eq(pre_line_count, 10)

  -- Simulate `o` on the closed block A fold landing at row 3 (the first row
  -- of the rendered region) — what Vim does after foldopen+=insert resolves
  -- the keystroke.
  vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "" })

  -- Run the scheduled revert synchronously.
  revert._flush_pending(bufnr)

  -- Both blocks back to their pre-edit positions; no stray rendered tasks.
  local post_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#post_lines, 10)
  eq(post_lines[1], "```tasks")
  eq(post_lines[3], "```")
  eq(post_lines[4], "- [ ] Block A task [[stub]]")
  eq(post_lines[5], "")
  eq(post_lines[6], "```tasks")
  eq(post_lines[8], "```")
  eq(post_lines[9], "- [ ] Block A task [[stub]]")
  eq(post_lines[10], "## Notes")

  render.clear_buffer(bufnr)
  index_mod.tasks_in = saved.tasks_in
  index_mod.set_render_paths = saved.set_render_paths
  index_mod.clear_render_paths = saved.clear_render_paths
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
