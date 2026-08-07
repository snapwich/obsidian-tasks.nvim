-- tests/integration_real/test_cursor_follow_real.lua
-- Cursor follow across a rerender, driven by REAL keypresses.
--
-- render/cursor.lua keeps the cursor on the SAME TASK — identified by
-- (src_path, src_line) — when a clear+render pass reorders the rendered rows,
-- and holds that task at its old screen row.  These cases cover the restore
-- sites end to end:
--
--   1. rerender_buffer after a priority edit typed on a rendered row, including
--      the winrestview viewport pin;
--   2. rerender_buffer through `<leader>tr` after an external source change
--      that reorders GROUPS;
--   3. revert.do_revert after an edit the flush rejects;
--   4. rerender_buffer through mark_dirty_for_deferred_sync's BufEnter hook —
--      the site whose outer row-pinned restore was deleted.
--
-- Why a child Neovim: an edit made with nvim_buf_set_lines runs with
-- vim.fn.mode() == "n", so the insert-mode gates in edit.flush and do_revert
-- never take the insert branch, and vim.schedule callbacks never interleave
-- with the typing.  child.type_keys drives nvim_input, which is what a terminal
-- sends.  vim.loop.sleep then lets the scheduled work drain.
--
-- Why no case asserts a row number alone: a row number is exactly what the old
-- restore preserved.  Each case asserts that the row CHANGED and that the
-- cursor sits on the task's NEW row, so a regression to a row-pinned restore
-- fails the test.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── Child Neovim + dashboard factory ─────────────────────────────────────────

--- Boot a child nvim, stub the index against one temp source file, and render a
--- dashboard for *query_lines*.
---
--- The index stub re-reads the source file on every tasks_in() call, so an
--- external rewrite of that file is picked up by the next render.  That is how
--- these cases produce a reorder without touching the dashboard buffer.
---
--- Globals set in the child: _G._dash (dashboard bufnr), _G._src (source path).
---
--- @param source_lines string[]  task lines written to the source file
--- @param query_lines  string[]  body of the ```tasks fence
--- @return table child
local function spawn_dashboard(source_lines, query_lines)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)

    -- Treesitter parsers may be absent; swallow the error so .md bufload works.
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end

    -- render/keymap.lua resolves <leader> when it installs the dashboard maps,
    -- i.e. on the first draw.  Pin it to <Space> BEFORE any render so the
    -- <leader>tr cases can type a key sequence instead of calling the handler.
    vim.g.mapleader = " "

    require("obsidian-tasks").setup({ global_filter = "#task" })
  ]],
    { cwd, deps_dir }
  )

  child.lua(
    [[
    local source_lines, query_lines = ...
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(source_lines, src)
    _G._src = src

    local index = require("obsidian-tasks.index")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    -- <leader>tr refreshes the index before it rerenders.  The stub reads the
    -- file on every call, so the refresh has nothing left to do.
    index.refresh_all_indexed_sync = function() end
    index.tasks_in = function()
      local all = {}
      local ok, lines = pcall(vim.fn.readfile, _G._src)
      if ok then
        for ln, line in ipairs(lines) do
          local t = task_parse.parse(line)
          if t then all[#all + 1] = { t, _G._src, ln } end
        end
      end
      local i = 0
      return function()
        i = i + 1
        if all[i] then return all[i][1], all[i][2], all[i][3] end
      end
    end

    -- Require the .init path: edit.lua and revert.lua require that form, and
    -- render/init.lua aliases both keys onto one module table.  Using .init
    -- here keeps _buffer_state coherent with what the restore reads.
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local buf_lines = { "```tasks" }
    vim.list_extend(buf_lines, query_lines)
    buf_lines[#buf_lines + 1] = "```"

    -- Listed buffer: case 4 puts it in a second window and switches back.
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buf_lines)
    -- The InsertLeave autocmd checks this buffer-local var.
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash = bufnr
  ]],
    { source_lines, query_lines }
  )

  return child
end

