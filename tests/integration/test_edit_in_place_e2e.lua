-- tests/integration/test_edit_in_place_e2e.lua
-- Feature-level verification for P4+P5 edit-in-place (ot-17ts).
--
-- Covers cross-task integration scenarios required by the last task (ot-v0s1):
--
--   E1  Single tick s///g across 3 source files → 1 read+write per file, 1 undo block.
--   E2  Normal-mode edit + insert-mode edit on same row in next tick → 2 undo blocks.
--   E3  Wikilink-suffix strip + drift recovery compose without interference.
--   E4  Status-flip via <leader>tt on a .md source file (non-dashboard) still works.
--   E5  P1–P9 full-stack scenario via SYNCHRONOUS seams (set_line, direct flush).
--
-- All assertions use synchronous seams (edit_mod._flush_pending, revert._flush_pending,
-- direct edit_mod.flush) to remain deterministic without yielding to the event loop.
--
-- Real-keypress coverage of the same flows lives in
-- tests/integration_real/test_e2e_edit_in_place.lua — that file is the
-- end-to-end acceptance bar (exercises mode='i' timing, InsertLeave drain,
-- pending_deletes scheduling).  E5 here remains as a deterministic
-- classifier-logic test.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local edit_mod = require("obsidian-tasks.render.edit")
local cmd = require("obsidian-tasks.cmd")
local managed = require("obsidian-tasks.render.managed")
local keymap_mod = require("obsidian-tasks.render.keymap")

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

--- Build a multi-file index stub; returns restore function.
--- tasks = { { text, path, row1 }, ... }  (row1 is 1-indexed src line)
local function install_multi_task_stub(tasks)
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
    local i = 0
    return function()
      i = i + 1
      if tasks[i] then
        local t = tasks[i]
        -- Re-read from disk each time so flush results are visible.
        local task_obj
        local ok, lines = pcall(vim.fn.readfile, t.path)
        if ok and lines[t.row1] then
          task_obj = task_parse.parse(lines[t.row1])
        end
        if not task_obj then
          task_obj = task_parse.parse(t.text)
        end
        return task_obj, t.path, t.row1
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Standard single-file dashboard: tmpfile + dashboard + render.
--- Returns bufnr, src_path, cleanup.
local function setup_dashboard(task_text)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ task_text })
  local restore_stub = install_multi_task_stub({
    { text = task_text, path = src_path, row1 = 1 },
  })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)
  local function cleanup()
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

-- ── E1: Single tick s///g across 3 source files → 1 write per file, 1 undo block ──
-- Verifies Q13: all on_lines events in one tick coalesce; group by src_path, single
-- read+write per file; single undo block per tick reverses all source mutations.

