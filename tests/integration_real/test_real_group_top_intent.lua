-- tests/integration_real/test_real_group_top_intent.lua
-- Real-input coverage for insert intent from cursor provenance (plan D2,
-- ADR 0004): a line inserted ABOVE the first task of a group (the group-top
-- slot) moves the group header up to the new line, and the insert is flagged
-- group-top for process_inserts.  Until the daily-note write lands (plan step
-- 4), a group-top insert takes the no-anchor fallback: the typed line is kept
-- below the dashboard as note content, the source note is not written, and a
-- warning is shown.
--
-- Gestures (cursor on the top task of the "technical debt" group): `O`, `"xP`,
-- `:put!`, `<C-o>O` from insert mode, `3O`, and a remapped `P` (a Lua function
-- that calls `:put!`, like yanky / substitute).
--
-- Regression (header stays on its task, current behavior): `o` / `p` on the
-- last task of the group above, `O` on a non-top task, `O` + <Esc> with an
-- empty line (writes nothing; the header returns), and one `show tree` fold.
--
-- See CLAUDE.md: these tests drive a child Neovim with type_keys + sleep; they
-- never edit the dashboard with nvim_buf_set_lines.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local SOURCE = {
  "## refactoring",
  "- [ ] Refactor A #task",
  "- [ ] Refactor A2 #task",
  "## technical debt",
  "- [ ] Debt B #task",
  "- [ ] Debt C #task",
}

local GROUP_QUERY = { "not done", "group by heading" }

