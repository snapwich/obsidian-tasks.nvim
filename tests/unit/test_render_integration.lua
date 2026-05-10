-- tests/unit/test_render_integration.lua
-- Integration tests for the F3 render feature.
--
-- Verifies the full render pipeline end-to-end:
--   • Rendered buffer text matches expected content.
--   • Fence concealment extmarks are applied correctly.
--   • <CR> on a render task line jumps to source file + correct line.
--   • <CR> on a non-render line falls through to smart_action.
--   • Two ```tasks blocks in one file render independently.
--
-- Uses a stub index (no vault walk required).  draw, layout, and init modules
-- run for real; keymap dispatch is tested through its draw wiring.

local T = MiniTest.new_set()

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(actual, expected)
  MiniTest.expect.equality(actual, expected)
end

--- Create a scratch buffer pre-populated with lines.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Install *mock* at *name* in package.loaded; return a cleanup function.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Build a stub index that yields the given entries from tasks_in().
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

--- Force-reload render/init module (clears _buffer_state, _lazy_init_started).
local function fresh_render()
  package.loaded["obsidian-tasks.render.init"] = nil
  return require("obsidian-tasks.render.init")
end

--- Return keymap callback for *lhs* in buffer *bufnr*, or nil.
local function find_callback(bufnr, lhs)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs then
      return m.callback
    end
  end
  return nil
end

-- ── 1. Rendered text snapshot ──────────────────────────────────────────────────

T["integration: rendered buffer contains task text as real line"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local t = parse.parse("- [ ] Buy milk")
  assert(t ~= nil)
  local stub = make_index_stub({ { task = t, path = "/vault/tasks_a.md", line_num = 5 } })
  local restore_idx = install_mock("obsidian-tasks.index", stub)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local found = false
  for _, l in ipairs(lines) do
    if l:find("Buy milk", 1, true) then
      found = true
    end
  end
  MiniTest.expect.equality(found, true)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["integration: label line is a virt_line, not real buffer text"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local extmark_util = require("obsidian-tasks.util.extmark")
  local parse = require("obsidian-tasks.task.parse")

  local t = parse.parse("- [ ] Alpha")
  assert(t ~= nil)
  local stub = make_index_stub({ { task = t, path = "/vault/tasks_a.md", line_num = 5 } })
  local restore_idx = install_mock("obsidian-tasks.index", stub)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  -- Label text must NOT appear in real buffer lines.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local label_in_buf = false
  for _, l in ipairs(lines) do
    if l:find("▶ tasks", 1, true) then
      label_in_buf = true
    end
  end
  MiniTest.expect.equality(label_in_buf, false)

  -- Label text MUST appear in virt_lines extmarks.
  local NS = extmark_util.NS
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
  local label_in_virt = false
  for _, em in ipairs(ems) do
    local details = em[4]
    if details and details.virt_lines then
      for _, row in ipairs(details.virt_lines) do
        for _, chunk in ipairs(row) do
          if type(chunk[1]) == "string" and chunk[1]:find("▶ tasks", 1, true) then
            label_in_virt = true
          end
        end
      end
    end
  end
  MiniTest.expect.equality(label_in_virt, true)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["integration: task line ends with wikilink backlink"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local t = parse.parse("- [ ] Buy milk")
  assert(t ~= nil)
  local stub = make_index_stub({ { task = t, path = "/vault/tasks_a.md", line_num = 5 } })
  local restore_idx = install_mock("obsidian-tasks.index", stub)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local has_wikilink = false
  for _, l in ipairs(lines) do
    -- Expect [[tasks_a]] (basename without extension).
    if l:find("%[%[tasks_a%]%]") then
      has_wikilink = true
    end
  end
  MiniTest.expect.equality(has_wikilink, true)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── 2. Fence concealment ───────────────────────────────────────────────────────

T["integration: fence lines have conceal_lines extmarks"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local extmark_util = require("obsidian-tasks.util.extmark")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr)

  local NS = extmark_util.NS
  local ems = vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, { details = true })
  local conceal_count = 0
  for _, em in ipairs(ems) do
    local details = em[4]
    if details and details.conceal_lines ~= nil then
      eq(details.conceal_lines, "") -- value must be empty string
      conceal_count = conceal_count + 1
    end
  end
  -- Exactly 3 fence lines (open, query, close) should be concealed.
  eq(conceal_count, 3)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["integration: concealcursor option not forced on by render"] = function()
  -- Render must set conceallevel=2 but must NOT change concealcursor.
  -- Default concealcursor is "" (empty).
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })

  render.render_buffer(bufnr)

  -- conceallevel must be 2.
  eq(vim.api.nvim_win_get_option(winid, "conceallevel"), 2)
  -- concealcursor must remain at default ("" — cursor line reveals text).
  eq(vim.api.nvim_win_get_option(winid, "concealcursor"), "")

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── 3. CR on render task line → jump to source ────────────────────────────────

T["integration: CR on render task line jumps to source file at correct line"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  -- Use a real fixture file so vim.cmd('edit') succeeds.
  local fixture = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h") .. "/fixtures/vault/tasks_a.md"
  MiniTest.expect.equality(vim.fn.filereadable(fixture) == 1, true)

  local src_line = 5
  local t = parse.parse("- [ ] Buy milk")
  assert(t ~= nil)
  local stub = make_index_stub({ { task = t, path = fixture, line_num = src_line } })
  local restore_idx = install_mock("obsidian-tasks.index", stub)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)

  render.render_buffer(bufnr)

  -- The task line was inserted right after the closing fence (0-indexed line 3 → 1-indexed row 4).
  vim.api.nvim_win_set_cursor(winid, { 4, 0 })

  local cb = find_callback(bufnr, "<CR>")
  MiniTest.expect.equality(cb ~= nil, true)
  cb()

  -- Current buffer should now be the fixture file.
  local cur_name = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
  MiniTest.expect.equality(cur_name:find("tasks_a.md", 1, true) ~= nil, true)

  -- Cursor must be at src_line.
  local pos = vim.api.nvim_win_get_cursor(0)
  eq(pos[1], src_line)

  -- Cleanup.
  local fbuf = vim.fn.bufnr(fixture)
  if fbuf ~= -1 then
    vim.api.nvim_buf_delete(fbuf, { force = true })
  end
  if vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
  restore_idx()
  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── 4. CR on non-render line → smart_action fall-through ──────────────────────

T["integration: CR on non-render line invokes smart_action fall-through"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  local smart_action_called = false
  local restore_obsidian = install_mock("obsidian.actions", {
    smart_action = function()
      smart_action_called = true
      return nil
    end,
  })

  -- Buffer with a tasks block (empty result → 3 fence lines only, no task lines).
  local bufnr = make_buf({ "prefix line", "```tasks", "not done", "```", "suffix line" })
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    width = 80,
    height = 10,
    row = 0,
    col = 0,
  })
  vim.api.nvim_set_current_win(winid)

  render.render_buffer(bufnr)

  -- Position cursor on "prefix line" (row 1) — definitely not a render task line.
  vim.api.nvim_win_set_cursor(winid, { 1, 0 })

  local cb = find_callback(bufnr, "<CR>")
  MiniTest.expect.equality(cb ~= nil, true)
  cb()

  MiniTest.expect.equality(smart_action_called, true)

  restore_obsidian()
  restore_idx()
  draw_mod.clear(bufnr)
  vim.api.nvim_win_close(winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── 5. Two ```tasks blocks render independently ────────────────────────────────

