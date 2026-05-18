-- tests/integration/test_insert_delete.lua
-- RED-phase integration tests for P8: INSERT + block-aware DELETE.
--
-- Locked decisions under test:
--   Q4  Insertion anchor on dashboard: first managed extmark above the new row.
--       No neighbor above → revert + notify (matches current top-of-dashboard
--       behavior but adds a notify).
--   Q11 Source-side insert position: after the anchor's continuation block.
--       New task adopts the anchor's indent level.
--   Q14 Delete with continuation: block-aware delete of task + continuation
--       lines.  Undo (P1 undo ring) is the safety net.
--
-- Expected failure reasons:
--   INSERT tests — INSERT classification is currently reverted (not propagated
--     to source); flush does not call insert_after_anchor.
--   DELETE-with-continuation tests — current DELETE uses count=1 (single row);
--     continuation lines are left in source.
--   Top-of-dashboard paste test — flush does not detect INSERT at all;
--     no notify is emitted.
--   Combined test — both INSERT and DELETE-with-continuation fail.
--
-- Note: "dd no continuation" passes in RED because P7 already handles
-- single-row DELETE correctly.  It is included as a regression guard.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local edit_mod = require("obsidian-tasks.render.edit")
local log = require("obsidian-tasks.log")

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

local function read_file(path)
  local b = vim.fn.bufnr(path, false)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, 0, -1, false)
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

--- Stub the index to serve tasks read from one or more source files.
--- Returns a restore function.
local function install_multi_file_stub(src_paths)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.tasks_in = function(_)
    local all = {}
    for _, sp in ipairs(src_paths) do
      local ok, lines = pcall(vim.fn.readfile, sp)
      if ok then
        for line_num, line in ipairs(lines) do
          local task = task_parse.parse(line)
          if task then
            all[#all + 1] = { task = task, path = sp, line_num = line_num }
          end
        end
      end
    end
    local i = 0
    return function()
      i = i + 1
      if all[i] then
        return all[i].task, all[i].path, all[i].line_num
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

local function install_file_stub(src_path)
  return install_multi_file_stub({ src_path })
end

--- Standard two-task dashboard scaffold from one source file.
--- src_lines: lines to write to the source file.
--- Returns: bufnr, src_path, cleanup.
local function setup_dashboard(src_lines)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile(src_lines)
  local restore = install_file_stub(src_path)
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)
  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local sb = vim.fn.bufnr(src_path, false)
    if sb ~= -1 then
      vim.api.nvim_buf_delete(sb, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end
  return bufnr, src_path, cleanup
end

--- Capture log.warn messages emitted during fn().
--- Returns: warned (bool), msgs (list of string).
local function capture_warns(fn)
  local warned = false
  local msgs = {}
  local orig = log.warn
  log.warn = function(msg)
    warned = true
    msgs[#msgs + 1] = tostring(msg)
  end
  fn()
  log.warn = orig
  return warned, msgs
end

-- Task rows start at row 3 in a single-block "```tasks / query / ```" dashboard.
local TASK_ROW = 3

-- ── Q4+Q11: Paste above managed row — source gets new task ───────────────────
--
-- RED: FAILS — INSERT classification is not propagated to source.
--   flush() does not detect the new row (it has no meta in meta_snapshot)
--   and does not call insert_after_anchor.  Source remains at 2 lines.
-- GREEN contract: when a task-like row appears in a managed region without
--   a meta entry, flush detects it as INSERT, finds the first managed extmark
--   above it as anchor (Q4), and calls insert_after_anchor(src, anchor_row,
--   anchor_indent, new_line) (Q11).  Source gains the new task after the
--   anchor's continuation block.

T["insert/delete: paste above managed row — source gets new task after anchor"] = function()
  -- Source: anchor task followed by next task (no continuation).
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Anchor task #task", -- row 0
    "- [ ] Next task #task", -- row 1
  })

  -- Dashboard rows: TASK_ROW = anchor, TASK_ROW+1 = next.
  -- Simulate paste: insert a new task row BETWEEN anchor and next.
  -- This is row TASK_ROW+1 (pushing "Next task" to TASK_ROW+2).
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW + 1, TASK_ROW + 1, false, { "- [ ] New task #task" })

  -- Flush (the real implementation schedules; tests call directly).
  edit_mod.flush(bufnr)

  -- GREEN expectation: source has 3 lines, new task inserted after anchor.
  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source should have 3 lines after insert")
  eq(src_lines[1], "- [ ] Anchor task #task", "anchor unchanged at source row 0")
  eq(src_lines[2], "- [ ] New task #task", "new task at source row 1 (after anchor)")
  eq(src_lines[3], "- [ ] Next task #task", "next task pushed to source row 2")

  cleanup()