--- Spawn a child with a NAMED dashboard note (so the no-anchor fallback keeps
--- the typed line as note content) over one source note.  The index is stubbed
--- to read the live source file and record each task's nearest heading.
local function spawn(source_lines, query_lines)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })
  ]],
    { cwd, deps_dir }
  )

  child.lua(
    [[(function(source_lines, query_lines)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(source_lines, src)
    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")
    local heading = require("obsidian-tasks.index.heading")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.nodes_for = function(p)
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or {})
      end
      return {}
    end
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      local all, cur = {}, nil
      if ok then
        for ln, line in ipairs(lines) do
          local h = heading.parse(line)
          if h then
            cur = h
          else
            local t = task_parse.parse(line)
            if t then
              t.heading = cur
              all[#all + 1] = { task = t, path = src, ln = ln }
            end
          end
        end
      end
      local i = 0
      return function()
        i = i + 1
        if all[i] then return all[i].task, all[i].path, all[i].ln end
      end
    end

    _G._warns = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, o)
      if level == vim.log.levels.WARN then _G._warns[#_G._warns + 1] = msg end
      return orig_notify(msg, level, o)
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "-dashboard.md")
    local fence = { "# Dashboard", "", "```tasks" }
    for _, q in ipairs(query_lines) do fence[#fence + 1] = q end
    fence[#fence + 1] = "```"
    fence[#fence + 1] = ""
    fence[#fence + 1] = "Trailing prose."
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fence)
    vim.b[bufnr].obsidian_tasks_dashboard = true
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].autoindent = false
    render.render_buffer(bufnr, nil)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src = src

    -- Row of the draw-NS extmark whose virt_lines carry *label*; -1 when none.
    _G._header_row = function(label)
      local ns = require("obsidian-tasks.util.extmark").NS
      local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
      for _, m in ipairs(marks) do
        for _, chunks in ipairs(m[4].virt_lines or {}) do
          for _, c in ipairs(chunks) do
            if c[1]:find(label, 1, true) then return m[2] end
          end
        end
      end
      return -1
    end

    -- Record, at every normal-mode flush, the line the "technical debt" header
    -- sits above.  The flush runs before the canonical rerender, so this sees
    -- the header where the on_lines intent hook left it.
    _G._flushes = {}
    local edit = require("obsidian-tasks.render.edit")
    local orig_flush = edit.flush
    edit.flush = function(b)
      if not require("obsidian-tasks.render.hygiene").in_insert_mode() then
        local r = _G._header_row("technical debt")
        _G._flushes[#_G._flushes + 1] = {
          row = r,
          line = vim.api.nvim_buf_get_lines(b, r, r + 1, false)[1],
        }
      end
      return orig_flush(b)
    end
  end)(...)]],
    { source_lines, query_lines }
  )
  return child
end

local function find_row(child, needle)
  return child.lua_get(
    [[(function(needle)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
        if l:find(needle, 1, true) then return i - 1 end
      end
      return -1
    end)(...)]],
    { needle }
  )
end

local function src_lines(child)
  return child.lua_get("vim.fn.readfile(_G._src)")
end

local function dash_lines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
end

local function header_row(child, label)
  return child.lua_get("_G._header_row(...)", { label or "technical debt" })
end

--- True when some flush saw the "technical debt" header directly above *text*.
local function header_was_above(child, text)
  for _, f in ipairs(child.lua_get("_G._flushes")) do
    if f.line == text then
      return true
    end
  end
  return false
end

--- Rows of the dashboard buffer that are NOT managed (note content).
local function note_rows(child)
  return child.lua_get([[(function()
    local save = require("obsidian-tasks.render.save")
    local b = _G._dash_bufnr
    local skip = {}
    for _, r in ipairs(save.compute_managed_ranges(b)) do
      for row = r[1], r[2] do skip[row] = true end
    end
    local out = {}
    for i, l in ipairs(vim.api.nvim_buf_get_lines(b, 0, -1, false)) do
      if not skip[i - 1] then out[#out + 1] = l end
    end
    return out
  end)()]])
end

local function count(list, text)
  local n = 0
  for _, l in ipairs(list) do
    if l == text then
      n = n + 1
    end
  end
  return n
end

local function warned(child, needle)
  for _, w in ipairs(child.lua_get("_G._warns")) do
    if w:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- The group-top fallback outcome for *text* (step 3, before the daily-note
--- write): source untouched, the line kept *n* times as note content below the
--- dashboard, and the no-anchor warning shown.
local function expect_group_top_fallback(child, text, n)
  eq(src_lines(child), SOURCE, "a group-top insert must not write the source note")
  eq(count(note_rows(child), text), n or 1, "typed line kept as note content: " .. vim.inspect(dash_lines(child)))
  eq(warned(child, "no task to anchor to"), true, "no-anchor warning: " .. vim.inspect(child.lua_get("_G._warns")))
end

local function on_task(child, needle)
  local row = find_row(child, needle)
  eq(row >= 0, true, needle .. " must be rendered")
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  -- Let CursorMoved fire for the new position before the gesture.
  vim.loop.sleep(50)
  child.type_keys("<Ignore>")
  vim.loop.sleep(50)
  return row
end

-- ── Gestures on the top task of a group: header moves, insert is group-top ────

T["O on the top task of a group moves the header up and flags group-top"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  local b_row = on_task(child, "Debt B")
  eq(header_row(child), b_row, "header starts above Debt B")

  child.type_keys("O", "- [ ] New top")
  vim.loop.sleep(150)
  -- Still in insert mode: the header is above the NEW line, not above Debt B.
  eq(child.fn.mode(), "i")
  eq(header_row(child), b_row, "header moved up to the inserted row")
  eq(dash_lines(child)[b_row + 1], "- [ ] New top")

  child.type_keys("<Esc>")
  vim.loop.sleep(400)
  eq(header_was_above(child, "- [ ] New top"), true, "flush saw the header above the new line")
  expect_group_top_fallback(child, "- [ ] New top")
  child.stop()
end

T['"xP (linewise register) on the top task is a group-top insert'] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  on_task(child, "Debt B")
  child.fn.setreg("x", { "- [ ] Pasted top" }, "l")
  child.type_keys('"xP')
  vim.loop.sleep(400)
  eq(header_was_above(child, "- [ ] Pasted top"), true, vim.inspect(child.lua_get("_G._flushes")))
  expect_group_top_fallback(child, "- [ ] Pasted top")
  child.stop()
end

T[":put! on the top task is a group-top insert"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  on_task(child, "Debt B")
  child.fn.setreg("x", { "- [ ] Put top" }, "l")
  child.type_keys(":put! x<CR>")
  vim.loop.sleep(400)
  eq(header_was_above(child, "- [ ] Put top"), true, vim.inspect(child.lua_get("_G._flushes")))
  expect_group_top_fallback(child, "- [ ] Put top")
  child.stop()
end

T["<C-o>O from insert mode on the top task is a group-top insert"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  local b_row = on_task(child, "Debt B")
  child.type_keys("A")
  vim.loop.sleep(50)
  child.type_keys("<C-o>O")
  vim.loop.sleep(50)
  child.type_keys("- [ ] Ctrl-o top")
  vim.loop.sleep(150)
  eq(header_row(child), b_row, "header moved up to the inserted row")
  child.type_keys("<Esc>")
  vim.loop.sleep(400)
  eq(header_was_above(child, "- [ ] Ctrl-o top"), true, vim.inspect(child.lua_get("_G._flushes")))
  expect_group_top_fallback(child, "- [ ] Ctrl-o top")
  child.stop()
end

T["3O on the top task: every repeated line is group-top"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  local b_row = on_task(child, "Debt B")
  child.type_keys("3O", "- [ ] Triple")
  vim.loop.sleep(100)
  child.type_keys("<Esc>")
  vim.loop.sleep(400)
  local f = child.lua_get("_G._flushes")[1]
  eq(f ~= nil and f.row == b_row and f.line == "- [ ] Triple", true)
  expect_group_top_fallback(child, "- [ ] Triple", 3)
  child.stop()
end

T["remapped P (Lua function calling :put!) on the top task is a group-top insert"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  child.lua([[vim.keymap.set("n", "P", function() vim.cmd("put!") end)]])
  on_task(child, "Debt B")
  child.fn.setreg('"', { "- [ ] Remap top" }, "l")
  child.type_keys("P")
  vim.loop.sleep(400)
  eq(header_was_above(child, "- [ ] Remap top"), true, vim.inspect(child.lua_get("_G._flushes")))
  expect_group_top_fallback(child, "- [ ] Remap top")
  child.stop()
end

T["O on the top task of the first group moves that header too"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  local a_row = on_task(child, "Refactor A")
  eq(header_row(child, "refactoring"), a_row)
  child.type_keys("O", "- [ ] First top")
  vim.loop.sleep(150)
  eq(header_row(child, "refactoring"), a_row)
  eq(dash_lines(child)[a_row + 1], "- [ ] First top")
  child.type_keys("<Esc>")
  vim.loop.sleep(400)
  expect_group_top_fallback(child, "- [ ] First top")
  child.stop()
end

-- A moved header is left-gravity: <CR> at the end of the typed group-top line
-- must not carry the header down to the second line.
T["O + text + <CR> + text: both lines are group-top, header above the first"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  local b_row = on_task(child, "Debt B")
  child.type_keys("O", "- [ ] Line one", "<CR>", "- [ ] Line two")
  vim.loop.sleep(150)
  eq(header_row(child), b_row)
  child.type_keys("<Esc>")
  vim.loop.sleep(400)
  eq(header_was_above(child, "- [ ] Line one"), true)
  expect_group_top_fallback(child, "- [ ] Line one")
  eq(count(note_rows(child), "- [ ] Line two"), 1)
  child.stop()
end

-- ── Regression: the header stays on its task (current behavior) ───────────────

T["o on the last task of the group above keeps today's anchor behavior"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  on_task(child, "Refactor A2")
  child.type_keys("o", "- [ ] Below A2 #task", "<Esc>")
  vim.loop.sleep(400)
  local f = child.lua_get("_G._flushes")[1]
  eq(f ~= nil and f.line:find("Debt B", 1, true) ~= nil, true, "header stayed on Debt B: " .. vim.inspect(f))
  local s = src_lines(child)
  eq(s[4], "- [ ] Below A2 #task", "written after the anchor: " .. vim.inspect(s))
  eq(s[5], "## technical debt")
  child.stop()
end

T["p on the last task of the group above keeps today's anchor behavior"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  on_task(child, "Refactor A2")
  child.fn.setreg("x", { "- [ ] Pasted below A2 #task" }, "l")
  child.type_keys('"xp')
  vim.loop.sleep(400)
  local f = child.lua_get("_G._flushes")[1]
  eq(f ~= nil and f.line:find("Debt B", 1, true) ~= nil, true, "header stayed on Debt B: " .. vim.inspect(f))
  local s = src_lines(child)
  eq(s[4], "- [ ] Pasted below A2 #task", "written after the anchor: " .. vim.inspect(s))
  child.stop()
end

T["O on a non-top task keeps today's anchor behavior"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  on_task(child, "Debt C")
  child.type_keys("O", "- [ ] Above C #task", "<Esc>")
  vim.loop.sleep(400)
  local f = child.lua_get("_G._flushes")[1]
  eq(f ~= nil and f.line:find("Debt B", 1, true) ~= nil, true, "header stayed on Debt B: " .. vim.inspect(f))
  local s = src_lines(child)
  eq(s[6], "- [ ] Above C #task", "written after Debt B: " .. vim.inspect(s))
  eq(s[7], "- [ ] Debt C #task")
  child.stop()
end

T["O + <Esc> on the top task writes nothing and the header returns"] = function()
  local child = spawn(SOURCE, GROUP_QUERY)
  local before = dash_lines(child)
  local b_row = on_task(child, "Debt B")
  child.type_keys("O")
  vim.loop.sleep(100)
  eq(header_row(child), b_row, "header moved up to the empty inserted row")
  child.type_keys("<Esc>")
  vim.loop.sleep(400)
  eq(src_lines(child), SOURCE, "nothing written to source")
  eq(dash_lines(child), before, "the empty line is gone after the rerender")
  local row = find_row(child, "Debt B")
  eq(header_row(child), row, "header back above Debt B")
  eq(#child.lua_get("_G._warns"), 0, "no warning: " .. vim.inspect(child.lua_get("_G._warns")))
  child.stop()
end

-- ── show tree: the header move does not touch the subtree folds ─────────────
--
-- Subtree folds are manual and start at the first CHILD row; the root row is
-- outside the fold and no fold uses the header extmark (plan D2).  While the
-- group-top line is in the buffer, the closed fold must cover exactly the same
-- child rows (shifted down by one) and the root must stay unfolded.

T["show tree: O on a group-top root moves the header and keeps its closed subtree fold"] = function()
  local source = {
    "## refactoring",
    "- [ ] Refactor A #task",
    "## technical debt",
    "- [ ] Debt B #task",
    "  - detail one",
    "  - detail two",
    "- [ ] Debt C #task",
  }
  local child = spawn(source, { "not done", "show tree", "group by heading" })
  local d1 = find_row(child, "detail one")
  eq(d1 >= 0, true)
  child.api.nvim_win_set_cursor(0, { d1 + 1, 0 })
  child.type_keys("zc")
  vim.loop.sleep(50)
  local fold_start, fold_end = child.fn.foldclosed(d1 + 1), child.fn.foldclosedend(d1 + 1)
  eq(fold_start ~= -1, true)

  local b_row = on_task(child, "Debt B")
  child.type_keys("O", "- [ ] Tree top")
  vim.loop.sleep(150)
  eq(child.fn.mode(), "i")
  eq(header_row(child), b_row)
  eq(dash_lines(child)[b_row + 1], "- [ ] Tree top")
  -- Same fold, one row lower; the root (now at b_row + 1) is not folded.
  eq(child.fn.foldclosed(d1 + 2), fold_start + 1)
  eq(child.fn.foldclosedend(d1 + 2), fold_end + 1)
  eq(child.fn.foldclosed(b_row + 2), -1)
  eq(child.fn.foldclosed(b_row + 1), -1)

  child.type_keys("<Esc>")
  vim.loop.sleep(500)
  eq(header_was_above(child, "- [ ] Tree top"), true)
  eq(src_lines(child), source)
  eq(child.fn.foldclosed(find_row(child, "Debt B") + 1), -1)
  child.stop()
end

return T
