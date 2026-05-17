-- tests/integration/test_edit_flush.lua
-- RED-phase integration tests for the P4+P5 edit-flush pipeline.
--
-- Most tests are initially FAILING because render/edit.flush() is a no-op stub
-- and render/revert.classify() always returns nil.  They pass once GREEN tasks
-- ot-165d (classifier), ot-32mh (batched write/drift), and ot-iyw1 (flush
-- coalescer) are implemented.
--
-- The "status flip via keymap" test is a REGRESSION GUARD that must pass
-- immediately — it covers the existing on_lines status-flip path, which is
-- explicitly preserved by this feature.
--
-- Locked decisions exercised:
--   Q1  Edit-flush timing: normal-mode → end-of-tick; insert-mode → InsertLeave.
--   Q12 Drift recovery: ±5 drift located; extmark's stored source_row updated.
--   Q13 Coalescing: multiple edits in one tick → one read+write per src_path;
--       single `u` reverses all source mutations from that tick.
--   Q15 Per-file failure: failed file's rows revert; other files proceed.
--   Q3  Lenient parser: invalid-field row accepts structural edits.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local edit_mod = require("obsidian-tasks.render.edit")
local cmd = require("obsidian-tasks.cmd")
local managed = require("obsidian-tasks.render.managed")

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

local function read_src_line(path, row0)
  local b = vim.fn.bufnr(path, false)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines[row0 + 1] or nil
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

local function get_line(bufnr, row0)
  return vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
end

local function set_line(bufnr, row0, text)
  vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { text })
end

