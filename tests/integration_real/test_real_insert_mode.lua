-- tests/integration_real/test_real_insert_mode.lua
-- Real-mode insert tests using MiniTest.new_child_neovim.
--
-- Why: Tests that simulate edits with vim.api.nvim_buf_set_lines() do NOT
-- exercise the real-mode path.  vim.fn.mode() returns 'n' during set_lines,
-- so on_lines_hook never takes the insert-mode branch.  vim.schedule()
-- callbacks also don't interleave with synthetic edits — they fire after the
-- test function returns, by which point the test has already asserted.
--
-- This file drives a child Neovim via nvim_input (terminal-equivalent), so
-- mode() is genuinely 'i', vim.schedule fires between keystrokes, and the
-- InsertLeave autocmd is the one in autocmds.lua (not a manual flush() call).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── Child Neovim factory ─────────────────────────────────────────────────────

--- Boot a child nvim, load our deps + obsidian-tasks setup, and create a
--- one-task dashboard.  Returns the child and the source-file path.
local function spawn_child_with_dashboard(task_text)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    -- Set up rtp for obsidian, blink, mini, obsidian-tasks.
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/obsidian.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/blink.cmp")
    vim.opt.rtp:prepend(cwd)

    -- Treesitter parsers may not be installed; swallow errors so .md bufload works.
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end

    local fixture_vault = cwd .. "/tests/fixtures/vault"
    require("obsidian").setup({
      workspaces = { { name = "test-vault", path = fixture_vault } },
      log_level = vim.log.levels.ERROR,
      completion = { nvim_cmp = false, blink = false },
      picker = { name = nil },
      ui = { enable = false },
    })
    require("obsidian-tasks").setup({ global_filter = "#task" })
    require("blink.cmp").setup({
      fuzzy = { implementation = "lua" },
      sources = {
        default = { "obsidian-tasks" },
        providers = {
          ["obsidian-tasks"] = { module = "obsidian-tasks.cmp.source", name = "ObsidianTasks" },
        },
      },
    })
  ]],
    { cwd, deps_dir }
  )

  -- Make a tmp source file and stub the index to return just this one task.
  local src_path = child.lua_get(
    [[(function(task_text)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ task_text }, src)

    local index = require("obsidian-tasks.index")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then
          local ok, lines = pcall(vim.fn.readfile, src)
          local t = ok and task_parse.parse(lines[1]) or task_parse.parse(task_text)
          return t, src, 1
        end
      end
    end

    -- Use .init path: edit.lua and other modules require the .init form, and
    -- Lua's require cache treats "obsidian-tasks.render" and
    -- "obsidian-tasks.render.init" as separate keys → separate module
    -- instances → separate _buffer_state.  Using .init keeps state coherent.
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
    -- The InsertLeave autocmd checks this buffer-local var.
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { task_text }
  )

  return child, src_path
end

--- Read a buffer line via the child.
local function child_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

--- Read a source-file line via the child.
local function child_src_line(child, row0)
  return child.lua_get("(vim.fn.readfile(_G._src_path))[" .. (row0 + 1) .. "]")
end

local TASK_ROW = 3 -- fence, query, fence, task

-- ── ciw + replacement + <Esc> ────────────────────────────────────────────────
-- The bug we're catching: vim.schedule fires between keystrokes during ciw,
-- triggers do_revert mid-typing, and wipes the partial replacement.
--
-- Why ciw, not cw: vim's cw also deletes the trailing space ("Walk " → ""),
-- producing "HELLOdog".  ciw is "change inside word" — it deletes only the
-- word, preserving surrounding whitespace.

T["ciw on description: typed text persists and propagates to source"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  local canonical_before = child_line(child, TASK_ROW)
  -- Position cursor on the 'W' of "Walk" — after "- [ ] " (6 chars).
  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 6 })

  -- ciw + HELLO + Esc.  type_keys uses nvim_input under the hood, which
  -- behaves like real terminal input (vim.schedule fires between keystrokes).
  child.type_keys("c", "i", "w", "H", "E", "L", "L", "O", "<Esc>")

  -- Wait for the InsertLeave autocmd + drained schedules to complete.
  vim.loop.sleep(200)

  local line_after = child_line(child, TASK_ROW)
  eq(line_after:find("HELLO") ~= nil, true, "ciw replacement must persist after typing: line=[" .. line_after .. "]")
  eq(line_after ~= canonical_before, true, "line must differ from canonical after ciw")

  local src_line = child_src_line(child, 0)
  eq(src_line, "- [ ] HELLO dog #task", "source file must reflect the ciw edit")

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── i…<Esc>: prepend chars before description ────────────────────────────────