end

-- ── Q4+Q11: Type new task on unmanaged row — source-side insertion ────────────
--
-- RED: FAILS — same reason as paste test above; INSERT not propagated.
-- GREEN contract: typing a complete task line on an unmanaged row within the
--   managed region triggers the same INSERT → insert_after_anchor path.

T["insert/delete: type new task between managed rows — source-side insertion"] = function()
  -- Source: two tasks; user types a new task between them on the dashboard.
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] First task #task", -- row 0
    "- [ ] Second task #task", -- row 1
  })

  -- Simulate typing a new task line between First and Second on the dashboard.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW + 1, TASK_ROW + 1, false, { "- [ ] Typed task #task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 3, "source should have 3 lines after typing new task")
  eq(src_lines[2], "- [ ] Typed task #task", "typed task propagated to source after first task")

  cleanup()
end

-- ── Auto-prefix bare INSERT lines with "- [ ] " ───────────────────────────────
--
-- User types a bare word like "test" on a new dashboard line.  Without a
-- structural prefix the parser rejects the line so it never appears in the
-- dashboard re-render — but the raw text is still written to source as orphan
-- content.  flush() must repair the prefix on INSERT (same logic as
-- REPAIR_AND_MUTATE) so the typed line becomes a task in source.

T["insert/delete: bare-text INSERT gets auto-prefixed with - [ ]"] = function()
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Anchor task #task", -- row 0
  })

  -- User types just "test" on a new line below the anchor.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW + 1, TASK_ROW + 1, false, { "test" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 2, "source should have 2 lines after bare-text INSERT")
  eq(src_lines[1], "- [ ] Anchor task #task", "anchor unchanged")
  eq(src_lines[2], "- [ ] test", "bare-text INSERT auto-prefixed with - [ ]")

  cleanup()
end

T["insert/delete: INSERT with bullet but no checkbox gets [ ] inserted"] = function()
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Anchor task #task",
  })

  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW + 1, TASK_ROW + 1, false, { "- something" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(src_lines[2], "- [ ] something", "bullet-but-no-checkbox INSERT gets [ ] inserted")

  cleanup()
end

-- ── Splitting a task with mid-line <CR> creates two tasks ─────────────────────
--
-- User presses Enter mid-task: the original managed row becomes the first half
-- (MUTATE) and a new unmanaged row appears below holding the second half
-- (INSERT).  The first half stays a task (already has its prefix); the second
-- half is bare text that must be auto-prefixed so it becomes its own task on
-- re-render (no orphan content left in source).

T["insert/delete: split mid-task creates two tasks in source"] = function()
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] need to merge dependabot updates", -- row 0
  })

  -- Simulate <CR> after "need to ": original row becomes two rows on the
  -- dashboard.  In the real flow on_lines fires for this single change; here
  -- we model it via nvim_buf_set_lines replacing the single row with two.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 1, false, {
    "- [ ] need to ",
    "merge dependabot updates",
  })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 2, "source should contain two tasks after mid-task split")
  eq(src_lines[1], "- [ ] need to ", "first half remains the original task (truncated)")
  eq(src_lines[2], "- [ ] merge dependabot updates", "second half becomes its own task")

  cleanup()
end

-- ── Q14: dd task with continuation — source removes task + continuation ────────
--
-- RED: FAILS — current DELETE uses count=1; source row 0 (task) is removed but
--   continuation lines (rows 1, 2) remain in source.  Test assertion that
--   source is empty fails.
-- GREEN contract: flush detects the DELETE and calls delete_block(src, row, indent)
--   which computes count=N (task + all continuation rows) and applies it via
--   apply_source_edit with count=N.