--- Source lines for *n* plain, unprioritised tasks.
--- @param n integer
--- @return string[]
local function plain_tasks(n)
  local lines = {}
  for i = 1, n do
    lines[i] = string.format("- [ ] Task %02d #task", i)
  end
  return lines
end

--- Rewrite 1-indexed source lines in place, as an external editor would.
---
--- The line COUNT never changes, so every task keeps its src_line — the second
--- half of the identity the follow matches on.
---
--- Patches are a LIST of { lnum, text } pairs rather than a keyed table: a
--- sparse table crosses the RPC boundary as an array padded with vim.NIL, which
--- writefile then rejects.
---
--- @param child   table
--- @param patches table[]  list of { lnum, replacement text }
local function rewrite_source(child, patches)
  child.lua(
    [[
    local patches = ...
    local lines = vim.fn.readfile(_G._src)
    for _, patch in ipairs(patches) do
      local lnum, text = patch[1], patch[2]
      lines[lnum] = text
    end
    vim.fn.writefile(lines, _G._src)
  ]],
    { patches }
  )
end

--- 0-indexed dashboard row of the first line containing *needle*, or -1.
--- @param child  table
--- @param needle string  plain substring
--- @return integer
local function find_row(child, needle)
  return child.lua_get(string.format(
    [[(function()
        local lines = vim.api.nvim_buf_get_lines(_G._dash, 0, -1, false)
        for i, l in ipairs(lines) do
          if l and l:find(%q, 1, true) then return i - 1 end
        end
        return -1
      end)()]],
    needle
  ))
end

--- Text of the dashboard line at 0-indexed *row0*.
local function dash_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

--- group_name the render recorded for 0-indexed dashboard row *row0*.
--- Group headings are virt_lines, not buffer lines, so the block state is the
--- only place the grouping is observable.
--- @return string
local function group_at(child, row0)
  return child.lua_get(string.format(
    [[(function()
        local state = require("obsidian-tasks.render.init")._buffer_state[_G._dash] or {}
        for _, block_state in ipairs(state) do
          local meta = (block_state.line_map or {})[%d]
          if meta then return meta.group_name or "" end
        end
        return ""
      end)()]],
    row0
  ))
end

--- 1-indexed cursor row of the child's current window.
local function cursor_row(child)
  return child.lua_get("vim.api.nvim_win_get_cursor(0)[1]")
end

--- 0-indexed cursor column of the child's current window.
local function cursor_col(child)
  return child.lua_get("vim.api.nvim_win_get_cursor(0)[2]")
end

--- Text of the line the cursor is on.
local function cursor_line(child)
  return child.lua_get("vim.api.nvim_get_current_line()")
end

--- Screen row of the cursor inside the child's window (1-indexed).
local function cursor_winline(child)
  return child.lua_get("vim.fn.winline()")
end

--- Source file lines, as the child sees them on disk.
local function read_source(child)
  return child.lua_get("vim.fn.readfile(_G._src)")
end

-- ── 1. Priority edit: the task reorders, the cursor and the view hold ────────
--
-- 30 tasks under `sort by priority`, all unprioritised, so the render keeps
-- source order.  The user raises Task 25 to the highest priority by typing the
-- emoji straight onto the rendered row.  Task 25 belongs at the top of the
-- list afterwards.
--
-- Two keystroke steps, because the flush does not move the row it just wrote:
-- edit.flush records a PENDING LINGER for any edit that would relocate the row,
-- which holds the task in place until the user asks for a refresh.  `<leader>tr`
-- is that request — it drops the lingers and rerenders, and the task jumps to
-- the top.  The cursor must ride with it, and the viewport pin must keep it on
-- the same SCREEN row so the page does not jump under the user.

