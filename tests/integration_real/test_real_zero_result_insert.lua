-- tests/integration_real/test_real_zero_result_insert.lua
-- Bug 3: inserting a task in a ZERO-RESULT dashboard (no task to anchor to) must
-- NOT lose the typed content.  The dashboard buffer IS the note file, so the
-- typed line is kept as plain NOTE content just below the query block's closing
-- fence (outside the rendered region) and persists on :w.  The user can relocate
-- it.  Driven through REAL keypresses against a file-backed buffer.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

--- Boot a file-backed zero-result dashboard note.  tasks_in yields nothing (a
--- restrictive query that matches no task), so the dashboard renders empty.
local function spawn()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "", "```tasks", "path includes NONE", "```" }, note)
    local index = require("obsidian-tasks.index")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function() return {} end
    index.tasks_in = function() return function() return nil end end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    vim.b[b].obsidian_tasks_dashboard = true
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._b = b
    _G._note = note
  ]],
    { cwd, deps_dir }
  )
  return child
end

local function buflines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")
end

T["typing a task in a zero-result dashboard keeps it below the fence + persists on :w"] = function()
  local child = spawn()
  -- Buffer: 0 '# Daily', 1 '', 2 '```tasks', 3 'path includes NONE', 4 '```', 5 sentinel.
  -- `o` on the closing fence, type a task, leave insert.
  child.api.nvim_win_set_cursor(0, { 5, 0 }) -- closing fence (1-indexed row 5)
  child.type_keys("o", "- [ ] brand new task", "<Esc>")
  vim.loop.sleep(450)

  local b = buflines(child)
  -- The task must be present, immediately below the closing fence, and exactly
  -- once (no double-render — a restrictive query doesn't match it).
  local count, idx = 0, nil
  for i, l in ipairs(b) do
    if l == "- [ ] brand new task" then
      count = count + 1
      idx = i
    end
  end
  eq(count, 1, "task present exactly once: " .. vim.inspect(b))
  eq(b[idx - 1], "```", "task sits just below the closing fence")
  -- It must NOT carry a rendered backlink ([[N]]) — it's plain note content.
  eq(b[idx]:match("%[%[%d+%]%]") == nil, true, "no rendered backlink")

  -- Save and confirm the note file on disk keeps the line (no data loss).
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(150)
  local disk = child.lua_get("vim.fn.readfile(_G._note)")
  local on_disk = false
  for _, l in ipairs(disk) do
    if l == "- [ ] brand new task" then
      on_disk = true
    end
  end
  eq(on_disk, true, ":w persisted the task to the note file: " .. vim.inspect(disk))

  child.stop()
end

return T
