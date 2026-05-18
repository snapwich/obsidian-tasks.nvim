-- tests/integration_real/test_real_p9_group_attr.lua
-- Real-mode coverage for ot-m3e1 (P9 group-defining attribute auto-add).
--
-- Covers steps 2, 4 of ot-m3e1.md:
--   2. group by priority — paste into ⏫ group → priority emoji auto-added
--   4. group by file — paste into a file group → NO auto-add (position-based)
--
-- Steps 1 (group by tag), 3 (status), 5 (multi-level), 6 (mixed-origin),
-- 7 (dataview) are partially covered elsewhere or deferred.  Step 1 already
-- has real-mode coverage in test_e2e_edit_in_place.lua.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local function spawn_with_query(task_lines, query_lines)
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

  child.lua_get(
    [[(function(task_lines, query_lines)
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
    local fence_lines = { "```tasks" }
    for _, q in ipairs(query_lines) do fence_lines[#fence_lines + 1] = q end
    fence_lines[#fence_lines + 1] = "```"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fence_lines)
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src = src
    return src
  end)(...)]],
    { task_lines, query_lines }
  )

  local src = child.lua_get("_G._src")
  return child, src
end

local function find_row(child, needle)
  return child.lua_get(string.format(
    [[(function()
        for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
          if l and l:find(%q, 1, true) then return i - 1 end
        end
        return -1
      end)()]],
    needle
  ))
end

-- ── group by priority: paste new task in ⏫ group → priority emoji added ──────

T["group by priority: new task in ⏫ group gets ⏫ auto-added"] = function()
  local child, src = spawn_with_query({
    "- [ ] Task High ⏫ #task",
    "- [ ] Task Low 🔽 #task",
  }, { "not done", "group by priority" })

  -- Find "Task High" — anchor for `o`.  The line has the ⏫ emoji.
  local high_row = find_row(child, "Task High")
  eq(high_row >= 0, true, "Task High row must exist")

  child.api.nvim_win_set_cursor(0, { high_row + 1, 0 })
  child.type_keys("o", "- [ ] New high-priority task", "<Esc>")
  vim.loop.sleep(400)

  local src = child.lua_get("vim.fn.readfile(_G._src)")
  local found = nil
  for _, l in ipairs(src) do
    if l:find("New high%-priority task") then
      found = l
    end
  end
  eq(found ~= nil, true, "new task must appear in source: src=" .. vim.inspect(src))
  eq(found:find("⏫") ~= nil, true, "P9 must auto-add ⏫ in priority group: found=[" .. (found or "nil") .. "]")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── group by file: paste new task → NO auto-add (position is inheritance) ────

T["group by file: new task does NOT get a file attribute auto-added"] = function()
  local child, src = spawn_with_query({
    "- [ ] File task A #task",
    "- [ ] File task B #task",
  }, { "not done", "group by path" })

  local a_row = find_row(child, "File task A")
  eq(a_row >= 0, true, "File task A row must exist")

  child.api.nvim_win_set_cursor(0, { a_row + 1, 0 })
  child.type_keys("o", "- [ ] Plain new task", "<Esc>")
  vim.loop.sleep(400)

  local src = child.lua_get("vim.fn.readfile(_G._src)")
  local found = nil
  for _, l in ipairs(src) do
    if l:find("Plain new task") then
      found = l
    end
  end
  eq(found ~= nil, true, "new task must appear in source")
  -- Confirm no extraneous attributes appended (the task line stays clean — no
  -- emoji, no #tag, no dataview field beyond what the user typed).  The
  -- group-by-file inheritance is "the file the new task lives in".
  eq(
    found:gsub("%s+$", ""),
    "- [ ] Plain new task",
    "P9 must NOT auto-add anything for group by file: found=[" .. (found or "nil") .. "]"
  )

  child.stop()
  pcall(vim.fn.delete, src)
end

return T
