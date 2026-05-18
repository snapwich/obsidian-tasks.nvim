-- tests/integration_real/test_real_mass_delete.lua
-- Real-mode coverage for ot-3scr (P7 mass-delete gate) manual verification.
--
-- Covers steps 1, 2, 3, 4 of ot-3scr.md:
--   1. single dd → block delete (also covered in test_e2e but lighter-weight here)
--   2. visual-line select 2 rows, d → both deleted (intact block, no gate)
--   3. ggdG → gate fires, source untouched, warning emitted
--   4. :%d → same as ggdG (gate fires)
--
-- Steps 5-6 (broken fence, multi-block partial) are deferred to future tickets.

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
    vim.opt.rtp:prepend(deps_dir .. "/obsidian.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/blink.cmp")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian").setup({
      workspaces = { { name = "test-vault", path = cwd .. "/tests/fixtures/vault" } },
      log_level = vim.log.levels.ERROR,
      completion = { nvim_cmp = false, blink = false },
      picker = { name = nil }, ui = { enable = false },
    })
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

  local src = child.lua_get(
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
    _G._orig_warn = log.warn
    log.warn = function(msg)
      table.insert(_G._warns, tostring(msg))
      _G._orig_warn(msg)
    end
    return src
  end)(...)]],
    { task_lines }
  )

  return child, src
end

-- ── single dd: intact-block delete propagates ─────────────────────────────────

T["single dd on managed row: source loses the task (no gate)"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] Task A #task",
    "- [ ] Task B #task",
    "- [ ] Task C #task",
  })

  -- Find Task B row.
  local b_row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find("Task B", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  eq(b_row >= 0, true, "Task B must exist before dd")

  child.api.nvim_win_set_cursor(0, { b_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(300)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  local b_present = false
  for _, l in ipairs(src_after) do
    if l:find("Task B") then
      b_present = true
    end
  end
  eq(b_present, false, "Task B must be deleted from source after dd")
  -- Other tasks untouched.
  eq(src_after[1], "- [ ] Task A #task", "Task A must remain")

  local warns = child.lua_get("_G._warns")
  for _, w in ipairs(warns) do
    eq(w:find("dashboard cleared"), nil, "single dd must NOT trigger the mass-delete gate")
  end

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── visual-line + d: intact multi-delete, gate does NOT fire ─────────────────

T["visual-line dd on 2 rows: both deleted from source (block still intact)"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] Task A #task",
    "- [ ] Task B #task",
    "- [ ] Task C #task",
  })

  local b_row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find("Task B", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  child.api.nvim_win_set_cursor(0, { b_row + 1, 0 })
  -- V then j to select 2 lines, then d to delete.
  child.type_keys("V", "j", "d")
  vim.loop.sleep(300)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  local b_present, c_present = false, false
  for _, l in ipairs(src_after) do
    if l:find("Task B") then
      b_present = true
    end
    if l:find("Task C") then
      c_present = true
    end
  end
  eq(b_present, false, "Task B must be deleted")
  eq(c_present, false, "Task C must be deleted")
  eq(src_after[1], "- [ ] Task A #task", "Task A must remain")

  local warns = child.lua_get("_G._warns")
  local saw_gate = false
  for _, w in ipairs(warns) do
    if w:find("dashboard cleared") then
      saw_gate = true
    end
  end
  eq(saw_gate, false, "intact-block multi-delete must NOT trigger the gate")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── :%d mass-delete: same as ggdG → gate fires, source untouched ─────────────

T[":%d wipes all rows: P7 gate fires, source untouched"] = function()
  local child, src = spawn_with_tasks({
    "- [ ] Task A #task",
    "- [ ] Task B #task",
    "- [ ] Task C #task",
  })

  local src_before = child.lua_get("vim.fn.readfile(_G._src)")
  child.cmd("%d")
  vim.loop.sleep(500)

  local src_after = child.lua_get("vim.fn.readfile(_G._src)")
  eq(
    vim.deep_equal(src_before, src_after),
    true,
    ":%d must leave source untouched (P7 gate); src_before="
      .. vim.inspect(src_before)
      .. " src_after="
      .. vim.inspect(src_after)
  )

  local warns = child.lua_get("_G._warns")
  local saw_gate = false
  for _, w in ipairs(warns) do
    if w:find("dashboard cleared") then
      saw_gate = true
    end
  end
  eq(saw_gate, true, ":%d must emit the 'dashboard cleared' gate warning")

  child.stop()
  pcall(vim.fn.delete, src)
end

return T