T["priority edit reorders the task: the cursor follows it and holds its screen row"] = function()
  local child = spawn_dashboard(plain_tasks(30), { "not done", "sort by priority" })

  local row0 = find_row(child, "Task 25")
  eq(row0 >= 0, true, "Task 25 must be rendered")

  -- Park Task 25 at screen row 3 with real motions: put the row two above it at
  -- the top of the window (zt), then step down twice.  Screen row 3 leaves room
  -- above the cursor, so the pin stays satisfiable once the task lands near the
  -- top of the buffer — winrestview asks for topline = row - 2.
  child.api.nvim_win_set_cursor(0, { row0 - 1, 0 })
  child.type_keys("z", "t", "j", "j")
  eq(cursor_row(child), row0 + 1, "setup: the cursor must be back on Task 25's row")
  eq(cursor_winline(child), 3, "setup: Task 25 must sit at screen row 3")

  -- Type the priority emoji just before the tag, as a user would.
  local line = dash_line(child, row0)
  local hash_byte = line:find("#task", 1, true) - 1 -- 0-indexed
  child.api.nvim_win_set_cursor(0, { row0 + 1, hash_byte })
  child.type_keys("i", "🔺 ", "<Esc>")
  vim.loop.sleep(400)

  eq(read_source(child)[25], "- [ ] Task 25 🔺 #task", "the typed priority must reach the source file")

  child.type_keys("<Space>", "t", "r")
  vim.loop.sleep(400)

  local new_row0 = find_row(child, "Task 25")
  eq(new_row0 >= 0, true, "Task 25 must still be rendered after the reorder")
  eq(new_row0 ~= row0, true, "the refresh must have reordered — otherwise the case proves nothing")
  eq(cursor_row(child), new_row0 + 1, "the cursor must be on Task 25's NEW row, not its old row number")
  eq(cursor_line(child):find("Task 25", 1, true) ~= nil, true, "cursor line: [" .. cursor_line(child) .. "]")
  eq(cursor_winline(child), 3, "the viewport pin must keep Task 25 at screen row 3")

  child.stop()
end

-- ── 2. <leader>tr after an external source change that reorders groups ───────
--
-- `group by priority` puts every task in "Priority 4: None".  An external
-- editor gives Task 12 the highest priority, which opens a
-- "Priority 1: Highest" group ABOVE the existing one.  The manual refresh then
-- pushes every remaining task down by the height of the new group.

T["<leader>tr after a source change that reorders groups keeps the cursor on its task"] = function()
  local child = spawn_dashboard(plain_tasks(12), { "not done", "group by priority" })

  local row0 = find_row(child, "Task 06")
  eq(row0 >= 0, true, "Task 06 must be rendered")
  eq(group_at(child, row0), "Priority 4: None", "setup: Task 06 must start in the None group")
  child.api.nvim_win_set_cursor(0, { row0 + 1, 0 })

  rewrite_source(child, { { 12, "- [ ] Task 12 🔺 #task" } })

  child.type_keys("<Space>", "t", "r")
  vim.loop.sleep(400)

  local first_task_row0 = find_row(child, "Task 12")
  eq(group_at(child, first_task_row0), "Priority 1: Highest", "the refresh must open the Highest group")

  local new_row0 = find_row(child, "Task 06")
  eq(new_row0 >= 0, true, "Task 06 must survive the refresh")
  eq(new_row0 ~= row0, true, "the new group must have pushed Task 06 down")
  eq(group_at(child, new_row0), "Priority 4: None", "Task 06 must still be in the None group")
  eq(cursor_row(child), new_row0 + 1, "the cursor must be on Task 06's NEW row")
  eq(cursor_line(child):find("Task 06", 1, true) ~= nil, true, "cursor line: [" .. cursor_line(child) .. "]")

  child.stop()
end

-- ── 3. do_revert after an edit the flush rejects ─────────────────────────────
--
-- An external editor rewrites two source lines while the dashboard is open:
-- Task 10 gets a new description, and Task 12 gets the highest priority.  The
-- user then appends text to Task 10's rendered row.  The flush cannot locate
-- that task any more — the row's recorded source text no longer matches the
-- file — so the edit is rejected, nothing is written, and the canonical render
-- is rebuilt through revert.do_revert.  That rebuild also REORDERS, because it
-- reads the changed source: Task 12 moves to the front and Task 10 slides down.
--
-- The trailing text also parks the cursor past the end of the restored line.
-- The old inline restore in revert.lua did not clamp the column, so
-- nvim_win_set_cursor failed inside its pcall and the cursor stayed wherever
-- the rebuild had left it.

