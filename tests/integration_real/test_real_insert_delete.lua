-- tests/integration_real/test_real_insert_delete.lua
-- Real-mode coverage for ot-q2da (P8 INSERT + DELETE).
--
-- Covers steps 4, 5 of ot-q2da.md:
--   4. dd on task with no continuation → only the task line removed
--   5. Insert at top of dashboard (no managed anchor above) → revert + notify
--
-- Step 1 (yank+paste) overlaps with `o` (already covered).  Step 2 (unmanaged
-- row between managed) is similar.  Step 3 (block delete with continuation)
-- is covered in test_e2e_edit_in_place.lua.  Steps 6-8 (undo, chmod -w,
-- combined paste+delete) deferred — undo + multi-op overlap with E2E.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local function spawn_with_tasks(task_lines)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/blink.cmp")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })
    require("blink.cmp").setup({
      fuzzy = { implementation = "lua" },
      sources = {
        default = { "obsidian-tasks" },
        providers = { ["obsidian-tasks"] = { module = "obsidian-tasks.cmp.source", name = "ObsidianTasks" } },
      },
    })
  ]],
    { cwd, deps_dir }
  )

  child.lua_get(
    [[(function(task_lines)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(task_lines, src)
    local index = require("obsidian-tasks.index")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      local all = {}
      if ok then
        for ln, line in ipairs(lines) do
          local t = task_parse.parse(line)
          if t then all[#all + 1] = { task = t, path = src, ln = ln } end
        end
      end
      local i = 0
      return function()
        i = i + 1
        if all[i] then return all[i].task, all[i].path, all[i].ln end
      end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src = src
    _G._warns = {}
    local log = require("obsidian-tasks.log")
    log.warn = function(msg) table.insert(_G._warns, tostring(msg)) end
    return src
  end)(...)]],
    { task_lines }
  )
  local src = child.lua_get("_G._src")
  return child, src
end

-- ── dd on task with no continuation: only the task line is removed ──────────

T["dd on task without continuation: source loses exactly one line"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] Solo task #task",
    "- [ ] Other task #task",
  })

  local solo_row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find("Solo task", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  eq(solo_row >= 0, true, "Solo task row must exist")
  child.api.nvim_win_set_cursor(0, { solo_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(300)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  eq(#src_after, 1, "Source must have exactly 1 line left (Other task)")
  eq(src_after[1], "- [ ] Other task #task", "Remaining line must be Other task")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── Paste/type new task with NO managed anchor above → revert + notify ───────

T["o at top of dashboard (no anchor): inserted row is reverted, source untouched"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] Only task #task",
  })

  -- Walk above the only managed row: dashboard is fence/query/fence then task.
  -- The fence row (0) is above the managed row.  `o` on row 1 (the "not done"
  -- query line) inserts at row 2.  Walking back from row 2: row 1 is the
  -- query (not managed), row 0 is the fence (not managed).  No anchor → revert.
  --
  -- We need the INSERT to fall INSIDE the managed region but with no anchor
  -- above.  The region snapshot is { 3, 3 } (one managed row).  An insert
  -- AT row 3 (replacing/preceding the task) might work, but `o` on row 2
  -- creates row 3 which displaces the task.  Try `O` (open ABOVE) on the
  -- task row instead — opens an empty line at row 3, pushing the task to row 4.
  local task_row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find("Only task", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  eq(task_row >= 0, true, "Only task row must exist")
  child.api.nvim_win_set_cursor(0, { task_row + 1, 0 })

  local src_before = child.lua_get("vim.fn.readfile(_G._src)")
  -- `O` opens an empty line ABOVE current. Cursor moves to that new (empty) line.
  child.type_keys("O", "- [ ] Brand new task", "<Esc>")
  vim.loop.sleep(400)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  eq(
    vim.deep_equal(src_before, src_after),
    true,
    "no-anchor INSERT must NOT propagate to source: src_after=" .. vim.inspect(src_after)
  )
  local warns = child.lua_get("_G._warns")
  local saw_no_anchor = false
  for _, w in ipairs(warns) do
    if w:find("no anchor") then
      saw_no_anchor = true
    end
  end
  eq(saw_no_anchor, true, "no-anchor INSERT must emit a notify warning")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── Bare-text INSERT (o + word + Esc) auto-prefixes with - [ ] ───────────────
--
-- Real keystroke path: `o test<Esc>` creates a new line containing "test"
-- below the current task.  flush() must auto-prefix the bare word with
-- "- [ ] " so the line becomes a task in source (not orphan content).

T["o + bare word: source gets - [ ] word as new task"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] Anchor #task",
  })

  local task_row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find("Anchor", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  eq(task_row >= 0, true, "Anchor row must exist")
  child.api.nvim_win_set_cursor(0, { task_row + 1, 0 })

  child.type_keys("o", "test", "<Esc>")
  vim.loop.sleep(400)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  eq(#src_after, 2, "source must have 2 lines after bare-text INSERT")
  eq(src_after[1], "- [ ] Anchor #task", "anchor unchanged")
  eq(src_after[2], "- [ ] test", "bare-text 'test' auto-prefixed with - [ ]")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── Mid-task <CR> split: original task and second half each become a task ────
--
-- The growing-replacement case: pressing <CR> mid-task replaces 1 line with 2.
-- on_lines must update the region/meta snapshots so flush() classifies row N
-- as MUTATE (truncated text) and row N+1 as INSERT (second half), and the
-- second half gets auto-prefixed with - [ ].

T["mid-task <CR> split: source contains both halves as separate tasks"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] need to merge dependabot #task",
  })

  local task_row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find("need to merge", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  eq(task_row >= 0, true, "task row must exist")

  -- Cursor: row task_row+1 (1-indexed), column 14 (immediately before 'merge').
  -- Line "- [ ] need to merge dependabot #task" — col 14 (0-indexed) is 'm' of 'merge'.
  child.api.nvim_win_set_cursor(0, { task_row + 1, 14 })
  -- Real insert-mode <CR>: enter insert mode, hit Enter, leave.
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(400)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  eq(#src_after, 2, "source must contain two tasks after mid-task split")
  eq(src_after[1], "- [ ] need to ", "first half kept as truncated task")
  eq(src_after[2], "- [ ] merge dependabot #task", "second half becomes its own task")

  child.stop()
  pcall(vim.fn.delete, src)
end

return T
