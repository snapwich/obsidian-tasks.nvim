-- tests/integration/test_edit_through.lua
-- End-to-end integration tests for the F4 edit-through pipeline.
--
-- Six scenarios exercising the full diff → patch/delete/insert → strip path,
-- plus a multi-block round-trip guard and a stale-jump fallback test.
--
-- Uses real tmpdir source files (no mocked filesystem).
-- Each scenario creates isolated files to avoid cross-test pollution.
--
-- Deviation from spec (scenarios 3–5):
--   S3 uses a range_override because the user-inserted line is STRICTLY BEYOND
--   the last tracked extmark — edit.diff's dynamic scan window stops at the
--   furthest live extmark row, so lines after the last task remain undetectable
--   (v1-accepted limitation).  S4 & S5 call resolve_insert directly because
--   empty-render blocks have no inserted_range and run_write_pre's `if range`
--   guard skips them entirely.

local T = MiniTest.new_set()

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Swap package.loaded[name] for mock; return cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Build stub index yielding entries from tasks_in().
--- @param entries table[]  { task, path, line_num }
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
  }
end

--- Create scratch buffer pre-populated with lines.
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Write lines to a fresh temp file; return its absolute path.
local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

--- Force-reload render/init so _buffer_state and _lazy_init_started reset.
local function fresh_render()
  package.loaded["obsidian-tasks.render.init"] = nil
  return require("obsidian-tasks.render.init")
end

--- Mirror the User:ObsidianNoteWritePre autocmd handler from autocmds.lua.
--- Diffs each rendered block and applies source-file changes, then strips the
--- render region from the buffer.
---
--- @param bufnr          integer  render buffer
--- @param range_override table?   { [fence_first] = {first, last} } — extend the
---                                scan range for a specific block (used when the
---                                user-inserted line is outside the draw-time range)
local function run_write_pre(bufnr, range_override)
  local draw = require("obsidian-tasks.render.draw")
  local edit = require("obsidian-tasks.render.edit")
  local render = require("obsidian-tasks.render")

  local state = draw.render_state(bufnr)
  if not state then
    return
  end

  for fence_first, block in pairs(state) do
    local range = (range_override and range_override[fence_first]) or block.inserted_range
    if range then
      local result = edit.diff(bufnr, range, block.em_map)
      for _, patch in ipairs(result.patches) do
        edit.apply_patch(patch)
      end
      for _, deletion in ipairs(result.deletions) do
        edit.apply_deletion(deletion)
      end
      for _, ins in ipairs(result.inserts) do
        edit.apply_insert(ins, bufnr)
      end
    end
  end

  render.clear_buffer(bufnr)
end

--- Capture vim.notify calls during fn; return { { msg, level }, ... }.
local function capture_notify(fn)
  local calls = {}
  local orig = vim.notify
  vim.notify = function(msg, level, _opts)
    calls[#calls + 1] = { msg = msg, level = level }
  end
  local ok, err = pcall(fn)
  vim.notify = orig
  if not ok then
    error(err, 2)
  end
  return calls
end

--- Override opts.capture_file for the duration of fn, then restore.
local function with_capture_file(path, fn)
  local plugin = require("obsidian-tasks")
  local orig = plugin.opts.capture_file
  plugin.opts.capture_file = path
  local ok, err = pcall(fn)
  plugin.opts.capture_file = orig
  if not ok then
    error(err, 2)
  end
end

-- ── Scenario 1: modify ────────────────────────────────────────────────────────

T["S1: modify render task → source file patched, buffer stripped to fence only"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Source file: task at 1-indexed line 2.
  -- The modification changes the description (not status) so the task remains
  -- "not done" and will appear in the re-render under the "not done" query.
  local src_path = make_tmpfile({ "# Source", "- [ ] Buy milk" })

  local task_text = "- [ ] Buy milk"
  local task = parse.parse(task_text)
  assert(task ~= nil)

  local restore_idx =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = task, path = src_path, line_num = 2 } }))

  -- Render buffer with one tasks block.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Task is rendered at row 3 (0-indexed).  Modify the description (keep not-done).
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "- [ ] Buy organic milk" })

  -- Run the write-pre pipeline (standard range: {3, 3}).
  run_write_pre(bufnr)

  -- Source file must have the patched text at 1-indexed line 2.
  local src_lines = vim.fn.readfile(src_path)
  eq(src_lines[2], "- [ ] Buy organic milk")

  -- Buffer must be stripped to only the fence lines.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#buf_lines, 3)
  eq(buf_lines[1], "```tasks")
  eq(buf_lines[2], "not done")
  eq(buf_lines[3], "```")

  -- Re-render to verify rebuild contains updated content.
  -- Stub index with the modified task (same status = not done, new description).
  restore_idx()
  local patched_task = parse.parse("- [ ] Buy organic milk")
  assert(patched_task ~= nil)
  local restore_idx2 =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = patched_task, path = src_path, line_num = 2 } }))
  render.render_buffer(bufnr)
  local rebuilt = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found_organic = false
  for _, l in ipairs(rebuilt) do
    if l:find("organic", 1, true) then
      found_organic = true
    end
  end
  MiniTest.expect.equality(found_organic, true)

  draw_mod.clear(bufnr)
  restore_idx2()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── Scenario 2: delete ────────────────────────────────────────────────────────