T["do_revert after a rejected edit lands the cursor on the task, not the row"] = function()
  local child = spawn_dashboard(plain_tasks(12), { "not done", "sort by priority" })

  local row0 = find_row(child, "Task 10")
  eq(row0 >= 0, true, "Task 10 must be rendered")

  rewrite_source(child, {
    { 10, "- [ ] Task 10 renamed #task" },
    { 12, "- [ ] Task 12 🔺 #task" },
  })

  child.api.nvim_win_set_cursor(0, { row0 + 1, 0 })
  child.type_keys("A", " zzzzzzzzzzzzzzzzzzzz", "<Esc>")
  vim.loop.sleep(500)

  local src = read_source(child)
  eq(src[10], "- [ ] Task 10 renamed #task", "a rejected edit must not reach the source file")

  local new_row0 = find_row(child, "Task 10 renamed")
  eq(new_row0 >= 0, true, "Task 10 must be rendered again after the revert")
  eq(new_row0 ~= row0, true, "the revert's rerender must have reordered")
  eq(cursor_row(child), new_row0 + 1, "the cursor must be on Task 10's NEW row")
  eq(cursor_line(child):find("Task 10 renamed", 1, true) ~= nil, true, "cursor line: [" .. cursor_line(child) .. "]")
  eq(cursor_col(child) <= #cursor_line(child), true, "the column must be clamped to the restored line")

  child.stop()
end

-- ── 4. Deferred sync through mark_dirty_for_deferred_sync ────────────────────
--
-- A source write while a dashboard is not the current buffer marks it dirty and
-- defers the rerender to its next BufEnter.  That hook used to wrap
-- rerender_buffer in its OWN row-pinned restore, which overrode the identity
-- follow.  The outer restore is gone; this case proves nothing regressed.
--
-- The dashboard stays in its own window while the source note opens in a split,
-- so the window keeps the user's cursor across the switch.  (`:buffer` cannot
-- be used here: Neovim fires BufEnter with the cursor still at row 1 and only
-- restores the remembered position afterwards, so no restore inside the hook
-- would be observable.)
--
-- If the row pin came back, the cursor would stay on the old row number, which
-- after the reorder holds Task 09.

T["deferred BufEnter sync follows the task instead of pinning the row"] = function()
  local child = spawn_dashboard(plain_tasks(12), { "not done", "sort by priority" })

  local row0 = find_row(child, "Task 10")
  eq(row0 >= 0, true, "Task 10 must be rendered")
  child.api.nvim_win_set_cursor(0, { row0 + 1, 0 })

  -- Open the source note in a split and leave the dashboard behind.
  child.lua("vim.cmd('split ' .. vim.fn.fnameescape(_G._src))")
  eq(child.lua_get("vim.api.nvim_win_get_buf(0) ~= _G._dash"), true, "the source note must be current")

  -- Off-screen source write, then the mark the propagation paths set.
  rewrite_source(child, { { 12, "- [ ] Task 12 🔺 #task" } })
  child.lua("require('obsidian-tasks.render.init').mark_dirty_for_deferred_sync(_G._dash)")
  eq(child.lua_get("vim.b[_G._dash].obsidian_tasks_sync_dirty"), true, "the dashboard must be marked dirty")

  child.type_keys("<C-w>", "p")
  vim.loop.sleep(400)

  eq(child.lua_get("vim.b[_G._dash].obsidian_tasks_sync_dirty == nil"), true, "the dirty flag must be cleared")

  local new_row0 = find_row(child, "Task 10")
  eq(new_row0 >= 0, true, "Task 10 must be rendered after the deferred sync")
  eq(new_row0 ~= row0, true, "the deferred sync must have reordered")
  eq(cursor_row(child), new_row0 + 1, "the cursor must be on Task 10's NEW row")
  eq(cursor_line(child):find("Task 10", 1, true) ~= nil, true, "cursor line: [" .. cursor_line(child) .. "]")

  child.stop()
end

return T