T["insert/delete: dd task with continuation — source removes task and block"] = function()
  -- Source: a task followed by non-task continuation lines (plain text, indented).
  -- The continuation lines do NOT parse as tasks so only the parent task is
  -- rendered in the dashboard (single managed row).
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Task with notes #task", -- row 0, indent 0 → rendered in dashboard
    "  Some continuation note", -- row 1, indent 2, not a task → NOT rendered
    "  More continuation", -- row 2, indent 2, not a task → NOT rendered
  })

  -- Dashboard: only the parent task at TASK_ROW; continuation lines invisible.
  -- Simulate dd: delete the managed task row from the buffer.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 1, false, {})

  edit_mod.flush(bufnr)

  -- GREEN expectation: all 3 source rows deleted (task + 2 continuation lines).
  local src_lines = read_file(src_path)
  eq(#src_lines, 0, "source should be empty — dd removes task and its continuation block")

  cleanup()
end

-- ── Q14: dd task with no continuation — source removes only task line ─────────
--
-- PASSES in RED (P7 already handles single-row DELETE correctly).
-- Included as a regression guard: P8's block-aware delete must not accidentally
-- remove extra lines when the task has no continuation.

T["insert/delete: dd task with no continuation — source removes only the task"] = function()
  -- Source: two tasks with no continuation between them.
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Task to delete #task", -- row 0
    "- [ ] Sibling task #task", -- row 1
  })

  -- Simulate dd on the first task.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 1, false, {})

  edit_mod.flush(bufnr)

  -- Source should have only the sibling remaining.
  local src_lines = read_file(src_path)
  eq(#src_lines, 1, "source should have 1 line — only the deleted task is removed")
  eq(src_lines[1], "- [ ] Sibling task #task", "sibling task remains in source")

  cleanup()
end

-- ── Q4: Top-of-dashboard paste — revert + notify ──────────────────────────────
--
-- RED: FAILS — flush does not detect the INSERT at all (the new row has no meta
--   and is not currently inspected by flush); no notify is emitted.
-- GREEN contract: when an INSERT row has no managed extmark above it (Q4: no
--   anchor), flush reverts the dashboard row and emits a warn notification.
--   Source must NOT be mutated.

T["insert/delete: top-of-dashboard paste — reverts and emits notify"] = function()
  -- Source: single task (will render at TASK_ROW).
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Only task #task", -- row 0
  })

  local src_before = read_file(src_path)

  -- Simulate paste AT the top of the managed region (row 3) — before any managed
  -- task.  No managed extmark exists above row 3, so there is no anchor.
  local warned, _warn_msgs = capture_warns(function()
    vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW, false, { "- [ ] Orphan paste #task" })
    edit_mod.flush(bufnr)
  end)

  -- Source must be unchanged (no-anchor revert).
  local src_after = read_file(src_path)
  eq(src_after, src_before, "source must not be mutated when no anchor is found")

  -- A warn notification must be emitted (Q4 revert + notify).
  eq(warned, true, "top-of-dashboard paste must emit a warn notification (no anchor above)")

  cleanup()
end

-- ── Q15: Insert into read-only source — revert isolates, other file proceeds ───
--
-- RED: FAILS — INSERT is not propagated at all; both files are unchanged;
--   no isolation logic runs because flush never attempts insert_after_anchor.
-- GREEN contract: when insert_after_anchor fails for a read-only source file,
--   that file's dashboard INSERT row is reverted; other files in the same tick
--   proceed.  Specifically, a DELETE in file B in the same tick must still be
--   applied even if the INSERT into file A (read-only) fails.

