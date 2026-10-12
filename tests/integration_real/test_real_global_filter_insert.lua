-- tests/integration_real/test_real_global_filter_insert.lua
-- Plan D6 (group-top insert, step 1), through REAL keypresses (child nvim +
-- type_keys): every new TASK line that a dashboard insert writes to its source
-- note gets the global filter in its description when the typed text does not
-- have it.  Without it the index drops the new task, and it disappears from the
-- dashboard on the rerender after the write.
--
-- The index stub here applies the global filter the same way the real index
-- does (index/init.lua make_on_task), so "stays visible after rerender" is a
-- real check, not a stub artifact.  Covers the three insert paths in
-- render/edit_insert.lua: flat, tree single-line, tree block.  Description
-- bullets are not tasks and are written as typed.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local SRC = {
  "# work",
  "",
  "- [ ] Alpha #task",
  "- [ ] Beta #task",
  "",
  "# home",
  "",
  "- [ ] Gamma #task",
}

--- Boot a child nvim with a grouped dashboard over one source note, with
--- global_filter = "#task".  The stubbed index parses the note through the real
--- node parser with a global-filter on_task hook, so a task line without the
--- filter in its description is dropped exactly as the real index drops it.
--- @param query_lines string[]  fence body (without the fences)
--- @return table child
local function spawn(query_lines)
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
    [[(function(src_content, query_lines)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local function on_task(task)
      return task.description:find("#task", 1, true) ~= nil
    end
    local function read_nodes()
      local ok, lines = pcall(vim.fn.readfile, src)
      return nodes_mod.parse_lines(ok and lines or src_content, { on_task = on_task })
    end

    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.nodes_for = function(p)
      if p == src then
        return read_nodes()
      end
      return {}
    end
    index.tasks_in = function()
      local emit = {}
      for _, n in ipairs(read_nodes()) do
        if n.kind == "task" then
          emit[#emit + 1] = { n.task, src, n.line_num }
        end
      end
      local i = 0
      return function()
        i = i + 1
        if emit[i] then
          return emit[i][1], emit[i][2], emit[i][3]
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local bufnr = vim.api.nvim_create_buf(false, true)
    local fence = { "```tasks" }
    for _, q in ipairs(query_lines) do fence[#fence + 1] = q end
    fence[#fence + 1] = "```"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fence)
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    -- Literal indentation for typed lines (no autoindent from the anchor).
    vim.bo[bufnr].autoindent = false
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src = src
  end)(...)]],
    { SRC, query_lines }
  )
  return child
end

local function src_lines(child)
  return child.lua_get("vim.fn.readfile(_G._src)")
end

local function dash_lines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
end

local function find_row(child, needle)
  for i, l in ipairs(dash_lines(child)) do
    if l:find(needle, 1, true) then
      return i - 1
    end
  end
  return -1
end

--- The source line whose text contains *needle*, or nil.
local function src_line_with(child, needle)
  for _, l in ipairs(src_lines(child)) do
    if l:find(needle, 1, true) then
      return l
    end
  end
  return nil
end

local function cleanup(child)
  local src = child.lua_get("_G._src")
  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── flat ─────────────────────────────────────────────────────────────────────

T["flat grouped: bare 'foo' typed via o lands as '- [ ] foo #task' and stays visible"] = function()
  local child = spawn({ "not done", "group by heading" })
  local row = find_row(child, "Alpha")
  eq(row >= 0, true, "Alpha must render")

  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  child.type_keys("o", "foo", "<Esc>")
  vim.loop.sleep(400)

  eq(src_line_with(child, "foo"), "- [ ] foo #task", "src=" .. vim.inspect(src_lines(child)))
  eq(find_row(child, "foo") >= 0, true, "foo must stay visible after rerender: " .. vim.inspect(dash_lines(child)))
  cleanup(child)
end

T["flat grouped: filter goes before a typed date field"] = function()
  local child = spawn({ "not done", "group by heading" })
  local row = find_row(child, "Alpha")
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  child.type_keys("o", "bar 📅 2026-10-12", "<Esc>")
  vim.loop.sleep(400)

  eq(src_line_with(child, "bar"), "- [ ] bar #task 📅 2026-10-12", "src=" .. vim.inspect(src_lines(child)))
  eq(find_row(child, "bar") >= 0, true, "bar must stay visible after rerender: " .. vim.inspect(dash_lines(child)))
  cleanup(child)
end

T["flat grouped: typed filter is not duplicated"] = function()
  local child = spawn({ "not done", "group by heading" })
  local row = find_row(child, "Alpha")
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  child.type_keys("o", "- [ ] baz #task", "<Esc>")
  vim.loop.sleep(400)

  eq(src_line_with(child, "baz"), "- [ ] baz #task", "src=" .. vim.inspect(src_lines(child)))
  cleanup(child)
end

-- ── tree ─────────────────────────────────────────────────────────────────────

T["tree single-line: bare 'foo' typed via o lands as '- [ ] foo #task' and stays visible"] = function()
  local child = spawn({ "not done", "show tree", "group by heading" })
  local row = find_row(child, "Alpha")
  eq(row >= 0, true, "Alpha must render")

  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  child.type_keys("o", "foo", "<Esc>")
  vim.loop.sleep(400)

  eq(src_line_with(child, "foo"), "- [ ] foo #task", "src=" .. vim.inspect(src_lines(child)))
  eq(find_row(child, "foo") >= 0, true, "foo must stay visible after rerender: " .. vim.inspect(dash_lines(child)))
  cleanup(child)
end

T["tree single-line: description bullet is written as typed (no filter)"] = function()
  local child = spawn({ "not done", "show tree", "group by heading" })
  local row = find_row(child, "Alpha")
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  child.type_keys("o", "  - a note", "<Esc>")
  vim.loop.sleep(400)

  eq(src_line_with(child, "a note"), "  - a note", "src=" .. vim.inspect(src_lines(child)))
  cleanup(child)
end

T["tree block: every task line gets the filter, the description bullet does not"] = function()
  local child = spawn({ "not done", "show tree", "group by heading" })
  local row = find_row(child, "Alpha")
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  child.type_keys("o", "root", "<CR>", "  - a note", "<CR>", "  - [ ] kid", "<Esc>")
  vim.loop.sleep(500)

  local src = src_lines(child)
  eq(src_line_with(child, "root"), "- [ ] root #task", "src=" .. vim.inspect(src))
  eq(src_line_with(child, "a note"), "  - a note", "src=" .. vim.inspect(src))
  eq(src_line_with(child, "kid"), "  - [ ] kid #task", "src=" .. vim.inspect(src))
  local dash = dash_lines(child)
  eq(find_row(child, "root") >= 0, true, "root must stay visible: " .. vim.inspect(dash))
  eq(find_row(child, "kid") >= 0, true, "kid must stay visible: " .. vim.inspect(dash))
  cleanup(child)
end

return T