--- Index stub: returns tasks from a live source file (buffer if loaded, disk otherwise).
local function install_file_task_stub(src_path)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
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
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Standard scaffolding: tmpfile with task_text; dashboard buffer with one query.
--- Returns: bufnr, src_path, cleanup.
local function setup_dashboard(task_text)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ task_text })
  local restore_stub = install_file_task_stub(src_path)
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)
  local cleanup = function()
    render.clear_buffer(bufnr)
    restore_stub()
    revert._cleanup(bufnr)
    local src_buf = vim.fn.bufnr(src_path, false)
    if src_buf ~= -1 then
      vim.api.nvim_buf_delete(src_buf, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end
  return bufnr, src_path, cleanup
end

-- Task rows sit below the fence header (row 0 = ```, row 1 = query, row 2 = ```,
-- row 3 = first task).
local TASK_ROW = 3

-- ── Q1: Normal-mode edit propagates at end-of-tick ───────────────────────────

T["edit flush: normal-mode description edit propagates to source"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Buy milk #task")

  local canonical = get_line(bufnr, TASK_ROW)
  -- Simulate `cw` replacing the description word.
  local edited = canonical:gsub("Buy milk", "Buy oat milk")
  set_line(bufnr, TASK_ROW, edited)

  -- Trigger end-of-tick flush (the real implementation schedules this via
  -- vim.schedule; in tests we call flush directly).
  edit_mod.flush(bufnr)

  -- Assertion: source row should reflect the new description.
  local src_line = read_src_line(src_path, 0)
  eq(src_line, "- [ ] Buy oat milk #task", "source must have updated description after flush")

  cleanup()
end

-- ── Q1: Insert-mode edit defers to InsertLeave ────────────────────────────────

T["edit flush: insert-mode edit deferred to InsertLeave propagates to source"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Walk dog #task")

  local canonical = get_line(bufnr, TASK_ROW)
  -- Simulate insert-mode edit: set the line as if the user typed in insert mode.
  local edited = canonical:gsub("Walk dog", "Walk the dog")
  set_line(bufnr, TASK_ROW, edited)

  -- Simulate InsertLeave: call flush directly (the autocmd wires this in the
  -- real implementation; since flush is a stub this test fails expectedly).
  edit_mod.flush(bufnr)

  local src_line = read_src_line(src_path, 0)
  eq(src_line, "- [ ] Walk the dog #task", "source must reflect insert-mode edit on InsertLeave")

  cleanup()
end

-- ── Q13: Multi-row tick coalesces to one write per src_path ──────────────────

T["edit flush: two edits in one tick coalesce to single write per file"] = function()
  render.configure({ default_folded = false })

  local src_a = make_tmpfile({ "- [ ] Task A #task", "- [ ] Task B #task" })
  local restore_a = install_file_task_stub(src_a)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Count writefile calls per path.
  local write_counts = {}
  local orig_writefile = vim.fn.writefile
  vim.fn.writefile = function(lines, path, ...)
    write_counts[path] = (write_counts[path] or 0) + 1
    return orig_writefile(lines, path, ...)
  end

  -- Simulate `:s/foo/bar/g` style: both task rows edited in the same tick.
  local row_a = TASK_ROW
  local row_b = TASK_ROW + 1
  local can_a = get_line(bufnr, row_a)
  local can_b = get_line(bufnr, row_b)
  set_line(bufnr, row_a, can_a:gsub("Task A", "Task A edited"))
  set_line(bufnr, row_b, can_b:gsub("Task B", "Task B edited"))

  -- Flush: should group by src_path and write src_a exactly once.
  edit_mod.flush(bufnr)

  vim.fn.writefile = orig_writefile

  -- One write for the single source file (both tasks are in src_a).
  eq(write_counts[src_a], 1, "source file should be written exactly once per tick")

  render.clear_buffer(bufnr)
  restore_a()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
end

-- ── Q13: Single `u` undoes entire multi-file tick ────────────────────────────

T["edit flush: single undo after multi-file tick reverses all source mutations"] = function()
  render.configure({ default_folded = false })

  local src_a = make_tmpfile({ "- [ ] Task A #task" })
  local src_b = make_tmpfile({ "- [ ] Task B #task" })

  -- Stub the index to return from both files.
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved_tasks_in = index_mod.tasks_in
  local saved_srp = index_mod.set_render_paths
  local saved_crp = index_mod.clear_render_paths
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.tasks_in = function(_)
    local all = {}
    for _, sp in ipairs({ src_a, src_b }) do
      local ok, lines = pcall(vim.fn.readfile, sp)
      if ok then
        for _, line in ipairs(lines) do
          local task = task_parse.parse(line)
          if task then
            all[#all + 1] = { task = task, path = sp }
          end
        end
      end
    end
    local i = 0
    return function()
      i = i + 1
      if all[i] then
        return all[i].task, all[i].path, 1
      end
    end
  end

  local dash_bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(dash_bufnr, nil)

  -- Edit both task rows in the same tick.
  local row_a = TASK_ROW
  local row_b = TASK_ROW + 1
  local can_a = get_line(dash_bufnr, row_a)
  local can_b = get_line(dash_bufnr, row_b)
  set_line(dash_bufnr, row_a, can_a:gsub("Task A", "Task A mutated"))
  set_line(dash_bufnr, row_b, can_b:gsub("Task B", "Task B mutated"))

  -- Flush (stub: no-op, so sources won't actually change — assertions will fail).
  edit_mod.flush(dash_bufnr)

  -- Verify sources were updated.
  eq(read_src_line(src_a, 0), "- [ ] Task A mutated #task", "src_a should be mutated")
  eq(read_src_line(src_b, 0), "- [ ] Task B mutated #task", "src_b should be mutated")

  -- Single undo should reverse both source mutations.
  local ok_undo = cmd.dashboard_undo(dash_bufnr)
  eq(ok_undo, true, "undo should succeed")
  eq(read_src_line(src_a, 0), "- [ ] Task A #task", "src_a should be reverted by undo")
  eq(read_src_line(src_b, 0), "- [ ] Task B #task", "src_b should be reverted by undo")

  -- Cleanup.
  render.clear_buffer(dash_bufnr)
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_srp
  index_mod.clear_render_paths = saved_crp
  revert._cleanup(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
end

-- ── Q12: Drift recovery — ±5 rows ────────────────────────────────────────────

T["edit flush: ±5 row drift located; edit lands at correct source row"] = function()
  -- Source file: insert 5 blank lines above the task to simulate drift.
  local original_row = 0
  local drifted_row = 5 -- task is now at row 5
  local task_text = "- [ ] Drifted task #task"
  local lines = {}
  for i = 1, 5 do
    lines[i] = "# inserted blank " .. i
  end
  lines[6] = task_text -- row 5 (0-indexed)
  local src_path = make_tmpfile(lines)

  -- Dashboard was rendered when task was at row 0.
  local restore_stub = install_file_task_stub(src_path)
  render.configure({ default_folded = false })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  local canonical = get_line(bufnr, TASK_ROW)
  local edited = canonical:gsub("Drifted task", "Drifted task edited")
  set_line(bufnr, TASK_ROW, edited)

  -- Flush: real implementation should call locate, find row 5, write there.
  edit_mod.flush(bufnr)

  -- After flush, the edit should land at the drifted row (5), NOT at row 0.
  local updated = read_src_line(src_path, drifted_row)
  eq(updated, "- [ ] Drifted task edited #task", "edit should land at located row after drift recovery")

  -- Original row (0..4) should still be blank.
  local undisturbed = read_src_line(src_path, original_row)
  eq(undisturbed, "# inserted blank 1", "original row should not be mutated")

  -- The managed extmark's stored source_row must be updated from 0 to 5 so that
  -- subsequent edits on the same row use the correct (drift-recovered) source row.
  -- Q12: "Found → write at located row, update extmark's stored source_row."
  local post_meta = managed.task_meta_for_row(bufnr, TASK_ROW)
  MiniTest.expect.no_equality(post_meta, nil, "task meta must exist after drift-recovery flush")
  eq(post_meta.source_row, drifted_row, "extmark source_row must be updated to located row after drift recovery")

  render.clear_buffer(bufnr)
  restore_stub()
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── Q15: Per-file failure reverts that file's rows; others commit ─────────────

T["edit flush: per-file write failure reverts that file's rows, other files commit"] = function()
  render.configure({ default_folded = false })

  local src_ok = make_tmpfile({ "- [ ] Task OK #task" })
  local src_fail = make_tmpfile({ "- [ ] Task FAIL #task" })

  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved_tasks_in = index_mod.tasks_in
  local saved_srp = index_mod.set_render_paths
  local saved_crp = index_mod.clear_render_paths
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.tasks_in = function(_)
    local all = {}
    for _, sp in ipairs({ src_ok, src_fail }) do
      local ok, file_lines = pcall(vim.fn.readfile, sp)
      if ok then
        for _, line in ipairs(file_lines) do
          local task = task_parse.parse(line)
          if task then
            all[#all + 1] = { task = task, path = sp }
          end
        end
      end
    end
    local i = 0
    return function()
      i = i + 1
      if all[i] then
        return all[i].task, all[i].path, 1
      end
    end
  end

  local dash_bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(dash_bufnr, nil)

  -- Make src_fail read-only.
  vim.fn.system({ "chmod", "-w", src_fail })

  local row_ok = TASK_ROW
  local row_fail = TASK_ROW + 1
  local can_ok = get_line(dash_bufnr, row_ok)
  local can_fail = get_line(dash_bufnr, row_fail)
  set_line(dash_bufnr, row_ok, can_ok:gsub("Task OK", "Task OK updated"))
  set_line(dash_bufnr, row_fail, can_fail:gsub("Task FAIL", "Task FAIL updated"))

  -- Track notify calls to detect partial-success notification.
  local notified = false
  local orig_notify = vim.notify
  vim.notify = function(msg, ...)
    if msg and msg:find("partial") then
      notified = true
    end
    return orig_notify(msg, ...)
  end

  edit_mod.flush(dash_bufnr)

  vim.notify = orig_notify
  vim.fn.system({ "chmod", "+w", src_fail })

  -- src_ok should be updated.
  eq(read_src_line(src_ok, 0), "- [ ] Task OK updated #task", "writable file should be committed")
  -- src_fail should be unchanged (write failed).
  eq(read_src_line(src_fail, 0), "- [ ] Task FAIL #task", "read-only file should not be changed")
  -- A partial-success notification should have been emitted.
  eq(notified, true, "partial-success notification should have been emitted")

  -- Cleanup.
  render.clear_buffer(dash_bufnr)
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_srp
  index_mod.clear_render_paths = saved_crp
  revert._cleanup(dash_bufnr)
  vim.api.nvim_buf_delete(dash_bufnr, { force = true })
  vim.fn.delete(src_ok)
  vim.fn.delete(src_fail)
end

-- ── Regression guard: status flip via keymap still works ─────────────────────
-- This test must pass IMMEDIATELY — it exercises the existing on_lines
-- status-flip path (recognize_status_edit → classify_and_commit), which is
-- NOT changed by P4/P5.  It guards against regressions introduced by adding
-- the classify() stub or the InsertLeave autocmd.

T["regression: status flip via on_lines path still propagates to source"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Regression task #task")

  local canonical = get_line(bufnr, TASK_ROW)
  -- Status-flip: [ ] → [x] (only the status char changes).
  local edited = canonical:gsub("%[ %]", "[x]", 1)
  set_line(bufnr, TASK_ROW, edited)

  -- Use the existing revert._flush_pending path (unchanged by P4/P5).
  revert._flush_pending(bufnr)

  local src_line = read_src_line(src_path, 0)
  eq(src_line, "- [x] Regression task #task", "status flip must still propagate via existing path")

  cleanup()
end

-- ── Lenient parser: invalid-field row accepts structural edits ────────────────
-- Q3 + Lenient parser invariants (P2): a task with an invalid field value still
-- propagates structural edits.  Invalid-field highlight is retained post-flush.

T["edit flush: row with invalid field accepts description edit; retains diagnostics"] = function()
  -- Source task has an invalid due-date value that the lenient parser accepts.
  local src_path = make_tmpfile({ "- [ ] Task with bad date 📅 someday #task" })
  local restore_stub = install_file_task_stub(src_path)
  render.configure({ default_folded = false })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  local canonical = get_line(bufnr, TASK_ROW)
  -- Edit the description portion only (not the invalid field).
  local edited = canonical:gsub("Task with bad date", "Updated task with bad date")
  set_line(bufnr, TASK_ROW, edited)

  -- Pre-flush: load the source buffer so diagnostics can be checked post-flush.
  -- The real flush implementation will call render.refresh_source_diagnostics
  -- on the source buffer after writing; this check verifies that path fires.
  vim.cmd("silent! badd " .. vim.fn.fnameescape(src_path))
  local src_bufnr = vim.fn.bufnr(src_path, false)

  edit_mod.flush(bufnr)

  -- Source must reflect the description edit despite the invalid field.
  local src_line = read_src_line(src_path, 0)
  eq(
    src_line,
    "- [ ] Updated task with bad date 📅 someday #task",
    "description edit should propagate despite invalid field"
  )

  -- Diagnostics for the invalid date field ('someday') must still be present
  -- on the source buffer after flush — i.e. flush must call
  -- render.refresh_source_diagnostics so the invalid-field highlight is
  -- retained on the source row (Q3 + lenient-parser P2 invariant).
  local post_diags = {}
  if src_bufnr ~= -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    for _, d in ipairs(vim.diagnostic.get(src_bufnr, { namespace = render._source_diag_ns })) do
      post_diags[#post_diags + 1] = d
    end
  end
  MiniTest.expect.equality(
    #post_diags > 0,
    true,
    "invalid-field diagnostic must be retained on source buffer after flush (render.refresh_source_diagnostics must fire)"
  )

  render.clear_buffer(bufnr)
  restore_stub()
  revert._cleanup(bufnr)
  if src_bufnr ~= -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    vim.api.nvim_buf_delete(src_bufnr, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── Q2: Date field normalization — "tomorrow" → ISO date ─────────────────────
-- Locked decision Q2: per-field value normalization: dates 'tomorrow' → ISO
-- via cmp/date_nl.lua.  Flush must normalize natural-language date tokens in
-- field positions before writing to source; verbatim text outside date fields
-- is written as-is.

T["edit flush: Q2 date normalization — 'tomorrow' in date field written as ISO"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Plan meeting #task")

  local canonical = get_line(bufnr, TASK_ROW)
  -- Simulate the user typing "tomorrow" into the due-date field position.
  -- The rendered line gains a date emoji + NL text; flush must convert to ISO.
  local edited = canonical:gsub("#task", "📅 tomorrow #task")
  set_line(bufnr, TASK_ROW, edited)

  edit_mod.flush(bufnr)

  -- The source file must contain the ISO equivalent of "tomorrow", NOT the
  -- literal string "tomorrow".  The exact ISO date depends on the test runtime
  -- date, so we check that the field value is a valid YYYY-MM-DD string.
  local src_line = read_src_line(src_path, 0)
  MiniTest.expect.no_equality(src_line, nil, "source line must exist after flush")
  -- "tomorrow" must NOT appear verbatim in the written source (normalization required).
  MiniTest.expect.equality(
    src_line and src_line:find("tomorrow") == nil,
    true,
    "Q2: 'tomorrow' must be normalized to ISO date before writing to source"
  )
  -- The ISO date pattern YYYY-MM-DD must appear in the written source line.
  MiniTest.expect.equality(
    src_line and src_line:find("%d%d%d%d%-%d%d%-%d%d") ~= nil,
    true,
    "Q2: written source must contain an ISO date (YYYY-MM-DD) after 'tomorrow' normalization"
  )

  cleanup()
end

-- ── Q10: Cursor shift after REPAIR_AND_MUTATE ─────────────────────────────────
-- Locked decision Q10: when structural repair re-adds `- [ ] ` (6 chars) at
-- the start of a line, the cursor column shifts right by 6 so the user's
-- position within the text is preserved.

T["edit flush: Q10 cursor shifts right when structural repair adds prefix"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Repair me #task")

  -- Open the dashboard buffer in a window so cursor operations work.
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 20,
    row = 0,
    col = 0,
    style = "minimal",
  })

  -- Simulate REPAIR_AND_MUTATE: user deleted the `- [ ] ` prefix (6 chars),
  -- leaving just the description.  Cursor sits at column 3 within the bare text.
  local bare_text = "Repair me #task"
  set_line(bufnr, TASK_ROW, bare_text)
  vim.api.nvim_win_set_cursor(winid, { TASK_ROW + 1, 3 }) -- 1-indexed row, 0-indexed col

  -- Flush: classifier detects REPAIR_AND_MUTATE → re-adds `- [ ] ` prefix →
  -- shifts cursor right by len("- [ ] ") = 6.
  edit_mod.flush(bufnr)

  local post_cursor = vim.api.nvim_win_get_cursor(winid)
  -- post_cursor[1] is 1-indexed row (should be unchanged)
  -- post_cursor[2] is 0-indexed col (should be 3 + 6 = 9)
  eq(post_cursor[2], 9, "Q10: cursor column must shift right by 6 after REPAIR_AND_MUTATE prefix re-add")

  vim.api.nvim_win_close(winid, true)
  cleanup()
end

-- ── blink.cmp commit during insert mode triggers flush on InsertLeave ─────────

T["edit flush: blink.cmp completion commit flushes on InsertLeave"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Complete me 📅 #task")

  -- Simulate blink.cmp acceptance: the completion replaces the date field text.
  local canonical = get_line(bufnr, TASK_ROW)
  local after_completion = canonical:gsub("📅 ", "📅 2024-12-31 ")
  set_line(bufnr, TASK_ROW, after_completion)

  -- Simulate <Esc> / InsertLeave: call flush directly.
  -- In the real system the InsertLeave autocmd fires flush(bufnr).
  edit_mod.flush(bufnr)

  local src_line = read_src_line(src_path, 0)
  eq(src_line, "- [ ] Complete me 📅 2024-12-31 #task", "completion result should be flushed on InsertLeave")

  cleanup()
end

return T
