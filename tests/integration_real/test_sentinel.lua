-- tests/integration_real/test_sentinel.lua
-- Real-mode tests for the EOF dashboard sentinel using MiniTest.new_child_neovim.
--
-- Why real keypresses: typing into / deleting the sentinel exercises the
-- on_lines → demote / revert path, which only behaves correctly when vim.fn.mode()
-- genuinely reports insert/normal and vim.schedule callbacks fire between
-- keystrokes.  Synthetic nvim_buf_set_lines edits run in mode 'n' and never take
-- the insert-mode branch (see CLAUDE.md), so they cannot test this.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── Child Neovim factory ─────────────────────────────────────────────────────

--- Boot a child nvim, load deps + obsidian-tasks, and create a one-task
--- dashboard that ends at EOF (so draw appends a sentinel below the task).
--- Returns the child and the source-file path.
local function spawn_child_with_dashboard(task_text)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/obsidian.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/blink.cmp")
    vim.opt.rtp:prepend(cwd)

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
  ]],
    { cwd, deps_dir }
  )

  local src_path = child.lua_get(
    [[(function(task_text)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ task_text }, src)

    local index = require("obsidian-tasks.index")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    -- Return every parseable task line currently in the source file (re-read on
    -- each call) so a re-render after an `o`-inserted task shows both tasks.
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      lines = (ok and type(lines) == "table") and lines or {}
      local i = 0
      return function()
        while i < #lines do
          i = i + 1
          local t = task_parse.parse(lines[i])
          if t then
            return t, src, i
          end
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    -- Whole-buffer fence → the rendered task lands on the last buffer line, so
    -- draw appends a sentinel at the row below it.
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "not done", "```" })
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

--- Read a dashboard buffer line via the child (0-indexed row).
local function child_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

--- Total dashboard buffer line count via the child.
local function child_line_count(child)
  return child.lua_get("vim.api.nvim_buf_line_count(_G._dash_bufnr)")
end

--- Capture the child's screen as an array of trailing-trimmed row strings.
--- Uses mini.test's get_screenshot (which redraws first), so virtual lines and
--- folds are reflected exactly as a user would see them.
local function screen_rows(child)
  local ss = child.get_screenshot()
  local rows = {}
  for i = 1, #ss.text do
    rows[i] = (table.concat(ss.text[i], ""):gsub("%s+$", ""))
  end
  return rows
end

--- 1-indexed screen row containing *needle* (plain substring), or nil.
local function screen_find(rows, needle)
  for i, r in ipairs(rows) do
    if r:find(needle, 1, true) then
      return i
    end
  end
  return nil
end

local TASK_ROW = 3 -- fence(0-2), task(3)
local SENTINEL_ROW = 4 -- sentinel appended below the task

-- ── sentinel is appended at EOF ───────────────────────────────────────────────

T["render: a one-task EOF dashboard ends with an empty sentinel line"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  eq(child_line_count(child), 5) -- fence(3) + task(1) + sentinel(1)
  eq(child_line(child, SENTINEL_ROW), "")

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── dd on the sentinel reverts (sentinel restored) ───────────────────────────

T["dd on sentinel: revert restores the sentinel"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { SENTINEL_ROW + 1, 0 })
  child.type_keys("dd")
  vim.loop.sleep(200)

  -- Sentinel restored: still 5 lines, last line empty, task intact.
  eq(child_line_count(child), 5)
  eq(child_line(child, SENTINEL_ROW), "")
  eq(child_line(child, TASK_ROW):find("Walk dog") ~= nil, true)

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── typing into the sentinel demotes it (content persists, not reverted) ──────

T["type into sentinel: typed text persists (demoted, not reverted)"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { SENTINEL_ROW + 1, 0 })
  child.type_keys("i", "my note", "<Esc>")
  vim.loop.sleep(250)

  -- The typed text survives the InsertLeave drain (no revert wiped it).
  eq(child_line(child, SENTINEL_ROW), "my note")
  -- The task above is untouched.
  eq(child_line(child, TASK_ROW):find("Walk dog") ~= nil, true)

  -- Demoted: the block no longer tracks a sentinel extmark …
  local sid =
    child.lua_get("(require('obsidian-tasks.render.draw').render_state(_G._dash_bufnr)[0] or {}).sentinel_extmark_id")
  eq(sid, vim.NIL)
  -- … and the demoted row is no longer inside any managed region (so it will be
  -- written to disk on :w rather than stripped).
  local region =
    child.lua_get("require('obsidian-tasks.render.managed').region_for_row(_G._dash_bufnr, " .. SENTINEL_ROW .. ")")
  eq(region, vim.NIL)

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── refresh after demote: demoted line preserved, no new sentinel ─────────────

T["refresh after demote: demoted line kept, no new sentinel appended"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { SENTINEL_ROW + 1, 0 })
  child.type_keys("i", "my note", "<Esc>")
  vim.loop.sleep(250)

  -- Explicit refresh (simulates <leader>tr / BufWritePost re-render).
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._dash_bufnr, nil)")
  vim.loop.sleep(150)

  -- The demoted line acts as the natural EOF separator: it is preserved and no
  -- fresh sentinel is appended below it.
  eq(child_line_count(child), 5) -- fence(3) + task(1) + demoted line(1)
  eq(child_line(child, SENTINEL_ROW), "my note")
  eq(child_line(child, TASK_ROW):find("Walk dog") ~= nil, true)

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── o on the last task: new task inserted before the sentinel ─────────────────