T["integration: two tasks blocks render as independent real-line sets"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local t1 = parse.parse("- [ ] Alpha")
  local t2 = parse.parse("- [x] Beta")
  assert(t1 ~= nil)
  assert(t2 ~= nil)

  -- Stub returns two tasks with different done status.
  -- The first block (not done) matches t1; the second (done) matches t2.
  -- We use a stub that always returns both; filter in query will separate them.
  local stub = make_index_stub({
    { task = t1, path = "/vault/a.md", line_num = 1 },
    { task = t2, path = "/vault/b.md", line_num = 2 },
  })
  local restore_idx = install_mock("obsidian-tasks.index", stub)

  local bufnr = make_buf({
    "```tasks", -- 1
    "not done", -- 2
    "```", -- 3
    "", -- 4
    "```tasks", -- 5
    "done", -- 6
    "```", -- 7
  })
  render.render_buffer(bufnr)

  -- Both blocks should have been drawn (render has _buffer_state with 2 entries).
  MiniTest.expect.equality(render._buffer_state[bufnr] ~= nil, true)
  eq(#render._buffer_state[bufnr], 2)

  -- Buffer should contain lines from both rendered blocks.
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local has_alpha = false
  local has_beta = false
  for _, l in ipairs(lines) do
    if l:find("Alpha", 1, true) then
      has_alpha = true
    end
    if l:find("Beta", 1, true) then
      has_beta = true
    end
  end
  MiniTest.expect.equality(has_alpha, true)
  MiniTest.expect.equality(has_beta, true)

  -- draw state should have two separate block entries.
  local all_state = draw_mod.render_state(bufnr)
  MiniTest.expect.equality(all_state ~= nil, true)
  -- There should be at least two fence_first keys.
  local block_count = 0
  for _ in pairs(all_state) do
    block_count = block_count + 1
  end
  MiniTest.expect.equality(block_count >= 2, true)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["integration: two blocks have separate extmark namespaces (no cross-contamination)"] = function()
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local parse = require("obsidian-tasks.task.parse")

  local t1 = parse.parse("- [ ] First")
  local t2 = parse.parse("- [x] Second")
  assert(t1 ~= nil)
  assert(t2 ~= nil)
  local stub = make_index_stub({
    { task = t1, path = "/vault/a.md", line_num = 1 },
    { task = t2, path = "/vault/b.md", line_num = 2 },
  })
  local restore_idx = install_mock("obsidian-tasks.index", stub)

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "",
    "```tasks",
    "done",
    "```",
  })
  render.render_buffer(bufnr)

  -- is_render_line for the first inserted task line should resolve to block A's source.
  -- is_render_line for the second inserted task line should resolve to block B's source.
  -- After render_buffer with two blocks each yielding 1 task:
  --   Block A (fence 0-2): task at line 3.
  --   Block B (fence 5-7 after +1 shift): task at line 9.
  local meta_a = draw_mod.is_render_line(bufnr, 3)
  -- Block B fence was at 4-6 (0-indexed), shifted by +1 (block A inserted 1 task) → 5-7.
  -- Block B task inserted at line 8 (0-indexed).
  local meta_b = draw_mod.is_render_line(bufnr, 8)

  -- meta_a must exist (block A task).
  MiniTest.expect.equality(meta_a ~= nil, true)
  -- meta_b must exist (block B task).
  MiniTest.expect.equality(meta_b ~= nil, true)

  -- Each block's src_path must be different.
  if meta_a and meta_b then
    MiniTest.expect.equality(meta_a.src_path ~= meta_b.src_path, true)
  end

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── 6. Fixture vault: inbox/queries.md renders two blocks ─────────────────────

T["integration: inbox/queries.md fixture has two tasks blocks"] = function()
  -- This test verifies the fixture file itself is correctly structured.
  local render = fresh_render()
  local draw_mod = require("obsidian-tasks.render.draw")
  local restore_idx = install_mock("obsidian-tasks.index", make_index_stub({}))

  -- Load the fixture file into a buffer.
  local fixture_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h")
    .. "/fixtures/vault/inbox/queries.md"
  MiniTest.expect.equality(vim.fn.filereadable(fixture_path) == 1, true)

  local lines = vim.fn.readfile(fixture_path)
  local bufnr = make_buf(lines)

  -- Should find two tasks blocks.
  local blocks = render.find_blocks(bufnr)
  eq(#blocks, 2)

  render.render_buffer(bufnr)

  -- Both blocks rendered (empty results but state is created).
  MiniTest.expect.equality(render._buffer_state[bufnr] ~= nil, true)
  eq(#render._buffer_state[bufnr], 2)

  draw_mod.clear(bufnr)
  restore_idx()
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