T["e2e: single-tick multi-file coalesce — 1 write per file, 1 undo block"] = function()
  render.configure({ default_folded = false })

  local src_a = make_tmpfile({ "- [ ] Alpha task #e1" })
  local src_b = make_tmpfile({ "- [ ] Beta task #e1" })
  local src_c = make_tmpfile({ "- [ ] Gamma task #e1" })

  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved_tasks_in = index_mod.tasks_in
  local saved_srp = index_mod.set_render_paths
  local saved_crp = index_mod.clear_render_paths
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.tasks_in = function(_)
    local entries = {
      { path = src_a, row1 = 1 },
      { path = src_b, row1 = 1 },
      { path = src_c, row1 = 1 },
    }
    local i = 0
    return function()
      i = i + 1
      if entries[i] then
        local ok, lines = pcall(vim.fn.readfile, entries[i].path)
        if ok and lines[1] then
          local t = task_parse.parse(lines[1])
          if t then
            return t, entries[i].path, entries[i].row1
          end
        end
      end
    end
  end

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Track writefile calls per path.
  local write_counts = {}
  local orig_writefile = vim.fn.writefile
  vim.fn.writefile = function(lines, path, ...)
    write_counts[path] = (write_counts[path] or 0) + 1
    return orig_writefile(lines, path, ...)
  end

  -- Simulate :s/#e1/#e1-edited/g touching all three rows in one "tick"
  -- (same as flush() scanning all changed rows in one pass).
  local row_a = TASK_ROW
  local row_b = TASK_ROW + 1
  local row_c = TASK_ROW + 2
  set_line(bufnr, row_a, get_line(bufnr, row_a):gsub("#e1", "#e1-edited"))
  set_line(bufnr, row_b, get_line(bufnr, row_b):gsub("#e1", "#e1-edited"))
  set_line(bufnr, row_c, get_line(bufnr, row_c):gsub("#e1", "#e1-edited"))

  -- flush() is the tick boundary: processes all pending changed rows.
  edit_mod.flush(bufnr)

  vim.fn.writefile = orig_writefile

  -- One write per source file (Q13: coalesced per src_path).
  eq(write_counts[src_a], 1, "E1: src_a must be written exactly once")
  eq(write_counts[src_b], 1, "E1: src_b must be written exactly once")
  eq(write_counts[src_c], 1, "E1: src_c must be written exactly once")

  -- All three source files updated.
  eq(read_src_line(src_a, 0), "- [ ] Alpha task #e1-edited", "E1: src_a must have updated task")
  eq(read_src_line(src_b, 0), "- [ ] Beta task #e1-edited", "E1: src_b must have updated task")
  eq(read_src_line(src_c, 0), "- [ ] Gamma task #e1-edited", "E1: src_c must have updated task")

  -- Single undo block reverses all three source mutations (Q13).
  local undo_ok = cmd.dashboard_undo(bufnr)
  eq(undo_ok, true, "E1: undo must succeed")
  eq(read_src_line(src_a, 0), "- [ ] Alpha task #e1", "E1: src_a must be reverted by undo")
  eq(read_src_line(src_b, 0), "- [ ] Beta task #e1", "E1: src_b must be reverted by undo")
  eq(read_src_line(src_c, 0), "- [ ] Gamma task #e1", "E1: src_c must be reverted by undo")

  -- Cleanup.
  render.clear_buffer(bufnr)
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_srp
  index_mod.clear_render_paths = saved_crp
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  for _, sp in ipairs({ src_a, src_b, src_c }) do
    local b = vim.fn.bufnr(sp, false)
    if b ~= -1 then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    vim.fn.delete(sp)
  end
end

-- ── E2: Normal-mode edit + insert-mode edit on same row → 2 undo blocks ───────
-- Verifies Q1 (tick boundary semantics): normal-mode flush (tick 1) and
-- InsertLeave flush (tick 2) each produce a separate undo ring entry, so two
-- separate `u` presses are needed to reverse both edits.

