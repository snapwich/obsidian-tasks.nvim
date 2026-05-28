-- tests/unit/test_render_draw.lua
-- Integration tests for render/draw.lua.
-- All vim.api calls are valid because mini.test runs in headless Neovim.

local T = MiniTest.new_set()

-- ── module handles ────────────────────────────────────────────────────────────

local draw_mod = require("obsidian-tasks.render.draw")
local managed = require("obsidian-tasks.render.managed")
local extmark_util = require("obsidian-tasks.util.extmark")
local NS = extmark_util.NS

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]  raw lines (1-indexed)
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Return all draw-NS extmarks for a buffer.
--- @param bufnr integer
--- @return table[]  list of { id, row, col, details }
local function get_extmarks(bufnr)
  return vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
end

--- Find extmarks that have a virt_lines field.
local function virt_line_ems(bufnr)
  local result = {}
  for _, em in ipairs(get_extmarks(bufnr)) do
    local details = em[4]
    if details and details.virt_lines and #details.virt_lines > 0 then
      result[#result + 1] = em
    end
  end
  return result
end

--- Build a minimal single-task layout_lines list (task, footer).
local function simple_layout(task_text, src_path, src_line)
  local hash = vim.fn.sha256(task_text):sub(1, 16)
  return {
    {
      kind = "task",
      text = task_text,
      src_path = src_path or "/vault/note.md",
      src_line = src_line or 5,
      src_hash = hash,
    },
    { kind = "footer", text = "─ 1 result ─" },
  }
end

--- Build a fence_range for lines at indices first..last (0-indexed).
local function fence(first, last)
  return { first, last }
end

-- ── util/extmark.lua ──────────────────────────────────────────────────────────

T["extmark_util: NS is a positive integer"] = function()
  eq(type(NS), "number")
  MiniTest.expect.equality(NS > 0, true)
end

-- ── draw: basic buffer manipulation ──────────────────────────────────────────

T["draw: task text inserted as real buffer line"] = function()
  -- Buffer: line0=```tasks, line1=not done, line2=```
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Buy milk", "/v/note.md", 10)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Task line should appear after the fence (at index 3)
  MiniTest.expect.equality(vim.tbl_contains(lines, "- [ ] Buy milk"), true)
  draw_mod.clear(bufnr)
end

T["draw: task line is at index after closing fence"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] My task", "/v/note.md", 1)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- fence is lines 0-2 (0-indexed), task should be at line 3
  local lines = vim.api.nvim_buf_get_lines(bufnr, 3, 4, false)
  eq(lines[1], "- [ ] My task")
  draw_mod.clear(bufnr)
end

T["draw: multiple tasks inserted in order"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash_a = vim.fn.sha256("- [ ] Alpha"):sub(1, 16)
  local hash_b = vim.fn.sha256("- [ ] Beta"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] Alpha", src_path = "/v/a.md", src_line = 1, src_hash = hash_a },
    { kind = "task", text = "- [ ] Beta", src_path = "/v/b.md", src_line = 2, src_hash = hash_b },
    { kind = "footer", text = "─ 2 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 3, 5, false)
  eq(lines[1], "- [ ] Alpha")
  eq(lines[2], "- [ ] Beta")
  draw_mod.clear(bufnr)
end

-- ── draw: no conceal (fence lines are plain text) ─────────────────────────────
-- Conceal was removed in T2. Fence lines are now visible plain text.
-- Folding (T4) will hide them when the query is collapsed.

T["draw: fence lines have no conceal_lines extmarks"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))

  -- No extmark in the draw NS should have a conceal_lines field.
  for _, em in ipairs(get_extmarks(bufnr)) do
    local details = em[4]
    if details then
      MiniTest.expect.equality(details.conceal_lines, nil)
    end
  end
  draw_mod.clear(bufnr)
end

T["draw: conceallevel is NOT set on windows displaying the buffer"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = 80,
    height = 20,
    row = 0,
    col = 0,
  })
  local orig_cl = vim.api.nvim_win_get_option(winid, "conceallevel")
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))
  -- conceallevel must be unchanged (draw no longer sets it).
  eq(vim.api.nvim_win_get_option(winid, "conceallevel"), orig_cl)
  draw_mod.clear(bufnr)
  vim.api.nvim_win_close(winid, true)
end

