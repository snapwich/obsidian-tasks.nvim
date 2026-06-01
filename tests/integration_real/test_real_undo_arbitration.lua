-- tests/integration_real/test_real_undo_arbitration.lua
-- Bug 2: `u` in a dashboard buffer must arbitrate between the plugin's task-undo
-- ring and Neovim's NATIVE undo by RECENCY.  A native in-buffer edit (prose, a
-- query tweak — anything outside a managed row) must be undoable with plain `u`
-- even when the plugin ring is non-empty, and the most recent action wins.
--
-- Driven through REAL keypresses (child nvim + type_keys) so the buffer-local
-- `u` keymap and the native undo sequence are the genuine ones.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

--- Boot a dashboard whose note has a plain prose TITLE line above the fence
--- (a native-editable region) plus one matched task.
local function spawn(content, query_lines)
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
    [[(function(args)
    local src_content, query_lines = args[1], args[2]
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)
    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.nodes_for = function(p)
      if p == src then return nodes_mod.parse_lines(vim.fn.readfile(src)) end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then
          local lines = vim.fn.readfile(src)
          return task_parse.parse(lines[1]), src, 1
        end
      end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, query_lines)
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash = bufnr
    _G._src = src
  end)(...)]],
    { { content, query_lines } }
  )
  return child
end

local function line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash, " .. row0 .. ", " .. (row0 + 1) .. ", false)[1]")
end

-- Layout: 0 TITLE, 1 fence, 2 query, 3 fence, 4 task, 5 sentinel.

--- Apply a task edit through the SAME path a `<leader>tt` toggle uses
--- (cmd.apply_source_edit with dashboard_bufnr), then re-render.  This records a
--- plugin undo-ring entry stamped with the current native seq — identical to a
--- real toggle, but without depending on the leader key in type_keys.
local function plugin_toggle(child, new_line)
  child.lua(
    [[(function(nl)
    local cmd = require("obsidian-tasks.cmd")
    cmd.apply_source_edit(_G._src, 0, { nl }, { dashboard_bufnr = _G._dash })
    require("obsidian-tasks.render").rerender_buffer(_G._dash, nil)
  end)(...)]],
    { new_line }
  )
end

T["native edit after a task edit: u undoes the native edit first, then the task"] = function()
  local child = spawn({ "- [ ] anchor #task" }, { "TITLE", "```tasks", "show tree", "```" })

  -- 1) Plugin task edit (ring entry; does NOT advance native undo seq).
  plugin_toggle(child, "- [x] anchor #task")
  vim.loop.sleep(150)
  eq(line(child, 4):match("%[x%]") ~= nil, true, "task toggled to done: " .. tostring(line(child, 4)))

  -- 2) Native edit on the TITLE line (outside any managed row).
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys("A", " EDITED", "<Esc>")
  vim.loop.sleep(150)
  eq(line(child, 0), "TITLE EDITED")

  -- 3) `u` must undo the NATIVE title edit (most recent), not the task.
  child.type_keys("u")
  vim.loop.sleep(250)
  eq(line(child, 0), "TITLE", "first u undid the native title edit (recency)")
  eq(line(child, 4):match("%[x%]") ~= nil, true, "task still done after first u: " .. tostring(line(child, 4)))

  -- 4) `u` again undoes the TASK toggle via the plugin ring.
  child.type_keys("u")
  vim.loop.sleep(250)
  eq(
    line(child, 4):match("%[ %]") ~= nil,
    true,
    "second u undid the task toggle via the ring: " .. tostring(line(child, 4))
  )

  child.stop()
end

T["pure native edit with an empty ring: u just works natively"] = function()
  local child = spawn({ "- [ ] anchor #task" }, { "TITLE", "```tasks", "show tree", "```" })
  child.api.nvim_win_set_cursor(0, { 1, 0 })
  child.type_keys("A", " HELLO", "<Esc>")
  vim.loop.sleep(120)
  eq(line(child, 0), "TITLE HELLO")
  child.type_keys("u")
  vim.loop.sleep(150)
  eq(line(child, 0), "TITLE", "native undo works when the ring is empty")
  child.stop()
end

return T