T["e2e: normal-mode + insert-mode edits on same row produce 2 undo blocks"] = function()
  local bufnr, src_path, cleanup = setup_dashboard("- [ ] Two-tick task #e2")

  -- ── Tick 1: normal-mode cw replacement ────────────────────────────────────
  local canonical = get_line(bufnr, TASK_ROW)
  local after_cw = canonical:gsub("Two%-tick", "Tick-one")
  set_line(bufnr, TASK_ROW, after_cw)
  -- Simulate end-of-tick flush (normal mode).
  edit_mod.flush(bufnr)

  -- Source must reflect tick-1 edit.
  eq(read_src_line(src_path, 0), "- [ ] Tick-one task #e2", "E2: tick-1 edit must land in source")

  -- ── Tick 2: insert-mode description edit ──────────────────────────────────
  -- Re-read canonical (the managed extmark's rendered_text was updated by flush).
  local canonical2 = get_line(bufnr, TASK_ROW)
  local after_insert = canonical2:gsub("Tick%-one", "Tick-two")
  set_line(bufnr, TASK_ROW, after_insert)
  -- Simulate InsertLeave flush (tick 2).
  edit_mod.flush(bufnr)

  -- Source must now reflect tick-2 edit.
  eq(read_src_line(src_path, 0), "- [ ] Tick-two task #e2", "E2: tick-2 edit must land in source")

  -- Two separate undo blocks: first undo reverts tick-2 → source back to tick-1 state.
  local undo1 = cmd.dashboard_undo(bufnr)
  eq(undo1, true, "E2: first undo must succeed")
  eq(read_src_line(src_path, 0), "- [ ] Tick-one task #e2", "E2: first undo reverts to tick-1 source")

  -- Second undo reverts tick-1 → source back to original.
  local undo2 = cmd.dashboard_undo(bufnr)
  eq(undo2, true, "E2: second undo must succeed")
  eq(read_src_line(src_path, 0), "- [ ] Two-tick task #e2", "E2: second undo reverts to original source")

  cleanup()
end

-- ── E3: Wikilink-suffix strip + drift recovery compose without interference ───
-- Verifies that strip_wikilink_suffix (applied at flush time) and drift-content-
-- search (Q12: ±10-row locate) work correctly together in the same flush.
-- Scenario: source file has blank lines inserted ABOVE the task (simulating an
-- external edit that shifts the row), AND the dashboard row carries a wikilink
-- suffix that must be stripped before writing.  The flush must:
--   (a) Strip the wikilink suffix from the edited buffer line.
--   (b) Locate the task at the drifted row via content-search.
--   (c) Write the stripped (correctly described) text at the drifted row.
--   (d) Update the managed extmark's stored source_row to the located row.

T["e2e: wikilink-suffix strip + drift recovery compose in same flush"] = function()
  -- Source file: 5 blank lines, then the task at row 5 (drift from row 0).
  local task_text = "- [ ] Compose task #e3"
  local lines = {}
  for i = 1, 5 do
    lines[i] = "# drift line " .. i
  end
  lines[6] = task_text -- row 5 (0-indexed)
  local src_path = make_tmpfile(lines)

  -- Dashboard was rendered when task was at row 0 (before drift).
  local restore_stub = install_multi_task_stub({
    { text = task_text, path = src_path, row1 = 1 }, -- row1=1 (1-indexed) → source_row=0
  })
  render.configure({ default_folded = false })
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Dashboard row shows "- [ ] Compose task #e3 [[<tmpname>]]".
  -- Simulate user editing the description via cw.
  local canonical = get_line(bufnr, TASK_ROW)
  local edited = canonical:gsub("Compose task", "Edited compose task")
  set_line(bufnr, TASK_ROW, edited)

  -- flush: must strip the wikilink suffix AND locate the task at drifted row 5.
  edit_mod.flush(bufnr)

  -- The write must land at the drifted row 5, NOT at row 0.
  local updated_drifted = read_src_line(src_path, 5)
  eq(
    updated_drifted,
    "- [ ] Edited compose task #e3",
    "E3: flush must write at the drifted row with wikilink suffix stripped"
  )

  -- Rows 0..4 (the drift lines) must be untouched.
  local row0 = read_src_line(src_path, 0)
  eq(row0, "# drift line 1", "E3: drift lines must not be modified")

  -- The managed extmark's source_row must be updated from 0 → 5 (Q12).
  local post_meta = managed.task_meta_for_row(bufnr, TASK_ROW)
  MiniTest.expect.no_equality(post_meta, nil, "E3: task meta must exist after drift-recovery flush")
  eq(post_meta.source_row, 5, "E3: extmark source_row must be updated to located row 5")

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

-- ── E4: Status-flip via <leader>tt on a .md source file still works ───────────
-- Regression guard for the universal keymap path (autocmds.lua P3 wiring):
-- <leader>tt on a source .md file (not a dashboard) must toggle the task
-- status and write to source — the P4+P5 flush wiring must not have broken
-- this path.  This test exercises the cmd.dispatch route (not the on_lines path).

T["e2e: <leader>tt status flip on source .md file (non-dashboard) still works"] = function()
  local task_text = "- [ ] E4 source task"
  local src_path = make_tmpfile({ task_text })

  -- Create a plain buffer (not a rendered dashboard) and add managed meta
  -- manually to simulate a source .md file where the user has the cursor on
  -- a task line (the non-dashboard keymap path).
  local src_bufnr = make_buf({ task_text })

  managed.add_task(src_bufnr, 0, {
    source_file = src_path,
    source_row = 0,
    task_text = task_text,
  })

  -- Stub render and index so dispatch_and_refresh doesn't call obsidian.nvim.
  local orig_rerender = nil
  local index_mod = require("obsidian-tasks.index")
  local saved_refresh = index_mod.refresh_file
  index_mod.refresh_file = function() end

  local render_mod = require("obsidian-tasks.render")
  orig_rerender = render_mod.rerender_buffer
  render_mod.rerender_buffer = function() end

  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return src_bufnr
  end

  keymap_mod.attach(src_bufnr)

  local winid = vim.api.nvim_open_win(src_bufnr, true, {
    relative = "editor",
    width = 80,
    height = 5,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  -- Find and invoke <leader>tt.
  local leader = vim.g.mapleader or "\\"
  local lhs_expanded = ("<leader>tt"):gsub("<[Ll]eader>", leader)
  local km = nil
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(src_bufnr, "n")) do
    if m.lhs == "<leader>tt" or m.lhs == lhs_expanded then
      km = m
      break
    end
  end
  MiniTest.expect.no_equality(km, nil, "E4: <leader>tt keymap must be registered on source buffer")
  if km then
    km.callback()
  end

  vim.api.nvim_win_close(winid, true)
  index_mod.refresh_file = saved_refresh
  render_mod.rerender_buffer = orig_rerender
  vim.api.nvim_get_current_buf = orig_gcb
  keymap_mod.detach(src_bufnr)
  managed.clear_buffer(src_bufnr)
  vim.api.nvim_buf_delete(src_bufnr, { force = true })

  -- Source file must now have [x] checkbox.
  local src_b = vim.fn.bufnr(src_path, false)
  local mutated
  if src_b ~= -1 then
    mutated = vim.api.nvim_buf_get_lines(src_b, 0, 1, false)[1]
    vim.api.nvim_buf_delete(src_b, { force = true })
  else
    mutated = read_file(src_path)[1]
  end
  vim.fn.delete(src_path)

  MiniTest.expect.no_equality(mutated, nil, "E4: source line must not be nil after toggle")
  eq(mutated:sub(1, 5), "- [x]", "E4: <leader>tt must toggle source checkbox to [x]")
end

-- ── E5: P1–P9 full-stack scenario ─────────────────────────────────────────────
--
-- A single scripted scenario that exercises the entire edit-in-place stack.
-- Steps:
--   1. Render a dashboard with a tag-grouped block across one source file.
--   2. cw — edit a task description (P4 classifier + P5 flush MUTATE).
--   3. Insert a date field with "tomorrow" → verifies ISO normalisation (P5 Q2).
--   4. Change a due date → source updated; broadened linger may fire (P6).
--   5. Paste new task into #work tag group → expects #work auto-added (P9).
--      RED: FAILS here — stub returns line unchanged; source task lacks #work.
--   6. dd a task with continuation lines → source removes task + continuation (P8).
--   7. Undo reverses the INSERT from step 5 (P1 undo ring).
--   8. Verify invalid-field task renders without destroying buffer state (P2).
--   9. ggdG gate: mass-delete is reverted; source untouched (P7).
--
-- Steps 1–4 and 6–9 use already-implemented GREEN features.
-- Step 5 FAILS in RED because the P9 stub does not inject #work.
-- All assertions are independent mini-steps; failing step 5 halts the test.

T["e2e: P1-P9 full-stack scenario — P9 group-attr auto-add fails in RED"] = function()
  render.configure({ default_folded = false, linger_on_filter_exit = true })

  -- ── 1. Setup: source file with several tasks, grouped tag dashboard ──────────
  local src_a = make_tmpfile({
    "- [ ] Alpha task #work", -- row 0 (1-indexed row 1)
    "- [ ] Beta task #work", -- row 1
    "  Some continuation note", -- row 2 (continuation for Beta)
  })
  local src_b = make_tmpfile({
    "- [ ] Gamma task #work", -- row 0 (1-indexed row 1)
    "- [ ] Delta invalid 📅 someday", -- row 1 (P2 invalid date)
  })

  -- Index stub: reads both source files each time tasks_in is called.
  local index_mod = require("obsidian-tasks.index")
  local task_parse_mod = require("obsidian-tasks.task.parse")
  local saved_tasks_in = index_mod.tasks_in
  local saved_srp = index_mod.set_render_paths
  local saved_crp = index_mod.clear_render_paths
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.tasks_in = function(_)
    local sources = { src_a, src_b }
    local all = {}
    for _, sp in ipairs(sources) do
      local ok, lines = pcall(vim.fn.readfile, sp)
      if ok then
        for ln, line in ipairs(lines) do
          local t = task_parse_mod.parse(line)
          if t then
            all[#all + 1] = { task = t, path = sp, line_num = ln }
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

  -- Dashboard: single block, group by tags, filter not done.
  local bufnr = make_buf({ "```tasks", "not done", "group by tags", "```" })
  render.render_buffer(bufnr, nil)

  -- Task rows start at row 4 (fence=0, query1=1, query2=2, fence=3, task=4).
  local FIRST_TASK = 4

  -- ── 2. cw — edit Alpha task description (P4 + P5 MUTATE) ────────────────────
  local alpha_row = FIRST_TASK
  local canonical_alpha = get_line(bufnr, alpha_row)
  local edited_alpha = canonical_alpha:gsub("Alpha task", "Alpha edited")
  set_line(bufnr, alpha_row, edited_alpha)
  edit_mod.flush(bufnr)

  local alpha_src = read_file(src_a)
  eq(alpha_src[1], "- [ ] Alpha edited #work", "E5-step2: Alpha description edit must land in source (P5 MUTATE)")

  -- ── 3. Add a due date with "tomorrow" → ISO normalisation (P5 Q2) ────────────
  -- Re-read canonical after flush (managed extmark was updated).
  local canonical_beta = get_line(bufnr, alpha_row + 1)
  local with_tomorrow = canonical_beta:gsub("#work", "📅 tomorrow #work")
  set_line(bufnr, alpha_row + 1, with_tomorrow)
  edit_mod.flush(bufnr)

  local beta_src_after_norm = read_file(src_a)
  local beta_line = beta_src_after_norm[2]
  MiniTest.expect.no_equality(beta_line, nil, "E5-step3: Beta line must exist in source")
  local has_iso = beta_line and beta_line:match("%d%d%d%d%-%d%d%-%d%d") ~= nil
  eq(has_iso, true, "E5-step3: 'tomorrow' must be normalised to ISO date (P5 Q2)")
  local has_literal_tomorrow = beta_line and beta_line:find("tomorrow") ~= nil
  eq(has_literal_tomorrow, false, "E5-step3: 'tomorrow' must NOT appear verbatim after normalisation")

  -- ── 4. Change Gamma task description (verify P5 MUTATE across files) ──────────
  local gamma_row = alpha_row + 2
  local canonical_gamma = get_line(bufnr, gamma_row)
  local edited_gamma = canonical_gamma:gsub("Gamma task", "Gamma updated")
  set_line(bufnr, gamma_row, edited_gamma)
  edit_mod.flush(bufnr)

  local gamma_src = read_file(src_b)
  eq(gamma_src[1], "- [ ] Gamma updated #work", "E5-step4: Gamma edit must land in src_b (P5 cross-file MUTATE)")

  -- ── 5. Paste new task into #work group — expects #work auto-added (P9) ────────
  -- Re-render first: after steps 2-4 the buffer still shows "tomorrow" in Beta's
  -- row (flush writes to source but does not rewrite the dashboard line for
  -- regular MUTATEs).  The stale text causes Beta to appear as a MUTATE again
  -- in step 5's flush, which interferes with the INSERT detection.  A fresh
  -- render_buffer resets meta_snapshot and region_snapshot to a clean baseline.
  render.render_buffer(bufnr, nil)

  -- Insert BETWEEN Alpha (alpha_row) and Beta (alpha_row+1) so the managed
  -- region [alpha_row, alpha_row+1] expands and the new row is inside it.
  -- anchor = Alpha task at alpha_row; new task goes after Alpha in source.
  --
  -- RED: this step FAILS because the stub does not inject #work.
  -- GREEN: source will contain "- [ ] New work task #work".
  local insert_at = alpha_row + 1
  vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, { "- [ ] New work task" })
  edit_mod.flush(bufnr)

  local src_a_after_insert = read_file(src_a)
  -- The new task is written after the anchor (Alpha task at source row 1).
  -- GREEN: src_a has original 3 lines + 1 new; new task has #work.
  local found_new = false
  for _, line in ipairs(src_a_after_insert) do
    if line:find("New work task") then
      found_new = true
      -- P9 assertion: #work must have been injected.
      local has_work_tag = line:find("#work") ~= nil
      eq(has_work_tag, true, "E5-step5: P9 must auto-add #work to new task in #work group")
    end
  end
  eq(found_new, true, "E5-step5: new task must appear in source after INSERT (P8)")

  -- ── 6. dd Beta task (which has a continuation note) — P8 block delete ────────
  -- Beta task is at alpha_row+1 on dashboard; after step 5 insert it may have
  -- shifted.  Use the managed meta to find it robustly.
  -- For simplicity: delete any row that still contains "Beta".
  local beta_row_now = nil
  local buf_lines_count = vim.api.nvim_buf_line_count(bufnr)
  for r = FIRST_TASK, buf_lines_count - 1 do
    local l = get_line(bufnr, r)
    if l and l:find("Beta") then
      beta_row_now = r
      break
    end
  end
  if beta_row_now then
    vim.api.nvim_buf_set_lines(bufnr, beta_row_now, beta_row_now + 1, false, {})
    edit_mod.flush(bufnr)
    -- P8: Beta + its continuation must be removed from source.
    local src_a_after_delete = read_file(src_a)
    local beta_still_present = false
    for _, line in ipairs(src_a_after_delete) do
      if line:find("Beta") then
        beta_still_present = true
      end
    end
    eq(beta_still_present, false, "E5-step6: Beta task must be deleted from source (P8 block delete)")
    local continuation_present = false
    for _, line in ipairs(src_a_after_delete) do
      if line:find("continuation note") then
        continuation_present = true
      end
    end
    eq(continuation_present, false, "E5-step6: Beta continuation must also be deleted (P8 block delete)")
  end

  -- ── 7. Undo INSERT from step 5 (P1 undo ring) ────────────────────────────────
  -- The INSERT in step 5 created an undo entry.  dashboard_undo should reverse it.
  local cmd_mod = require("obsidian-tasks.cmd")
  local undo_ok = cmd_mod.dashboard_undo(bufnr)
  eq(undo_ok, true, "E5-step7: undo must succeed (P1 undo ring)")

  -- ── 8. Verify invalid-field task (Delta) is still in source (P2 regression) ──
  local src_b_final = read_file(src_b)
  local delta_present = false
  for _, line in ipairs(src_b_final) do
    if line:find("Delta invalid") then
      delta_present = true
    end
  end
  eq(delta_present, true, "E5-step8: Delta task with invalid date must remain in source untouched (P2)")

  -- ── 9. ggdG gate — mass-delete reverted; source untouched (P7) ───────────────
  -- Simulate a true "ggdG" by deleting ALL rows (including fences) so the query
  -- block becomes structurally broken.  Per Q6: "block gone → revert".
  -- Deleting only task rows (fences intact) is a legitimate mass-delete and would
  -- propagate per spec; to trigger the gate the fences must also be removed.
  local total_rows = vim.api.nvim_buf_line_count(bufnr)
  if total_rows > 0 then
    local log = require("obsidian-tasks.log")
    local warned = false
    local orig_warn = log.warn
    log.warn = function(msg)
      if tostring(msg):find("dashboard cleared") then
        warned = true
      end
      orig_warn(msg)
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    edit_mod.flush(bufnr)
    log.warn = orig_warn
    -- P7: source files must be untouched; warning must be emitted.
    eq(warned, true, "E5-step9: P7 gate must emit 'dashboard cleared' warning on mass-delete")
  end

  -- ── Cleanup ───────────────────────────────────────────────────────────────────
  render.clear_buffer(bufnr)
  index_mod.tasks_in = saved_tasks_in
  index_mod.set_render_paths = saved_srp
  index_mod.clear_render_paths = saved_crp
  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  for _, sp in ipairs({ src_a, src_b }) do
    local b = vim.fn.bufnr(sp, false)
    if b ~= -1 then
      vim.api.nvim_buf_delete(b, { force = true })
    end
    vim.fn.delete(sp)
  end
end

return T