-- ── draw: virt_lines ─────────────────────────────────────────────────────────

T["draw: virt_lines extmarks present (footer)"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))

  -- Expect at least one footer virt_line.
  local vems = virt_line_ems(bufnr)
  MiniTest.expect.equality(#vems >= 1, true)
  draw_mod.clear(bufnr)
end

T["draw: footer virt_line text matches layout footer"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] T")
  layout[2].text = "─ sorted: due asc │ 1 result ─"
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local found = false
  for _, em in ipairs(virt_line_ems(bufnr)) do
    for _, row in ipairs(em[4].virt_lines) do
      for _, chunk in ipairs(row) do
        if type(chunk[1]) == "string" and chunk[1]:find("sorted: due asc", 1, true) then
          found = true
        end
      end
    end
  end
  MiniTest.expect.equality(found, true)
  draw_mod.clear(bufnr)
end

T["draw: group_header appears as virt_line before task"] = function()
  local bufnr = make_buf({ "```tasks", "group by path", "```" })
  local hash = vim.fn.sha256("- [ ] T"):sub(1, 16)
  local layout = {
    { kind = "group_header", text = "## /vault/note.md" },
    { kind = "task", text = "- [ ] T", src_path = "/vault/note.md", src_line = 1, src_hash = hash },
    { kind = "footer", text = "─ 1 result ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local found = false
  for _, em in ipairs(virt_line_ems(bufnr)) do
    for _, row in ipairs(em[4].virt_lines) do
      for _, chunk in ipairs(row) do
        if type(chunk[1]) == "string" and chunk[1]:find("## /vault/note.md", 1, true) then
          found = true
        end
      end
    end
  end
  MiniTest.expect.equality(found, true)
  draw_mod.clear(bufnr)
end

-- ── draw: no task lines ───────────────────────────────────────────────────────

T["draw: buffer unchanged when layout has no task lines"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = {
    { kind = "footer", text = "─ 0 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Buffer should still have exactly 3 lines (fence only, no task lines inserted).
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  eq(#lines, 3)
  draw_mod.clear(bufnr)
end

T["draw: zero-task footer anchors at fence_last, not inside the fence"] = function()
  -- Buffer has prose after the fence so this dashboard does NOT end at EOF
  -- (keeps the assertion stable once the EOF sentinel lands).
  local bufnr = make_buf({ "```tasks", "not done", "```", "after the fence" })
  local layout = {
    { kind = "footer", text = "─ 0 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- The footer virt_line must anchor on the closing fence (row 2 = fence_last)
  -- so it renders AFTER ``` rather than inside the fence at row 0 (fence_first).
  local footer_row = nil
  for _, em in ipairs(virt_line_ems(bufnr)) do
    for _, row in ipairs(em[4].virt_lines) do
      for _, chunk in ipairs(row) do
        if type(chunk[1]) == "string" and chunk[1]:find("0 results", 1, true) then
          footer_row = em[2]
        end
      end
    end
  end
  eq(footer_row, 2)
  draw_mod.clear(bufnr)
end

-- ── draw: managed-region extmarks ────────────────────────────────────────────

T["draw: managed fence extmark created for each block"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T", "/v/note.md", 1))

  -- managed.fence_marks should iterate exactly one fence extmark.
  local count = 0
  local found_range = nil
  for _, recorded, _ in managed.fence_marks(bufnr) do
    count = count + 1
    found_range = recorded
  end
  eq(count, 1)
  MiniTest.expect.equality(found_range ~= nil, true)
  eq(found_range[1], 0) -- fence_start_row
  eq(found_range[2], 2) -- fence_end_row

  draw_mod.clear(bufnr)
end

T["draw: managed task extmark created for each task row"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] Check me", "/vault/tasks.md", 42))

  -- Task was inserted at line 3 (0-indexed).
  local meta = managed.task_meta_for_row(bufnr, 3)
  MiniTest.expect.equality(meta ~= nil, true)
  eq(meta.source_file, "/vault/tasks.md")
  eq(meta.source_row, 41) -- 0-indexed (42 - 1)
  eq(meta.task_text, "- [ ] Check me") -- pre-wikilink (no src_path wikilink in this test)

  draw_mod.clear(bufnr)
end

T["draw: managed task text strips wikilink suffix"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  -- task text includes a wikilink (as layout.lua would add when backlinks visible)
  local rendered_text = "- [ ] My task [[note]]"
  local hash = vim.fn.sha256(rendered_text):sub(1, 16)
  local layout = {
    {
      kind = "task",
      text = rendered_text,
      src_path = "/vault/note.md",
      src_line = 7,
      src_hash = hash,
      -- wikilink_target is the exact link text layout appended; draw.lua strips
      -- it (not the src_path basename) to recover the clean source text.
      wikilink_target = "note",
    },
    { kind = "footer", text = "─ 1 result ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local meta = managed.task_meta_for_row(bufnr, 3)
  MiniTest.expect.equality(meta ~= nil, true)
  -- Wikilink " [[note]]" should be stripped.
  eq(meta.task_text, "- [ ] My task")

  draw_mod.clear(bufnr)
end

T["draw: managed region extmark covers all task rows"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash_a = vim.fn.sha256("- [ ] A"):sub(1, 16)
  local hash_b = vim.fn.sha256("- [ ] B"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] A", src_path = "/v/a.md", src_line = 1, src_hash = hash_a },
    { kind = "task", text = "- [ ] B", src_path = "/v/b.md", src_line = 2, src_hash = hash_b },
    { kind = "footer", text = "─ 2 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Tasks inserted at rows 3 and 4.  Region should cover both.
  local r3 = managed.region_for_row(bufnr, 3)
  local r4 = managed.region_for_row(bufnr, 4)
  MiniTest.expect.equality(r3 ~= nil, true)
  MiniTest.expect.equality(r4 ~= nil, true)
  -- Both rows should resolve to the same region.
  eq(r3.mark_id, r4.mark_id)

  draw_mod.clear(bufnr)
end

T["draw: no managed region extmark when no task lines"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = {
    { kind = "footer", text = "─ 0 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- No tasks → no region extmark → region_for_row returns nil for all rows.
  eq(managed.region_for_row(bufnr, 3), nil)

  draw_mod.clear(bufnr)
end

T["draw: multiple tasks — task_meta populated for each row"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash_a = vim.fn.sha256("- [ ] Alpha"):sub(1, 16)
  local hash_b = vim.fn.sha256("- [ ] Beta"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] Alpha", src_path = "/v/a.md", src_line = 10, src_hash = hash_a },
    { kind = "task", text = "- [ ] Beta", src_path = "/v/b.md", src_line = 20, src_hash = hash_b },
    { kind = "footer", text = "─ 2 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local meta_a = managed.task_meta_for_row(bufnr, 3)
  local meta_b = managed.task_meta_for_row(bufnr, 4)
  MiniTest.expect.equality(meta_a ~= nil, true)
  MiniTest.expect.equality(meta_b ~= nil, true)
  eq(meta_a.source_file, "/v/a.md")
  eq(meta_a.source_row, 9) -- 0-indexed
  eq(meta_b.source_file, "/v/b.md")
  eq(meta_b.source_row, 19) -- 0-indexed

  draw_mod.clear(bufnr)
end

-- ── clear ─────────────────────────────────────────────────────────────────────

T["clear: removes inserted task lines"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] Remove me"))

  draw_mod.clear(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Only the original 3 fence lines should remain.
  eq(#lines, 3)
  MiniTest.expect.equality(vim.tbl_contains(lines, "- [ ] Remove me"), false)
end

T["clear: removes all draw-NS extmarks"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))
  draw_mod.clear(bufnr)

  local ems = get_extmarks(bufnr)
  eq(#ems, 0)
end

T["clear: removes all managed extmarks"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T", "/v/note.md", 1))
  draw_mod.clear(bufnr)

  -- managed side tables must be empty.
  local counts = managed._debug_counts(bufnr)
  eq(counts.task_meta_count, 0)
  eq(counts.fence_mark_count, 0)
  eq(counts.region_mark_count, 0)
end

T["clear: no-op on buffer with no render"] = function()
  local bufnr = make_buf({ "some text" })
  -- Should not error.
  MiniTest.expect.no_error(function()
    draw_mod.clear(bufnr)
  end)
end

T["clear: render_state returns nil after clear"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))
  draw_mod.clear(bufnr)
  eq(draw_mod.render_state(bufnr), nil)
end

-- ── redraw: managed state cleaned up and recreated ────────────────────────────

T["redraw: managed extmarks replaced on re-draw of same block"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Task A", "/v/a.md", 1)

  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Verify initial state.
  local meta_before = managed.task_meta_for_row(bufnr, 3)
  MiniTest.expect.equality(meta_before ~= nil, true)
  eq(meta_before.source_file, "/v/a.md")

  -- Re-draw the same block with a different task.
  local layout2 = simple_layout("- [ ] Task B", "/v/b.md", 5)
  draw_mod.draw(bufnr, fence(0, 2), layout2)

  -- Old managed state should be gone; new state should reflect the new task.
  local meta_after = managed.task_meta_for_row(bufnr, 3)
  MiniTest.expect.equality(meta_after ~= nil, true)
  eq(meta_after.source_file, "/v/b.md")

  draw_mod.clear(bufnr)
end

-- ── clear + draw idempotency ──────────────────────────────────────────────────

T["idempotent: clear then draw produces same buffer text"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Idempotent task", "/v/note.md", 7)

  draw_mod.draw(bufnr, fence(0, 2), layout)
  local lines_first = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  draw_mod.clear(bufnr)
  draw_mod.draw(bufnr, fence(0, 2), layout)
  local lines_second = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  eq(#lines_first, #lines_second)
  for i = 1, #lines_first do
    eq(lines_first[i], lines_second[i])
  end
  draw_mod.clear(bufnr)
end

T["idempotent: clear then draw produces same extmark count"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Idempotent task")

  draw_mod.draw(bufnr, fence(0, 2), layout)
  local em_count_first = #get_extmarks(bufnr)

  draw_mod.clear(bufnr)
  draw_mod.draw(bufnr, fence(0, 2), layout)
  local em_count_second = #get_extmarks(bufnr)

  eq(em_count_first, em_count_second)
  draw_mod.clear(bufnr)
end

T["idempotent: redraw without explicit clear also idempotent"] = function()
  -- draw() internally calls clear() when state already exists.
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Task")

  draw_mod.draw(bufnr, fence(0, 2), layout)
  draw_mod.draw(bufnr, fence(0, 2), layout) -- second draw without clear

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  -- Still only one task line inserted (not doubled).
  local task_count = 0
  for _, l in ipairs(lines) do
    if l == "- [ ] Task" then
      task_count = task_count + 1
    end
  end
  eq(task_count, 1)
  draw_mod.clear(bufnr)
end

-- ── is_render_line ────────────────────────────────────────────────────────────

T["is_render_line: returns metadata for task line"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = simple_layout("- [ ] Check me", "/vault/tasks.md", 42)
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Task was inserted at line index 3 (0-indexed).
  local meta = draw_mod.is_render_line(bufnr, 3)
  MiniTest.expect.equality(meta ~= nil, true)
  eq(meta.src_path, "/vault/tasks.md")
  eq(meta.src_line, 42)
  MiniTest.expect.equality(type(meta.src_hash), "string")
  eq(#meta.src_hash, 16)
  draw_mod.clear(bufnr)
end

T["is_render_line: returns nil for fence line"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T", "/v/n.md", 1))

  -- Line 0 is the fence opening — not a task line.
  eq(draw_mod.is_render_line(bufnr, 0), nil)
  draw_mod.clear(bufnr)
end

T["is_render_line: returns nil for line outside render"] = function()
  local bufnr = make_buf({ "normal line", "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(1, 3), simple_layout("- [ ] T", "/v/n.md", 1))

  -- Line 0 is before the fence.
  eq(draw_mod.is_render_line(bufnr, 0), nil)
  draw_mod.clear(bufnr)
end

T["is_render_line: returns nil after clear"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T", "/v/n.md", 1))
  draw_mod.clear(bufnr)

  eq(draw_mod.is_render_line(bufnr, 3), nil)
end

T["is_render_line: returns nil for buffer with no render"] = function()
  local bufnr = make_buf({ "just text" })
  eq(draw_mod.is_render_line(bufnr, 0), nil)
end

-- ── render_state ──────────────────────────────────────────────────────────────

-- render_state now returns a map keyed by fence_first (0-indexed).
-- All single-block tests access state via render_state(bufnr)[fence_first].

T["render_state: returns state record after draw"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))

  -- render_state returns { [fence_first] = block_state }
  local all_state = draw_mod.render_state(bufnr)
  MiniTest.expect.equality(all_state ~= nil, true)
  local state = all_state[0]
  MiniTest.expect.equality(state ~= nil, true)
  eq(type(state.fence_range), "table")
  eq(type(state.em_map), "table")
  draw_mod.clear(bufnr)
end

T["render_state: fence_range matches argument"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] T"))

  local state = draw_mod.render_state(bufnr)[0]
  eq(state.fence_range[1], 0)
  eq(state.fence_range[2], 2)
  draw_mod.clear(bufnr)
end

T["render_state: inserted_range covers task lines"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local hash_a = vim.fn.sha256("- [ ] A"):sub(1, 16)
  local hash_b = vim.fn.sha256("- [ ] B"):sub(1, 16)
  local layout = {
    { kind = "task", text = "- [ ] A", src_path = "/v/a.md", src_line = 1, src_hash = hash_a },
    { kind = "task", text = "- [ ] B", src_path = "/v/b.md", src_line = 2, src_hash = hash_b },
    { kind = "footer", text = "─ 2 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local state = draw_mod.render_state(bufnr)[0]
  -- 2 tasks inserted after fence (line 2), so range 3..4
  eq(state.inserted_range[1], 3)
  eq(state.inserted_range[2], 4)
  draw_mod.clear(bufnr)
end

T["render_state: inserted_range is nil when no task lines"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local layout = {
    { kind = "footer", text = "─ 0 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  local state = draw_mod.render_state(bufnr)[0]
  eq(state.inserted_range, nil)
  draw_mod.clear(bufnr)
end

T["render_state: returns nil when no render active"] = function()
  local bufnr = make_buf({ "text" })
  eq(draw_mod.render_state(bufnr), nil)
end

-- ── multi-block ────────────────────────────────────────────────────────────────

T["draw: two blocks in same buffer have independent state"] = function()
  -- Buffer with two fences; second fence starts at line 4.
  local bufnr = make_buf({
    "```tasks", -- 0
    "not done", -- 1
    "```", -- 2
    "", -- 3
    "```tasks", -- 4
    "done", -- 5
    "```", -- 6
  })

  local layout_a = simple_layout("- [ ] Alpha", "/v/a.md", 1)
  local layout_b = simple_layout("- [x] Beta", "/v/b.md", 2)

  -- Draw block A (fence 0-2), then block B (fence 4-6).
  draw_mod.draw(bufnr, fence(0, 2), layout_a)
  -- After block A: 1 task inserted after line 2, so block B fence is now at 5-7.
  draw_mod.draw(bufnr, fence(5, 7), layout_b)

  -- Both blocks' state should exist independently.
  local all_state = draw_mod.render_state(bufnr)
  MiniTest.expect.equality(all_state ~= nil, true)
  MiniTest.expect.equality(all_state[0] ~= nil, true)
  MiniTest.expect.equality(all_state[5] ~= nil, true)

  draw_mod.clear(bufnr)
end

T["draw: redrawing one block does not clear the other"] = function()
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "",
    "```tasks",
    "done",
    "```",
  })
  local layout_a = simple_layout("- [ ] A", "/v/a.md", 1)
  local layout_b = simple_layout("- [x] B", "/v/b.md", 2)

  draw_mod.draw(bufnr, fence(0, 2), layout_a)
  -- block B fence adjusted for block A's insertion (+1 task line)
  draw_mod.draw(bufnr, fence(5, 7), layout_b)

  -- Redraw block A only; block B state must survive.
  draw_mod.draw(bufnr, fence(0, 2), layout_a)

  local all_state = draw_mod.render_state(bufnr)
  MiniTest.expect.equality(all_state[5] ~= nil, true)

  draw_mod.clear(bufnr)
end

T["clear: removes all blocks for buffer"] = function()
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "",
    "```tasks",
    "done",
    "```",
  })
  draw_mod.draw(bufnr, fence(0, 2), simple_layout("- [ ] A"))
  draw_mod.draw(bufnr, fence(5, 7), simple_layout("- [x] B"))

  draw_mod.clear(bufnr)

  eq(draw_mod.render_state(bufnr), nil)
  -- All draw-NS extmarks should be gone.
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
  eq(#ems, 0)
  -- All managed extmarks should be gone.
  local ns = managed.namespace()
  local managed_ems = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
  eq(#managed_ems, 0)
end

return T
