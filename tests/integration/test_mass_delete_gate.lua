-- tests/integration/test_mass_delete_gate.lua
-- RED-phase integration tests for the P7 mass-delete safety gate.
--
-- ALL tests in this file are intentionally FAILING in the RED phase:
--
--   Q6 decision:
--     • delete_count == 1  → always propagate (single dd).
--     • delete_count >= 2, block intact  → propagate (single undo block).
--     • delete_count >= 2, block gone    → revert all; notify "dashboard
--                                          cleared — source untouched".
--
--   RED stub: gate.query_block_intact always returns true (no-op).
--   Flush does not yet handle DELETE propagation (new_text == nil rows are
--   skipped in the changed list) and emits no notification for intact-block
--   mass delete or block-gone scenarios.
--
-- Expected failures:
--   • "single dd propagates" — source is NOT mutated in RED (flush skips nil
--     rows); test expects source to have 0 tasks → FAIL.
--   • "2dd intact block: both propagate" — same reason → FAIL.  Additional
--     GREEN-only undo assertions are unreachable in RED (first assertion
--     fails first, halting the test).
--   • "ggdG: no source mutation + warn" — source stays clean (acceptable in
--     RED), but no warn notification is emitted → FAIL on warn check.
--     Additional GREEN-only dashboard-restore assertion unreachable in RED.
--   • ":%d: same as ggdG" — same failure mode → FAIL.
--   • "multi-block: broken block, other block MUTATE reverts" — genuine
--     two-block scenario: bottom block dismantled + top block MUTATED in same
--     tick.  MUTATE propagates to source in RED (gate stub does not trigger
--     atomic revert) → FAIL.

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

--- Stub the task index to return tasks read from *src_paths* (list of paths).
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

--- Install a single-file index stub.  Returns restore function.
local function install_file_stub(src_path)
  return install_multi_file_stub({ src_path })
end

--- Standard single-task dashboard scaffold.
--- Returns: bufnr, src_path, cleanup.
local function setup_single_task_dashboard(task_text)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ task_text })
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

--- Two-task dashboard scaffold: both tasks from the same source file.
--- Returns: bufnr, src_path, cleanup.
local function setup_two_task_dashboard(task_a, task_b)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ task_a, task_b })
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

--- Capture log.warn calls during fn(), restore afterward.
--- Returns: warned (bool), messages (list).
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
-- (Rows 0-2 are the fence block; task rows are inserted below row 2.)
local TASK_ROW = 3

-- ── Q6: single dd always propagates ──────────────────────────────────────────

