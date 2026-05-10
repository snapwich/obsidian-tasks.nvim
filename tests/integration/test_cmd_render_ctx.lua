-- tests/integration/test_cmd_render_ctx.lua
-- Integration test: command mutation on a render-context line triggers F4 write-back.
--
-- Flow under test:
--   1. Render a buffer containing a tasks block (real draw module, stub index).
--      layout.lua appends a wikilink suffix (' [[basename]]') to each task line.
--   2. Run :ObsidianTask cancel on the rendered task line.
--      resolve_task_at strips the wikilink before parsing so the task is clean.
--      cancel_one serializes the mutated task (no wikilink) and writes it back.
--   3. Fire the write-pre pipeline (mirrors User:ObsidianNoteWritePre).
--      F4 Phase 2 detects the hash mismatch and emits a patch.
--   4. Assert source file is patched WITH NO wikilink and buffer is stripped.
--
-- Pre-existing draw mock leakage from unit tests is avoided by force-reloading
-- both render.draw and render.init at test start.

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

--- Build a stub index yielding the given entries.
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

--- Create a scratch buffer pre-populated with lines.
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

--- Force-reload render.draw AND render.init so all module-level state resets.
--- This prevents pre-existing draw mock leakage from unit tests.
local function fresh_draw_and_render()
  package.loaded["obsidian-tasks.render.draw"] = nil
  package.loaded["obsidian-tasks.render.init"] = nil
  return require("obsidian-tasks.render.init")
end

--- Mirror the User:ObsidianNoteWritePre autocmd handler.
--- Diffs each rendered block, applies source-file changes, then strips render.
--- @param bufnr integer  render buffer
local function run_write_pre(bufnr)
  local draw = require("obsidian-tasks.render.draw")
  local edit = require("obsidian-tasks.render.edit")
  local render = require("obsidian-tasks.render")

  local state = draw.render_state(bufnr)
  if not state then
    return
  end

  for _, block in pairs(state) do
    local range = block.inserted_range
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

-- ── S1: cancel on render line — wikilink must NOT appear in patched source ───