T["o on last task: new task lands before the sentinel; sentinel relocates"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 0 })
  child.type_keys("o", "- [ ] New task #task", "<Esc>")
  vim.loop.sleep(250)

  -- Source now has both tasks (the new one written after the anchor).
  local src_after = child.lua_get("vim.fn.readfile(_G._src_path)")
  local found_new = false
  for _, l in ipairs(src_after) do
    if l:find("New task") then
      found_new = true
    end
  end
  eq(found_new, true)

  -- Dashboard re-rendered with both tasks and the sentinel relocated to the very
  -- end: exactly one trailing empty line below the last task.
  local n = child_line_count(child)
  eq(child_line(child, n - 1), "") -- last line is the (relocated) sentinel
  eq(child_line(child, n - 2):find("New task") ~= nil, true) -- new task directly above it

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── bug 1: folded zero-result fence keeps its footer visible ──────────────────
-- The results footer must render as the line right after the collapsed fence
-- fold, not vanish into it.  With the footer anchored below fence_last (inside
-- the fold) it disappears when the fold closes; anchoring it above the trailing
-- (sentinel) row keeps it visible.

T["fold: zero-result footer stays visible below the closed fence fold"] = function()
  -- A non-task source line yields zero results, so the dashboard renders only a
  -- footer + sentinel at EOF.
  local child, src_path = spawn_child_with_dashboard("no tasks here")

  -- Fold the fence lines (mirrors render/folds.apply_folds) and close the fold.
  child.lua("vim.cmd('setlocal foldmethod=manual'); vim.cmd('1,3fold')")

  local rows = screen_rows(child)
  local fold_row = screen_find(rows, "tasks") -- default foldtext echoes the ```tasks line
  local footer_row = screen_find(rows, "result") -- "─ 0 results ─"

  -- Footer must be on screen at all while folded …
  eq(footer_row ~= nil, true)
  -- … and sit immediately below the collapsed fence fold.
  eq(fold_row ~= nil and footer_row > fold_row, true)

  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── bug 2: `o` on the last task lands the new line above the footer ───────────
-- Opening a line under the last task should look like inserting inside the
-- query (above the results footer), not below it.  Screenshot while still in
-- insert mode: the in-flight revert is gated off during insert, so the footer's
-- position reflects the extmark anchoring alone.

T["o on last task: the new line renders above the footer (inside the query)"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  child.api.nvim_win_set_cursor(0, { TASK_ROW + 1, 0 })
  -- Stay in insert mode (no <Esc>) so no re-render fires before the screenshot.
  child.type_keys("o", "- [ ] new task")

  local rows = screen_rows(child)
  local new_row = screen_find(rows, "new task")
  local footer_row = screen_find(rows, "result") -- "─ 1 result ─"
  eq(new_row ~= nil and footer_row ~= nil, true)
  -- The freshly opened line is above the footer.
  eq(new_row < footer_row, true)

  child.type_keys("<Esc>")
  child.stop()
  pcall(vim.fn.delete, src_path)
end

-- ── bug 3: deleting a demoted sentinel restores a fresh sentinel ──────────────
-- Typing into the sentinel demotes it (the line becomes the user's content).
-- Deleting that line returns the dashboard to EOF, so a fresh sentinel must be
-- re-appended below the last task.

T["demote then delete: removing the demoted line restores the sentinel"] = function()
  local child, src_path = spawn_child_with_dashboard("- [ ] Walk dog #task")

  -- Demote the sentinel by typing into it.
  child.api.nvim_win_set_cursor(0, { SENTINEL_ROW + 1, 0 })
  child.type_keys("i", "test", "<Esc>")
  vim.loop.sleep(250)
  eq(child_line(child, SENTINEL_ROW), "test") -- demoted: content persisted

  -- Delete the demoted line; the dashboard is back at EOF.
  child.type_keys("dd")
  vim.loop.sleep(250)

  -- A fresh empty sentinel is restored below the task.
  eq(child_line_count(child), 5) -- fence(3) + task(1) + sentinel(1)
  eq(child_line(child, SENTINEL_ROW), "")
  eq(child_line(child, TASK_ROW):find("Walk dog") ~= nil, true)

  child.stop()
  pcall(vim.fn.delete, src_path)
end

return T