T["S2: delete render task line → source file task removed, buffer stripped"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Source file: two lines, task at line 2.
  local src_path = make_tmpfile({ "# Source", "- [ ] Task to delete", "other content" })

  local task_text = "- [ ] Task to delete"
  local task = parse.parse(task_text)
  assert(task ~= nil)

  local restore_idx =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = task, path = src_path, line_num = 2 } }))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Delete the rendered task line at row 3.
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, {})

  -- Run write-pre (range {3, 3}; the line is gone so buffer is now shorter,
  -- but the extmark has no valid position → deletion detected).
  run_write_pre(bufnr)

  -- Source file must no longer contain the task line.
  local src_lines = vim.fn.readfile(src_path)
  eq(#src_lines, 2) -- "# Source" and "other content"
  eq(src_lines[1], "# Source")
  eq(src_lines[2], "other content")

  -- Buffer stripped to fence only.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#buf_lines, 3)
  eq(buf_lines[1], "```tasks")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── Scenario 3: insert with anchor ───────────────────────────────────────────
--
-- Two tasks are rendered (range {3, 4}).  A new task is inserted at row 5,
-- immediately after both tasks.  run_write_pre is called with an extended range
-- {3, 5} so the diff can see the unclaimed row 5.
-- The nearest sibling above row 5 is task B (row 4); new task goes after task B
-- in task B's source file.

T["S3: insert below existing tasks → appended to nearest-sibling source"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Two separate source files, each with one task.
  local src_a = make_tmpfile({ "- [ ] Task A" })
  local src_b = make_tmpfile({ "- [ ] Task B", "tail content" })

  local task_a = parse.parse("- [ ] Task A")
  local task_b = parse.parse("- [ ] Task B")
  assert(task_a ~= nil)
  assert(task_b ~= nil)

  local restore_idx = install_mock(
    "obsidian-tasks.index",
    make_index_stub({
      { task = task_a, path = src_a, line_num = 1 },
      { task = task_b, path = src_b, line_num = 1 },
    })
  )

  -- Render: two tasks inserted at rows 3 (task A) and 4 (task B).
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Insert "- [ ] New task" at row 5 (after both rendered tasks).
  vim.api.nvim_buf_set_lines(bufnr, 5, 5, false, { "- [ ] New task" })

  -- Extended scan range {3, 5} covers the newly inserted row.
  with_capture_file(nil, function()
    run_write_pre(bufnr, { [0] = { 3, 5 } })
  end)

  -- Task A's source must be unchanged.
  local lines_a = vim.fn.readfile(src_a)
  eq(#lines_a, 1)
  eq(lines_a[1], "- [ ] Task A")

  -- New task must appear after task B in task B's source (nearest sibling above row 5).
  local lines_b = vim.fn.readfile(src_b)
  eq(lines_b[1], "- [ ] Task B")
  eq(lines_b[2], "- [ ] New task")
  eq(lines_b[3], "tail content")

  -- Buffer stripped to fence.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(buf_lines[1], "```tasks")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
end

-- ── Scenario 4: insert with capture_file ─────────────────────────────────────
--
-- Empty render (no tasks from index).  A user types a task line and opts.capture_file
-- is set.  resolve_insert is called directly (empty render has no draw state /
-- inserted_range=nil; diff machinery cannot detect the insert).

T["S4: insert in empty render + capture_file → task appended to capture file"] = function()
  local cap_path = vim.fn.tempname() .. ".md"
  -- File must not exist yet (created on first use).
  eq(vim.fn.filereadable(cap_path), 0)

  -- Render buffer with no tasks (empty results) — no draw state inserted_range.
  local fresh = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  fresh.render_buffer(bufnr)

  -- Verify no tasks were inserted (render region is empty).
  local state = draw_mod.render_state(bufnr)
  if state then
    for _, block in pairs(state) do
      MiniTest.expect.equality(block.inserted_range, nil)
    end
  end

  -- Simulate user inserting a task into the empty render area.
  local edit = require("obsidian-tasks.render.edit")
  with_capture_file(cap_path, function()
    -- after_lnum = 0: no draw state → no anchor found → falls to capture_file.
    edit.resolve_insert(bufnr, 0, "- [ ] Captured task")
  end)

  -- Capture file must have been created with the new task.
  eq(vim.fn.filereadable(cap_path), 1)
  local lines = vim.fn.readfile(cap_path)
  eq(#lines, 1)
  eq(lines[1], "- [ ] Captured task")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(cap_path)
end

-- ── Scenario 5: insert with no capture_file ───────────────────────────────────
--
-- Empty render, no capture_file configured.  Inserting a task must emit log.warn
-- and NOT write the task anywhere.

T["S5: insert in empty render + no capture_file → warn emitted, task dropped"] = function()
  local fresh = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  fresh.render_buffer(bufnr)

  local edit = require("obsidian-tasks.render.edit")

  -- Track any temp files created (there should be none).
  local tmpdir = vim.fn.tempname()

  local notify_calls = capture_notify(function()
    with_capture_file(nil, function()
      edit.resolve_insert(bufnr, 0, "- [ ] Orphan task")
    end)
  end)

  -- A WARN must have been emitted containing "no anchor".
  local found_warn = false
  for _, call in ipairs(notify_calls) do
    if call.level == vim.log.levels.WARN and call.msg:find("no anchor", 1, true) then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, true)

  -- No file should have been written anywhere (tmpdir should not exist).
  eq(vim.fn.isdirectory(tmpdir), 0)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── Scenario 6: stale jump ────────────────────────────────────────────────────
--
-- A task is drawn with src_hash = sha256(source_text).  The source file is then
-- externally shifted by 5 lines (writefile with prepended padding) so the task
-- sits at a different line than recorded.  Pressing <CR> must find the moved line
-- via the content-match scan in resolve_jump_line, not the stale src_line.
--
-- Note on hashes: layout.lua now emits TWO hashes:
--   src_hash          = sha256(rendered_text_with_wikilink) — used by edit.lua diff
--   source_text_hash  = sha256(source_text_before_wikilink) — used by keymap.lua scan
-- This test has no wikilink, so both hashes are identical and equal task_hash.

T["S6: stale jump — task shifted 5 lines — CR lands on moved line"] = function()
  local draw_mod = require("obsidian-tasks.render.draw")

  local task_text = "- [ ] My stale task"
  -- Both hashes equal sha256(task_text) here because there is no wikilink.
  local task_hash = vim.fn.sha256(task_text):sub(1, 16)

  -- Source file: task initially at 1-indexed line 2.
  local src_path = make_tmpfile({ "# Note", task_text })

  -- Draw the task directly, supplying BOTH hash fields so the keymap handler
  -- can use source_text_hash for source-file content-match.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 20,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)

  draw_mod.draw(bufnr, { 0, 2 }, {
    {
      kind = "task",
      text = task_text,
      src_path = src_path,
      src_line = 2,
      src_hash = task_hash,
      source_text_hash = task_hash, -- no wikilink → identical to src_hash
    },
  })

  -- Task inserted at row 3 (0-indexed); cursor at 1-indexed row 4.
  vim.api.nvim_win_set_cursor(winid, { 4, 0 })

  -- Externally shift the source file: prepend 5 padding lines.
  -- Task now lives at 1-indexed line 7.
  vim.fn.writefile({ "padding 1", "padding 2", "padding 3", "padding 4", "padding 5", "# Note", task_text }, src_path)

  -- Invoke <CR> handler (installed by draw_mod.draw on first draw).
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local cr_cb = nil
  for _, m in ipairs(maps) do
    if m.lhs == "<CR>" then
      cr_cb = m.callback
    end
  end
  MiniTest.expect.equality(cr_cb ~= nil, true)
  cr_cb()

  -- Current buffer should now be the source file.
  local cur_name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  MiniTest.expect.equality(cur_name:find(vim.fn.fnamemodify(src_path, ":t"), 1, true) ~= nil, true)

  -- Cursor must be on the MOVED line (1-indexed row 7, not stale row 2).
  local pos = vim.api.nvim_win_get_cursor(0)
  eq(pos[1], 7)

  -- Cleanup.
  local src_bufnr = vim.fn.bufnr(src_path)
  if src_bufnr ~= -1 then
    vim.api.nvim_buf_delete(src_bufnr, { force = true })
  end
  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── Insert-above regression guard (ot-plh6 discovery) ───────────────────────
--
-- Two-task render.  User inserts a new line at the TOP of the render region
-- (row 3, before task A).  After the insert:
--   • task A's extmark shifts to row 4 (right_gravity=true, insert at row 3).
--   • task B's extmark shifts to row 5 (insert above its original row 4).
-- run_write_pre uses block.inserted_range = {3, 4} with NO range override.
--
-- Dynamic scan window (edit.lua Phase 0) expands scan_last to max live extmark
-- row: max(last=4, A=4, B=5) = 5.  Phase 1 strong-claims both tasks:
--   • row 4 → task A (hash matches).
--   • row 5 → task B (hash matches).
-- Row 3 is unclaimed → detected as INSERT.  resolve_insert walks up from row 2
-- (after_lnum=3 → walk from row 2) and finds no task extmark above row 3
-- within the block, so the new line is routed to capture_file.

T["insert-above: task A and B strong-claimed; new row is insert to capture_file"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local src_a = make_tmpfile({ "- [ ] Task A" })
  local src_b = make_tmpfile({ "- [ ] Task B" })
  local cap_path = vim.fn.tempname() .. ".md"

  local task_a = parse.parse("- [ ] Task A")
  local task_b = parse.parse("- [ ] Task B")
  assert(task_a ~= nil)
  assert(task_b ~= nil)

  local restore_idx = install_mock(
    "obsidian-tasks.index",
    make_index_stub({
      { task = task_a, path = src_a, line_num = 1 },
      { task = task_b, path = src_b, line_num = 1 },
    })
  )

  -- Render: task A at row 3, task B at row 4.  inserted_range = {3, 4}.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Insert ABOVE task A (at row 3), pushing A to 4 and B to 5.
  vim.api.nvim_buf_set_lines(bufnr, 3, 3, false, { "- [ ] Above A" })

  -- run_write_pre with NO range override: uses block.inserted_range = {3, 4}.
  -- With scan-window expansion, extmarks at rows 4 and 5 are pulled into the
  -- window: task A strong-claimed at row 4, task B strong-claimed at row 5.
  with_capture_file(cap_path, function()
    run_write_pre(bufnr)
  end)

  -- Source A: task A correctly strong-claimed at row 4 (no patch, no deletion).
  local lines_a = vim.fn.readfile(src_a)
  eq(#lines_a, 1)
  eq(lines_a[1], "- [ ] Task A")

  -- Source B: task B correctly strong-claimed at row 5 (no deletion).
  local lines_b = vim.fn.readfile(src_b)
  eq(#lines_b, 1)
  eq(lines_b[1], "- [ ] Task B")

  -- The new line at row 3 is detected as insert (row 3 unclaimed).
  -- No sibling above row 3 within block → falls to capture_file.
  eq(vim.fn.filereadable(cap_path), 1)
  local cap_lines = vim.fn.readfile(cap_path)
  eq(cap_lines[1], "- [ ] Above A")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
  vim.fn.delete(cap_path)
end

-- ── Delete-non-last-task regression guard (ot-plh6 discovery) ────────────────
--
-- Two-task render.  User deletes the FIRST task (task A).  After deletion:
--   • task A's extmark drifts to row 3 (now has task B's content → hash mismatch
--     → no strong claim).
--   • task B's extmark also lands at row 3 (line shifted up → hash matches
--     → strong claim).
-- run_write_pre correctly identifies the deletion of task A and leaves B intact.
-- This is the "delete-non-last-task" fix verified by the two-phase algorithm.

T["delete-non-last: task A deleted, task B source completely unchanged"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Two separate source files.
  local src_a = make_tmpfile({ "# Note A", "- [ ] Task A", "footer A" })
  local src_b = make_tmpfile({ "# Note B", "- [ ] Task B", "footer B" })

  local task_a = parse.parse("- [ ] Task A")
  local task_b = parse.parse("- [ ] Task B")
  assert(task_a ~= nil)
  assert(task_b ~= nil)

  local restore_idx = install_mock(
    "obsidian-tasks.index",
    make_index_stub({
      { task = task_a, path = src_a, line_num = 2 },
      { task = task_b, path = src_b, line_num = 2 },
    })
  )

  -- Render: task A at row 3, task B at row 4.  inserted_range = {3, 4}.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Delete task A (row 3).  Task B shifts to row 3.
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, {})

  -- run_write_pre with NO range override.
  run_write_pre(bufnr)

  -- Source A: task A line removed.
  local lines_a = vim.fn.readfile(src_a)
  eq(#lines_a, 2)
  eq(lines_a[1], "# Note A")
  eq(lines_a[2], "footer A")

  -- Source B: COMPLETELY unchanged (task B strong-claimed at row 3 → no op).
  local lines_b = vim.fn.readfile(src_b)
  eq(#lines_b, 3)
  eq(lines_b[1], "# Note B")
  eq(lines_b[2], "- [ ] Task B")
  eq(lines_b[3], "footer B")

  -- Buffer stripped to fence.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(buf_lines[1], "```tasks")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
end

-- ── Insert-between: new line between two tasks → detected, anchored above ────
--
-- Two-task render: task A at row 3, task B at row 4.  inserted_range = {3, 4}.
-- User inserts "- [ ] Between A and B" at row 4 (before task B).
-- After the insert:
--   • task A's extmark stays at row 3 (insert is after it).
--   • task B's extmark shifts to row 5 (right_gravity=true, insert at row 4).
-- Dynamic scan_last = max(last=4, A=3, B=5) = 5 → covers all three rows.
-- Row 3 → task A strong-claimed.  Row 5 → task B strong-claimed.
-- Row 4 → unclaimed → INSERT; nearest sibling above row 4 is task A.
-- New task is inserted after task A's src_line in src_a.

T["insert-between: new task between A and B → anchored to task A source"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local src_a = make_tmpfile({ "- [ ] Task A", "tail A" })
  local src_b = make_tmpfile({ "- [ ] Task B" })

  local task_a = parse.parse("- [ ] Task A")
  local task_b = parse.parse("- [ ] Task B")
  assert(task_a ~= nil)
  assert(task_b ~= nil)

  local restore_idx = install_mock(
    "obsidian-tasks.index",
    make_index_stub({
      { task = task_a, path = src_a, line_num = 1 },
      { task = task_b, path = src_b, line_num = 1 },
    })
  )

  -- Render: task A at row 3, task B at row 4.  inserted_range = {3, 4}.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Insert between the two tasks at row 4 (before task B).
  -- After this: task A → row 3, new line → row 4, task B's extmark → row 5.
  vim.api.nvim_buf_set_lines(bufnr, 4, 4, false, { "- [ ] Between A and B" })

  -- run_write_pre without range_override.  Dynamic scan_last extends to row 5
  -- (task B's extmark).  Rows 3 and 5 are strong-claimed; row 4 is unclaimed.
  with_capture_file(nil, function()
    run_write_pre(bufnr)
  end)

  -- src_a: new task inserted after task A (src_line = 1).
  local lines_a = vim.fn.readfile(src_a)
  eq(lines_a[1], "- [ ] Task A")
  eq(lines_a[2], "- [ ] Between A and B")
  eq(lines_a[3], "tail A")

  -- src_b: task B completely unchanged (strong-claimed at row 5, no op).
  local lines_b = vim.fn.readfile(src_b)
  eq(#lines_b, 1)
  eq(lines_b[1], "- [ ] Task B")

  -- Buffer stripped to fence.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(buf_lines[1], "```tasks")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
end

-- ── S3 companion: insert strictly beyond last tracked extmark → v1 limitation ──
--
-- Companion to S3.  The insert is at row 5, which is STRICTLY AFTER the last
-- tracked task (task B at row 4).  No tasks were shifted above their draw-time
-- rows, so dynamic scan_last = max_tracked_row = 4.  Row 5 is beyond scan_last
-- and is therefore undetectable.
--
-- This is the v1-accepted limitation documented in edit.lua:
--   "Lines inserted AFTER the last task (rows beyond the furthest tracked
--    extmark's live position) remain undetectable."
-- The test locks in this limitation: both source files are unchanged and
-- capture_file is not created.

T["S3-companion: insert outside draw range → not detected, sources unchanged"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local src_a = make_tmpfile({ "- [ ] Task A" })
  local src_b = make_tmpfile({ "- [ ] Task B" })
  local cap_path = vim.fn.tempname() .. ".md"

  local task_a = parse.parse("- [ ] Task A")
  local task_b = parse.parse("- [ ] Task B")
  assert(task_a ~= nil)
  assert(task_b ~= nil)

  local restore_idx = install_mock(
    "obsidian-tasks.index",
    make_index_stub({
      { task = task_a, path = src_a, line_num = 1 },
      { task = task_b, path = src_b, line_num = 1 },
    })
  )

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Insert at row 5 (AFTER both tasks in range {3, 4}).
  vim.api.nvim_buf_set_lines(bufnr, 5, 5, false, { "- [ ] Outside range" })

  -- Production path: NO range_override.  Diff only covers {3, 4} → row 5 not seen.
  with_capture_file(cap_path, function()
    run_write_pre(bufnr)
  end)

  -- Both source files unchanged (no patches, no deletions).
  local lines_a = vim.fn.readfile(src_a)
  eq(#lines_a, 1)
  eq(lines_a[1], "- [ ] Task A")

  local lines_b = vim.fn.readfile(src_b)
  eq(#lines_b, 1)
  eq(lines_b[1], "- [ ] Task B")

  -- capture_file NOT created (insert not detected → resolve_insert never called).
  eq(vim.fn.filereadable(cap_path), 0)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
  -- cap_path never created, no delete needed
end

-- ── S4/S5 companion: empty render + run_write_pre → no side effects ───────────
--
-- Companion to S4 and S5.  When no tasks are rendered, block.inserted_range is
-- nil.  run_write_pre skips the diff entirely (the guard `if range then` is false).
-- Result: neither capture_file nor warn is triggered — the pipeline is a no-op.
-- Locks in that the production path is inert for empty render blocks.

T["S4/S5-companion: empty render + run_write_pre → no write, no warn"] = function()
  local fresh = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  fresh.render_buffer(bufnr)

  local cap_path = vim.fn.tempname() .. ".md"

  local notify_calls = capture_notify(function()
    with_capture_file(cap_path, function()
      -- run_write_pre: state exists but all blocks have inserted_range=nil → no-op.
      run_write_pre(bufnr)
    end)
  end)

  -- capture_file NOT created.
  eq(vim.fn.filereadable(cap_path), 0)

  -- No warn emitted (diff was never run → resolve_insert never called).
  local found_warn = false
  for _, call in ipairs(notify_calls) do
    if call.level == vim.log.levels.WARN then
      found_warn = true
    end
  end
  MiniTest.expect.equality(found_warn, false)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── S6 companion: full render pipeline stale jump → moved line ───────────────
--
-- Companion to S6.  Uses render.render_buffer (production path) so src_hash is
-- computed by layout.lua from the RENDERED text (task text + wikilink suffix).
-- layout.lua also now computes source_text_hash from the pre-wikilink text,
-- which matches the raw source-file content.  The source file is externally
-- shifted so the task is at a different line.  resolve_jump_line uses
-- source_text_hash for the scan and correctly lands on the moved line.

T["S6-companion: full pipeline stale jump → lands on moved line"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local task_text = "- [ ] Stale companion task"
  local src_path = make_tmpfile({ "# Note", task_text })

  local task = parse.parse(task_text)
  assert(task ~= nil)

  local restore_idx =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = task, path = src_path, line_num = 2 } }))

  -- Full render pipeline: layout.lua appends wikilink, sets src_hash from
  -- rendered text AND sets source_text_hash from pre-wikilink text.
  -- keymap.lua uses source_text_hash for the content-match scan.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 20,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  render.render_buffer(bufnr)

  -- Task rendered at row 3 (0-indexed); cursor at 1-indexed row 4.
  vim.api.nvim_win_set_cursor(winid, { 4, 0 })

  -- Externally shift the source file: task now at line 7 (was 2).
  vim.fn.writefile({ "padding 1", "padding 2", "padding 3", "padding 4", "padding 5", "# Note", task_text }, src_path)

  -- Invoke <CR> handler.
  local maps = vim.api.nvim_buf_get_keymap(bufnr, "n")
  local cr_cb = nil
  for _, m in ipairs(maps) do
    if m.lhs == "<CR>" then
      cr_cb = m.callback
    end
  end
  MiniTest.expect.equality(cr_cb ~= nil, true)
  cr_cb()

  -- Cursor must be at the MOVED line (7), not the stale src_line (2).
  -- source_text_hash (pre-wikilink) matches the raw source-file content and
  -- the scan correctly locates the task at its new position.
  local pos = vim.api.nvim_win_get_cursor(0)
  eq(pos[1], 7)

  -- Cleanup.
  local src_bufnr = vim.fn.bufnr(src_path)
  if src_bufnr ~= -1 then
    vim.api.nvim_buf_delete(src_bufnr, { force = true })
  end
  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── Multi-block round-trip (regression guard) ─────────────────────────────────
--
-- Regression guard from [jr:code-reviewer] (ot-mwsl): multi-block buffers were
-- silently corrupting source files via spurious cross-block deletions.  This test
-- verifies that :w with NO user edits leaves all source files intact.

T["multi-block no-edit round-trip → source files unchanged"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Two separate source files, one task each.
  local src_a = make_tmpfile({ "# A", "- [ ] Alpha task" })
  local src_b = make_tmpfile({ "# B", "- [ ] Beta task" })

  local task_a = parse.parse("- [ ] Alpha task")
  local task_b = parse.parse("- [ ] Beta task")
  assert(task_a ~= nil)
  assert(task_b ~= nil)

  local restore_idx = install_mock(
    "obsidian-tasks.index",
    make_index_stub({
      { task = task_a, path = src_a, line_num = 2 },
      { task = task_b, path = src_b, line_num = 2 },
    })
  )

  -- Two-block render buffer.
  local bufnr = make_buf({
    "```tasks", -- 0
    "not done", -- 1
    "```", -- 2
    "", -- 3
    "```tasks", -- 4
    "done", -- 5
    "```", -- 6
  })
  render.render_buffer(bufnr)

  -- Two blocks must have been rendered.
  MiniTest.expect.equality(render._buffer_state[bufnr] ~= nil, true)
  eq(#render._buffer_state[bufnr], 2)

  -- Run write-pre WITHOUT any user edits.
  run_write_pre(bufnr)

  -- Both source files must be exactly as they were.
  local lines_a = vim.fn.readfile(src_a)
  eq(#lines_a, 2)
  eq(lines_a[1], "# A")
  eq(lines_a[2], "- [ ] Alpha task")

  local lines_b = vim.fn.readfile(src_b)
  eq(#lines_b, 2)
  eq(lines_b[1], "# B")
  eq(lines_b[2], "- [ ] Beta task")

  -- Buffer is stripped.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Fence lines remain; no task lines.
  local task_found = false
  for _, l in ipairs(buf_lines) do
    if l:find("Alpha", 1, true) or l:find("Beta", 1, true) then
      task_found = true
    end
  end
  MiniTest.expect.equality(task_found, false)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
end

return T