T["insert/delete: read-only source — insert reverts, other file DELETE proceeds"] = function()
  render.configure({ default_folded = false })

  -- File A (read-only): has anchor + next tasks.
  local src_a = make_tmpfile({
    "- [ ] Anchor A #task", -- row 0
    "- [ ] Next A #task", -- row 1
  })
  -- File B (writable): has a single task to delete.
  local src_b = make_tmpfile({
    "- [ ] Delete me B #task", -- row 0
  })

  local restore = install_multi_file_stub({ src_a, src_b })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Determine layout: A rows come before B rows (tasks_in order).
  -- TASK_ROW=3: src_a row 0, TASK_ROW+1=4: src_a row 1, TASK_ROW+2=5: src_b row 0.
  local ANCHOR_A_DASH = TASK_ROW -- dashboard row for "Anchor A"
  local NEXT_A_DASH = TASK_ROW + 1 -- dashboard row for "Next A"
  local DELETE_B_DASH = TASK_ROW + 2 -- dashboard row for "Delete me B"

  local src_a_before = read_file(src_a)
  local src_b_before = read_file(src_b)

  -- Make file A read-only so insert_after_anchor will fail.
  vim.fn.system({ "chmod", "-w", src_a })

  -- Same tick: INSERT into A (between A's rows) + DELETE B's task.
  vim.api.nvim_buf_set_lines(bufnr, NEXT_A_DASH, NEXT_A_DASH, false, { "- [ ] New A #task" })
  -- After insertion, B's dashboard row is now at DELETE_B_DASH + 1.
  vim.api.nvim_buf_set_lines(bufnr, DELETE_B_DASH + 1, DELETE_B_DASH + 2, false, {})

  edit_mod.flush(bufnr)

  -- Restore write permission for cleanup.
  vim.fn.system({ "chmod", "+w", src_a })

  -- File A: source unchanged (INSERT failed due to read-only).
  local src_a_after = read_file(src_a)
  eq(src_a_after, src_a_before, "read-only file A must not be mutated")

  -- File B: DELETE succeeded (Q15 isolation — other file proceeds).
  local src_b_after = read_file(src_b)
  eq(#src_b_after, 0, "file B DELETE must succeed even though file A INSERT failed")

  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local sb_a = vim.fn.bufnr(src_a, false)
    if sb_a ~= -1 then
      vim.api.nvim_buf_delete(sb_a, { force = true })
    end
    local sb_b = vim.fn.bufnr(src_b, false)
    if sb_b ~= -1 then
      vim.api.nvim_buf_delete(sb_b, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_a)
    vim.fn.delete(src_b)
  end
  cleanup()
end

-- ── Combined: same-tick paste + dd across two files → single undo block ───────
--
-- RED: FAILS — INSERT not propagated (source A unchanged) AND DELETE uses
--   count=1 (source B has continuation remnant).  Both assertions fail.
-- GREEN contract: a single flush tick with INSERT in file A and block-DELETE
--   in file B applies both operations atomically.  One dashboard_undo() call
--   reverses both source mutations (Q13 multi-file undo merge).

T["insert/delete: combined tick — paste in A + dd-with-continuation in B → both apply + single undo"] = function()
  render.configure({ default_folded = false })

  -- File A: anchor + next tasks.
  local src_a = make_tmpfile({
    "- [ ] Anchor A #task", -- row 0
    "- [ ] Next A #task", -- row 1
  })
  -- File B: task with non-task continuation lines.
  local src_b = make_tmpfile({
    "- [ ] Task B to delete #task", -- row 0, rendered
    "  continuation note B", -- row 1, not a task, not rendered
  })

  local restore = install_multi_file_stub({ src_a, src_b })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Dashboard layout: src_a tasks at rows 3 and 4; src_b task at row 5.
  local INSERT_AT = TASK_ROW + 1 -- paste between A's rows
  local DELETE_B_DASH = TASK_ROW + 2 -- B's task row

  -- Same-tick action: insert new task in A + dd B's task.
  vim.api.nvim_buf_set_lines(bufnr, INSERT_AT, INSERT_AT, false, { "- [ ] New A task #task" })
  -- After the insert, B's row shifted down by 1.
  vim.api.nvim_buf_set_lines(bufnr, DELETE_B_DASH + 1, DELETE_B_DASH + 2, false, {})

  edit_mod.flush(bufnr)

  -- GREEN expectation: A has 3 lines, B has 0 lines.
  local src_a_after = read_file(src_a)
  eq(#src_a_after, 3, "source A should have 3 lines after insert")
  eq(src_a_after[2], "- [ ] New A task #task", "new task at source A row 1")

  local src_b_after = read_file(src_b)
  eq(#src_b_after, 0, "source B should be empty — task + continuation deleted")

  -- GREEN addition: single u reverses BOTH mutations.
  local cmd_mod = require("obsidian-tasks.cmd")
  local ok_undo = cmd_mod.dashboard_undo(bufnr)
  eq(ok_undo, true, "single dashboard_undo must succeed after combined insert+delete")

  local src_a_undone = read_file(src_a)
  local src_b_undone = read_file(src_b)
  eq(#src_a_undone, 2, "undo must restore src_a to 2 lines")
  eq(#src_b_undone, 2, "undo must restore src_b to 2 lines (task + continuation)")

  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    for _, sp in ipairs({ src_a, src_b }) do
      local sb = vim.fn.bufnr(sp, false)
      if sb ~= -1 then
        vim.api.nvim_buf_delete(sb, { force = true })
      end
      vim.fn.delete(sp)
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  cleanup()
end

-- ── Cross-task feature-verification tests (GREEN phase) ───────────────────────
--
-- These tests cover acceptance criteria from the parent feature (ot-q2da)
-- that require multiple P8 components to work together.

-- ── Insert into deeply nested anchor (indented task with grandchildren) ────────
--
-- GREEN contract: when the anchor task has an indented continuation block
-- (grandchildren), insert_after_anchor walks past ALL continuation lines so
-- the new task lands after the deepest continuation line, at the anchor's
-- indent level.

T["cross-task: insert into deeply nested anchor — new task after deepest continuation"] = function()
  -- Source layout:
  --   row 0: "- [ ] Outer task #task"          indent 0, rendered (TASK_ROW)
  --   row 1: "  - [ ] Anchor task #task"        indent 2, rendered (TASK_ROW+1)
  --   row 2: "    Some grandchild note"         indent 4, NOT a task → not rendered
  --   row 3: "    More grandchild note"         indent 4, NOT a task → not rendered
  --   row 4: "- [ ] Another task #task"         indent 0, rendered (TASK_ROW+2)
  local src_path = make_tmpfile({
    "- [ ] Outer task #task",
    "  - [ ] Anchor task #task",
    "    Some grandchild note",
    "    More grandchild note",
    "- [ ] Another task #task",
  })
  render.configure({ default_folded = false })
  local restore = install_file_stub(src_path)
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local sb = vim.fn.bufnr(src_path, false)
    if sb ~= -1 then
      vim.api.nvim_buf_delete(sb, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end

  -- Dashboard: outer at TASK_ROW(3), anchor at TASK_ROW+1(4), another at TASK_ROW+2(5).
  -- Insert new task between anchor and another (at dashboard row 5, pushing another to 6).
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW + 2, TASK_ROW + 2, false, { "  - [ ] New nested task #task" })

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  -- Source should have 6 lines: the new task inserted after "More grandchild note" (row 4)
  -- and before "Another task" (which was at row 4, now row 5).
  eq(#src_lines, 6, "source should have 6 lines after inserting nested task")
  -- The new task lands at source row 4 (0-indexed), i.e. lines[5] (1-indexed).
  eq(src_lines[5], "  - [ ] New nested task #task", "new task lands after deepest continuation at correct indent")
  -- "Another task" is pushed to the last row.
  eq(src_lines[6], "- [ ] Another task #task", "outer sibling task moved to last row")

  cleanup()
end

-- ── Delete task whose continuation includes another task-like source line ──────
--
-- Behavior definition:
--   The source has an outer (not-done) task whose continuation block contains
--   a done subtask and a note — both indented deeper than the outer task.
--   The done subtask does NOT match the "not done" query, so it is NOT rendered
--   on the dashboard (no extmark, no managed row for it).
--
--   When the user `dd`s the outer task from the dashboard, delete_block walks
--   the outer task's continuation in source: both the done subtask and the note
--   are indented deeper → they are part of the continuation block → count=3.
--
--   Expected result: all 3 source lines are deleted.
--
-- Edge-case note (for rare "both tasks rendered" scenario):
--   If the inner task were NOT done (thus rendered on the dashboard), the inner
--   task's dashboard row would shift up when the outer task row is deleted.
--   flush() would then see the inner task's text at the outer task's snapshot
--   position and classify it as a MUTATE rather than a DELETE — resulting in
--   the outer source row being overwritten with the inner task text.  This is a
--   known limitation for the rare case where a task's continuation contains
--   another rendered managed task.  A future phase may improve handling by
--   detecting same-tick row shifts.

T["cross-task: delete outer task whose continuation includes a task-like done subtask — whole block removed"] = function()
  -- Source:
  --   row 0: outer task (not done, indent 0) → rendered at TASK_ROW
  --   row 1: done subtask (indent 2) → NOT rendered ("not done" query filters it)
  --   row 2: outer note (indent 2) → NOT a task, NOT rendered
  local src_path = make_tmpfile({
    "- [ ] Outer task #task",
    "  - [x] Done subtask #task",
    "  outer note",
  })
  render.configure({ default_folded = false })
  local restore = install_file_stub(src_path)
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local sb = vim.fn.bufnr(src_path, false)
    if sb ~= -1 then
      vim.api.nvim_buf_delete(sb, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end

  -- Dashboard: only outer task at TASK_ROW (done subtask is filtered out by "not done").
  -- Simulate `dd` on the outer task.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 1, false, {})

  edit_mod.flush(bufnr)

  -- Source: all 3 lines removed — outer task block spans rows 0-2 because
  -- both the done subtask and the note are indented deeper than outer_indent=0.
  local src_lines = read_file(src_path)
  eq(#src_lines, 0, "delete_block removes outer task + done subtask + note from source (whole block)")

  cleanup()
end

-- ── Combination with P7 mass-delete gate ──────────────────────────────────────

-- ── feat-3 gate: 2 INSERTs + 0 DELETEs — gate does not fire, both propagate ───

T["cross-task/gate: 2 INSERTs + 0 DELETEs — gate does not fire, both propagate"] = function()
  -- Source: 3 tasks; user inserts 2 new tasks between the first and second.
  -- delete_count == 0 so the mass-delete gate never fires regardless of
  -- insert count.
  local src_path = make_tmpfile({
    "- [ ] Task A #task",
    "- [ ] Task B #task",
    "- [ ] Task C #task",
  })
  render.configure({ default_folded = false })
  local restore = install_file_stub(src_path)
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  local function cleanup()
    render.clear_buffer(bufnr)
    restore()
    revert._cleanup(bufnr)
    local sb = vim.fn.bufnr(src_path, false)
    if sb ~= -1 then
      vim.api.nvim_buf_delete(sb, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end

  -- Insert 2 rows at once between Task A (TASK_ROW) and Task B (TASK_ROW+1).
  -- Both rows land inside the region and are detected as INSERT candidates.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW + 1, TASK_ROW + 1, false, {
    "- [ ] Insert1 #task",
    "- [ ] Insert2 #task",
  })

  edit_mod.flush(bufnr)

  -- Gate did not fire (0 deletes) → both inserts propagate → source has 5 lines.
  local src_lines = read_file(src_path)
  eq(#src_lines, 5, "both inserts must propagate (gate not triggered for 0 DELETEs)")
  local has_i1, has_i2 = false, false
  for _, l in ipairs(src_lines) do
    if l:find("Insert1") then
      has_i1 = true
    end
    if l:find("Insert2") then
      has_i2 = true
    end
  end
  eq(has_i1, true, "Insert1 must be in source")
  eq(has_i2, true, "Insert2 must be in source")

  cleanup()
end

-- ── feat-3 gate: 0 INSERTs + 2 DELETEs, intact block → both propagate ─────────

T["cross-task/gate: 0 INSERTs + 2 DELETEs intact block — gate passes, both propagate"] = function()
  -- Source: 2 tasks; user deletes both (visual-line 2dd). Block is intact.
  -- Gate fires (delete_count >= 2) but block is intact → propagate.
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Task One #task",
    "- [ ] Task Two #task",
  })

  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 2, false, {})

  edit_mod.flush(bufnr)

  local src_lines = read_file(src_path)
  eq(#src_lines, 0, "both DELETEs propagate when block is intact (gate passes)")

  cleanup()
end

-- ── feat-3 gate: 0 INSERTs + 2 DELETEs, broken block → full revert ─────────────

T["cross-task/gate: 0 INSERTs + 2 DELETEs broken block — gate fires, source untouched"] = function()
  -- Source: 2 tasks; user clears the entire buffer (removing fences too).
  -- delete_count >= 2, block is broken → gate fires → source untouched + warn.
  local bufnr, src_path, cleanup = setup_dashboard({
    "- [ ] Task Alpha #task",
    "- [ ] Task Beta #task",
  })

  local src_before = read_file(src_path)

  local warned, _ = capture_warns(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    edit_mod.flush(bufnr)
  end)

  local src_after = read_file(src_path)
  eq(src_after, src_before, "source must be untouched when block is broken (gate fires)")
  eq(warned, true, "gate must emit a warn notification when block is broken")

  cleanup()
end

return T
