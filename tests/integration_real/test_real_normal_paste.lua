-- tests/integration_real/test_real_normal_paste.lua
-- Bug 1: a NORMAL-mode paste (`p`) of task rows into a `show tree` dashboard must
-- be reconciled to source — it previously vanished because flush's INSERT
-- detection only ran on InsertLeave (or managed-row edits), so a `p` (which never
-- enters insert mode) scheduled only the do_revert re-render, which cleared the
-- new rows.  When the pasted rows are RENDERED dashboard rows (carrying the
-- appended ' [[backlink]]'), the backlink must be stripped so source stays clean.
--
-- Driven through REAL keypresses (child nvim + type_keys).

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local function spawn(content)
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
    [[(function(c)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(c, src)
    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local tp = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.nodes_for = function(p)
      if p == src then return nodes_mod.parse_lines(vim.fn.readfile(src)) end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then return tp.parse(vim.fn.readfile(src)[1]), src, 1 end
      end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "```tasks", "show tree", "```" })
    vim.b[b].obsidian_tasks_dashboard = true
    render.render_buffer(b, nil)
    vim.api.nvim_set_current_buf(b)
    vim.cmd("normal! zR")
    _G._dash = b
    _G._src = src
  end)(...)]],
    { content }
  )
  return child
end

local function src(child)
  return child.lua_get("vim.fn.readfile(_G._src)")
end

T["normal-mode paste of two rendered child rows: added to source, backlink stripped"] = function()
  -- anchor (matched root) drags test2 (depth 1) + test3 (depth 2) in.  The
  -- rendered rows carry an appended backlink; the user's own [[note|alias]] is
  -- part of the task body and must be preserved.
  local child = spawn({
    "- [ ] anchor #task",
    "  - [ ] test2 [[note|alias]]",
    "    - [ ] test3 [[note|alias]]",
  })
  -- Buffer rows (0-idx): 0 fence,1 query,2 fence,3 anchor,4 test2,5 test3,6 sentinel.
  -- Yank the two child rows (1-indexed 5,6) in NORMAL mode, paste below anchor.
  child.api.nvim_win_set_cursor(0, { 5, 0 })
  child.type_keys("Vj", "y")
  child.api.nvim_win_set_cursor(0, { 4, 0 }) -- anchor
  child.type_keys("p")
  vim.loop.sleep(450)

  local s = src(child)
  eq(#s, 5, "two tasks added to source: " .. vim.inspect(s))
  eq(s[1], "- [ ] anchor #task")
  eq(s[2], "  - [ ] test2 [[note|alias]]")
  eq(s[3], "    - [ ] test3 [[note|alias]]")
  -- Pasted copies: anchor-relative depth (child / grandchild of anchor), and the
  -- appended dashboard backlink ([[0]]) is NOT present — only the user's wikilink.
  eq(s[4], "  - [ ] test2 [[note|alias]]", "pasted test2 clean + nested under anchor: [" .. tostring(s[4]) .. "]")
  eq(s[5], "    - [ ] test3 [[note|alias]]", "pasted test3 clean + nested under test2: [" .. tostring(s[5]) .. "]")
  -- No leaked numeric backlink anywhere.
  for _, l in ipairs(s) do
    eq(l:match("%[%[%d+%]%]") == nil, true, "no leaked [[N]] backlink in: [" .. l .. "]")
  end

  child.stop()
end

return T