T["cancel on render line → source patched cleanly (no wikilink written to disk)"] = function()
  local render = fresh_draw_and_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Source file: task at 1-indexed line 2.
  -- layout.lua will append " [[<basename>]]" to the rendered line because
  -- query/run.lua sets task._src_path = src_path before calling layout.
  local src_path = make_tmpfile({ "# Source", "- [ ] Buy milk" })

  local task = parse.parse("- [ ] Buy milk")
  assert(task ~= nil)

  local restore_idx =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = task, path = src_path, line_num = 2 } }))

  -- Render buffer with one tasks block.
  -- After render: rows 0-2 = fence, row 3 = "- [ ] Buy milk [[<basename>]]".
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Verify the task was rendered at row 3 and that layout appended the wikilink.
  local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  MiniTest.expect.equality(#before_lines >= 4, true)
  MiniTest.expect.equality(before_lines[4]:find("Buy milk", 1, true) ~= nil, true)
  -- Wikilink present in rendered line.
  MiniTest.expect.equality(before_lines[4]:find("%[%[") ~= nil, true)

  -- Run :ObsidianTask cancel on row 3 (1-indexed line 4).
  -- Mock nvim_get_current_buf so the cmd uses the render buffer.
  -- Mock os.date for a deterministic stamp.
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  local orig_date = os.date
  os.date = function(_fmt)
    return "2024-01-15"
  end

  local cancel = require("obsidian-tasks.cmd.cancel")
  cancel.run({}, { line1 = 4, line2 = 4 })

  vim.api.nvim_get_current_buf = orig_gcb
  os.date = orig_date

  -- Render buffer line 4 must show the cancelled task WITHOUT the wikilink.
  -- resolve_task_at strips the wikilink before parsing; cancel_one serializes
  -- the clean task and writes it back to the render buffer.
  local after_cmd_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local render_line = after_cmd_lines[4]
  MiniTest.expect.equality(render_line:sub(1, 5), "- [-]")
  MiniTest.expect.equality(render_line:find("Buy milk", 1, true) ~= nil, true)
  MiniTest.expect.equality(render_line:find("\xe2\x9d\x8c") ~= nil, true) -- ❌
  MiniTest.expect.equality(render_line:find("2024%-01%-15") ~= nil, true)
  -- No wikilink in the render line after mutation.
  MiniTest.expect.equality(render_line:find("%[%[") == nil, true)

  -- Fire write-pre: F4 detects the mutated line (Phase 2 hash mismatch → patch).
  run_write_pre(bufnr)

  -- Source file must have the patched (cancelled) task at line 2.
  local src_lines = vim.fn.readfile(src_path)
  eq(src_lines[1], "# Source")
  MiniTest.expect.equality(src_lines[2]:sub(1, 5), "- [-]")
  MiniTest.expect.equality(src_lines[2]:find("Buy milk", 1, true) ~= nil, true)
  MiniTest.expect.equality(src_lines[2]:find("2024%-01%-15") ~= nil, true)
  -- REGRESSION GUARD: no wikilink in patched source line.
  MiniTest.expect.equality(src_lines[2]:find("%[%[") == nil, true)

  -- Buffer must be stripped to fence-only (3 lines).
  local stripped = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#stripped, 3)
  eq(stripped[1], "```tasks")
  eq(stripped[2], "not done")
  eq(stripped[3], "```")

  -- Cleanup.
  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

-- ── S2: render twice — wikilink not duplicated on second edit ─────────────────
--
-- Regression guard: each render→edit cycle must not accumulate wikilinks.
-- Tests the sequence: render → cancel → write-pre → re-render → cancel again.
-- If resolve_task_at does NOT strip wikilinks, the second cancel would produce
-- "- [-] Task [[note]] [[note]] ❌ ..." and the source would be corrupted.

T["render → cancel → re-render → cancel: wikilink not duplicated in source"] = function()
  local render = fresh_draw_and_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local src_path = make_tmpfile({ "# Note", "- [ ] Task to cycle" })

  local task1 = parse.parse("- [ ] Task to cycle")
  assert(task1 ~= nil)

  local restore_idx =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = task1, path = src_path, line_num = 2 } }))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- First cancel.
  local orig_gcb = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  local orig_date = os.date
  os.date = function(_fmt)
    return "2024-01-15"
  end

  local cancel = require("obsidian-tasks.cmd.cancel")
  cancel.run({}, { line1 = 4, line2 = 4 })

  vim.api.nvim_get_current_buf = orig_gcb
  os.date = orig_date

  run_write_pre(bufnr)

  -- Source is now "- [-] Task to cycle ❌ 2024-01-15".  Restore index stub with
  -- the updated task and re-render under "done" filter (cancelled task is done).
  restore_idx()
  local task2 = parse.parse("- [-] Task to cycle \xe2\x9d\x8c 2024-01-15")
  assert(task2 ~= nil)

  -- Re-render the buffer with the updated task.
  -- Use "not done" query: cancelled tasks have type=CANCELLED which is ≠ DONE,
  -- so they pass the "not done" filter.
  local bufnr2 = make_buf({ "```tasks", "not done", "```" })
  local restore_idx2 =
    install_mock("obsidian-tasks.index", make_index_stub({ { task = task2, path = src_path, line_num = 2 } }))
  render.render_buffer(bufnr2)

  local re_lines = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
  MiniTest.expect.equality(#re_lines >= 4, true)
  local re_task_line = re_lines[4]

  -- The re-rendered line has exactly one wikilink (appended by layout).
  local wikilink_count = 0
  for _ in re_task_line:gmatch("%[%[") do
    wikilink_count = wikilink_count + 1
  end
  eq(wikilink_count, 1)

  -- Run a second cancel on the already-cancelled task (idempotent).
  local orig_gcb2 = vim.api.nvim_get_current_buf
  vim.api.nvim_get_current_buf = function()
    return bufnr2
  end
  cancel.run({}, { line1 = 4, line2 = 4 })
  vim.api.nvim_get_current_buf = orig_gcb2

  run_write_pre(bufnr2)

  -- Source: still only ONE wikilink check (should have none in source).
  local final_lines = vim.fn.readfile(src_path)
  MiniTest.expect.equality(final_lines[2]:find("%[%[") == nil, true)

  -- Cleanup.
  draw_mod.clear(bufnr)
  draw_mod.clear(bufnr2)
  restore_idx2()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.api.nvim_buf_delete(bufnr2, { force = true })
  vim.fn.delete(src_path)
end

return T