T["i on description: inserted text persists and propagates"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 6 }) -- on 'W'
  child.type_keys("i", "Quickly ", "<Esc>")
  vim.loop.sleep(150)

  local line_after = child_line(child, TASK_ROW)
  eq(line_after:find("Quickly Walk") ~= nil, true, "i must prepend before description")

  local src_line = child_src_line(child, 0)
  eq(src_line, "- [ ] Quickly Walk dog #task", "source must reflect 'i' insert")

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── a…<Esc>: append chars after cursor position ──────────────────────────────

T["a after description: appended text persists and propagates"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  -- Position cursor on the 'g' of "dog" (col 13 = "- [ ] Walk do").
  -- After 'a' we're inserting after 'g' which is end of "dog".
  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 13 })
  child.type_keys("a", " slowly", "<Esc>")
  vim.loop.sleep(150)

  local line_after = child_line(child, TASK_ROW)
  eq(line_after:find("dog slowly") ~= nil, true, "a must append after cursor: line=[" .. line_after .. "]")

  local src_line = child_src_line(child, 0)
  eq(src_line, "- [ ] Walk dog slowly #task", "source must reflect 'a' append")

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── r X: single-char replace (normal mode, no insert-mode involvement) ───────
-- This already worked before the fix (status edits go through the recognize_
-- status_edit fast path), but we cover it here so the file is the canonical
-- "real keypress" suite for edit-in-place.

T["r [x]: replace status symbol commits to source"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  -- Status char position: index 3 (the space inside "[ ]").
  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 3 })
  child.type_keys("r", "x")
  vim.loop.sleep(150)

  local src_line = child_src_line(child, 0)
  eq(src_line, "- [x] Walk dog #task", "r x must commit status flip to source")

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── blink.cmp completion accept inside insert mode ──────────────────────────
-- Replacement for tests/integration/test_edit_flush.lua's fake "blink.cmp
-- completion" test which used set_line() (mode='n') and never exercised
-- the real insert→completion→commit flow.
--
-- This test simulates the manual analogue: enter insert mode, type a date
-- field marker + value, leave insert mode.  Whether or not blink actually
-- offers a popup, the resulting buffer text is what a real completion accept
-- would produce — and the bug we want to catch is the flush/revert race that
-- only fires when the user is in real insert mode.

T["insert mode: typing a complete date field commits on <Esc>"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Complete me #task")

  -- Position cursor BEFORE "#task" (just before the '#').
  -- Line: "- [ ] Complete me #task [[0]]"
  --        0123456789012345678
  -- "#task" starts at byte 18.
  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 18 })

  -- Type the date field as if blink.cmp completion expanded "📅 2024-12-31 ".
  -- Multi-byte characters (📅) are sent verbatim by nvim_input.
  child.type_keys("i", "📅 2024-12-31 ", "<Esc>")
  vim.loop.sleep(200)

  local src_line = child_src_line(child, 0)
  eq(
    src_line,
    "- [ ] Complete me 📅 2024-12-31 #task",
    "blink-style completion typed in insert mode must commit to source"
  )

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── o below managed row: opens a new line, types new task, <Esc> ─────────────
-- Exercises the INSERT classifier path.

T["o below task: new task line lands in source after anchor"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 0 })
  child.type_keys("o", "- [ ] New task #task", "<Esc>")
  vim.loop.sleep(200)

  local src_after = child.lua_get("vim.fn.readfile(_G._src_path)")
  -- Source should now have 2 lines: original Walk dog + the new task.
  eq(#src_after >= 2, true, "source must have at least 2 lines after 'o' insert")
  local found_new = false
  for _, l in ipairs(src_after) do
    if l:find("New task") then
      found_new = true
    end
  end
  eq(found_new, true, "'New task' must appear in source after INSERT flow")

  child.stop()
  pcall(vim.fn.delete, src_path)
end

return T