-- RED: FAILS — flush skips nil-text rows; source remains with 1 task.
-- GREEN contract: a single deleted managed row (delete_count == 1) must cause
-- the source line to be deleted from the source file, regardless of whether
-- the query block is intact.
T["mass delete gate: single dd propagates to source"] = function()
  local bufnr, src_path, cleanup = setup_single_task_dashboard("- [ ] Task Alpha #task")

  -- Simulate `dd` on the single task row: remove it from the buffer.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 1, false, {})

  -- Flush synchronously (skip vim.schedule).
  edit_mod.flush(bufnr)

  -- GREEN expectation: task was deleted from source.
  local src_lines = read_file(src_path)
  eq(#src_lines, 0, "single dd must propagate: source must have 0 lines after the task is deleted")

  cleanup()
end

-- ── Q6: 2dd on intact block propagates ───────────────────────────────────────

-- RED: FAILS — flush skips nil-text rows; source still has 2 tasks.
-- GREEN contract: when delete_count >= 2 AND the query block is intact (fences
-- present), both DELETEs must propagate as a single source mutation.
T["mass delete gate: 2dd on intact block propagates both DELETEs"] = function()
  local bufnr, src_path, cleanup = setup_two_task_dashboard("- [ ] Task Beta1 #task", "- [ ] Task Beta2 #task")

  -- Simulate visual-line `2dd`: delete both task rows atomically.
  vim.api.nvim_buf_set_lines(bufnr, TASK_ROW, TASK_ROW + 2, false, {})

  edit_mod.flush(bufnr)

  -- GREEN expectation: both tasks deleted from source.
  local src_lines = read_file(src_path)
  eq(#src_lines, 0, "2dd on intact block must propagate: source must have 0 lines after both tasks deleted")

  -- GREEN addition: one u reverses BOTH deletions (drives single-undo-block
  -- contract for mass deletes on intact blocks).  Unreachable in RED because
  -- the assertion above already halts the test.
  local cmd_mod = require("obsidian-tasks.cmd")
  local ok_undo = cmd_mod.dashboard_undo(bufnr)
  eq(ok_undo, true, "single undo must succeed after 2dd propagation")
  local src_after_undo = read_file(src_path)
  eq(#src_after_undo, 2, "single undo must restore both deleted tasks to source")

  cleanup()
end

-- ── Q6: ggdG — no source mutation + warn notification ────────────────────────

-- RED: FAILS — flush emits no warn notification (gate stub is a no-op).
-- Source is coincidentally unchanged in RED (flush early-returns with changed={})
-- but the warn assertion drives the failure.
-- GREEN contract: when the buffer is cleared (delete_count >= 2, block gone),
-- no source mutation must occur AND a warn notification "dashboard cleared —
-- source untouched" must be emitted.
T["mass delete gate: ggdG emits warn and leaves source untouched"] = function()
  local bufnr, src_path, cleanup = setup_two_task_dashboard("- [ ] Task Gamma1 #task", "- [ ] Task Gamma2 #task")

  local src_before = read_file(src_path)

  -- Simulate ggdG: clear the entire buffer.
  local warned, warn_msgs = capture_warns(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
    edit_mod.flush(bufnr)
  end)

  -- Source must be untouched.
  local src_after = read_file(src_path)
  eq(src_after, src_before, "ggdG must not mutate source — dashboard cleared safely")

  -- Warn notification must have fired.
  eq(warned, true, "ggdG must emit a warn notification (dashboard cleared — source untouched)")

  -- The notification message must describe the safety action.
  local found_msg = false
  for _, m in ipairs(warn_msgs) do
    if m:find("dashboard cleared") or m:find("source untouched") then
      found_msg = true
      break
    end
  end
  eq(found_msg, true, "warn message must mention 'dashboard cleared' or 'source untouched'")

  -- GREEN addition: gate revert must restore the dashboard buffer so rendered
  -- task rows are visible again after the safety guard fires.  Unreachable in
  -- RED because the warn assertion above already halts the test.
  revert._flush_pending(bufnr)
  local buf_lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#buf_lines_after > 0, true, "gate revert must restore dashboard buffer (must not remain empty after ggdG)")

  cleanup()
end

-- ── Q6: :%d — same semantics as ggdG ─────────────────────────────────────────

-- RED: FAILS — flush emits no warn notification (gate stub is a no-op).
-- GREEN contract: `:%d` (delete all lines) behaves identically to ggdG:
-- no source mutation + warn notification.
T["mass delete gate: colon-percent-d emits warn and leaves source untouched"] = function()
  local bufnr, src_path, cleanup = setup_two_task_dashboard("- [ ] Task Delta1 #task", "- [ ] Task Delta2 #task")

  local src_before = read_file(src_path)

  -- `:%d` equivalent: delete every line in the buffer.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

  -- Flush and capture any warn notification.
  local warned, _ = capture_warns(function()
    edit_mod.flush(bufnr)
  end)

  local src_after = read_file(src_path)
  eq(src_after, src_before, ":%d must not mutate source")
  eq(warned, true, ":%d must emit a warn notification")

  cleanup()
end

-- ── Q6: multi-block broken block + intact-block MUTATE → atomic revert ───────

-- RED: FAILS — gate stub returns true (no-op); the MUTATE in the intact top
-- block propagates to the source file, but GREEN must revert it.
--
-- GREEN contract: when delete_count >= 2 AND ANY block in the buffer is not
-- intact, ALL edits in the tick — including MUTATEs in still-intact blocks —
-- must be reverted (atomic, buffer-wide semantics).  No source must be
-- modified.
--
-- Scenario (genuine two-block):
--   • Two-block dashboard (top block rows 0-2, bottom block rows 6-8 after
--     render).  Both blocks query "not done"; source has three tasks (Nu1-3).
--     After render: top tasks at snapshot rows 3-5, bottom tasks at rows 9-11.
--   • Bottom block's opening fence (row 6) is overwritten → block broken.
--   • Two task rows from the bottom block are deleted (delete_count = 2).
--     After 2 deletions, snapshot rows 10-11 are beyond the buffer end → nil.
--   • Nu2 in the still-intact TOP block (snapshot row 4) is mutated in the
--     same tick.  Top block rows 3-5 are unaffected by the bottom deletions
--     because the revert snapshot is not adjusted for managed-row deletions.
--   • Expected (GREEN): buffer-wide gate fires → revert ALL including top
--     MUTATE → source unchanged + warn.
--   • RED: gate is a no-op stub → MUTATE propagates → source modified → FAIL.
T["mass delete gate: broken block causes co-occurring MUTATE to revert atomically"] = function()
  render.configure({ default_folded = false })

  -- Three tasks in source; both query blocks show all three (same "not done"
  -- query, same stub).
  local src = make_tmpfile({
    "- [ ] Task Nu1 #task",
    "- [ ] Task Nu2 #task",
    "- [ ] Task Nu3 #task",
  })
  local restore = install_file_stub(src)

  -- Two-block dashboard buffer: top block (rows 0-2 of cleared buf) and
  -- bottom block (rows 3-5 of cleared buf → shifts to rows 6-8 after the top
  -- block's 3 tasks are inserted at rows 3-5 during render).
  local bufnr = make_buf({ "```tasks", "not done", "```", "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Post-render layout (0-indexed):
  --   Rows 0-2  : top block fences + query
  --   Rows 3-5  : top block tasks (Nu1, Nu2, Nu3)   ← snapshot rows 3-5
  --   Rows 6-8  : bottom block fences + query        ← fence open at row 6
  --   Rows 9-11 : bottom block tasks (Nu1, Nu2, Nu3) ← snapshot rows 9-11
  local BOT_FENCE_OPEN = 6
  local BOT_TASK_ROW = 9
  local TOP_MUTATE_ROW = 4 -- Nu2 in top block; snapshot row 4 stays valid

  local src_before = read_file(src)

  -- Step 1: Dismantle bottom block's opening fence (replace → no line shift).
  vim.api.nvim_buf_set_lines(bufnr, BOT_FENCE_OPEN, BOT_FENCE_OPEN + 1, false, { "" })

  -- Step 2: Delete two task rows from bottom block (delete_count = 2).
  -- Fence overwrite was a replace → buffer line count unchanged → BOT_TASK_ROW
  -- still points at the first bottom-block task.
  vim.api.nvim_buf_set_lines(bufnr, BOT_TASK_ROW, BOT_TASK_ROW + 1, false, {})
  -- After first deletion, rows 10-11 shift to 9-10.  Delete again at same pos.
  vim.api.nvim_buf_set_lines(bufnr, BOT_TASK_ROW, BOT_TASK_ROW + 1, false, {})
  -- Buffer now has 10 lines (rows 0-9).  Snapshot rows 10 and 11 are beyond
  -- the buffer end → cur[1] == nil → delete_count = 2.

  -- Step 3: Mutate Nu2 in the still-intact top block.
  -- Top block rows 3-5 are unaffected by bottom-block managed-row deletions
  -- (the revert snapshot is only adjusted for prose/untouched edits, not for
  -- touched-managed-row deletions).  Snapshot row 4 still has Nu2's meta and
  -- live row 4 still holds Nu2's rendered content.
  local cur_top = vim.api.nvim_buf_get_lines(bufnr, TOP_MUTATE_ROW, TOP_MUTATE_ROW + 1, false)
  if cur_top[1] and cur_top[1]:match("^%s*%-%s+%[") then
    local mutated = (cur_top[1]:gsub("Nu2", "Nu2 MUTATED"))
    vim.api.nvim_buf_set_lines(bufnr, TOP_MUTATE_ROW, TOP_MUTATE_ROW + 1, false, { mutated })
  end

  local warned_atomic, _ = capture_warns(function()
    edit_mod.flush(bufnr)
  end)

  -- GREEN expectation: buffer-wide gate fires (bottom block broken) →
  -- ALL edits in the tick revert atomically → top-block MUTATE must NOT
  -- propagate.  In RED the MUTATE propagates → source is modified → FAIL.
  local src_after = read_file(src)
  eq(
    src_after,
    src_before,
    "intact-block MUTATE must revert atomically when any block is broken — source must be unchanged"
  )

  -- In GREEN, a warn notification fires.
  eq(warned_atomic, true, "broken-block multi-block tick must emit a warn notification")

  render.clear_buffer(bufnr)
  restore()
  revert._cleanup(bufnr)
  local sb = vim.fn.bufnr(src, false)
  if sb ~= -1 then
    vim.api.nvim_buf_delete(sb, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src)
end

return T
