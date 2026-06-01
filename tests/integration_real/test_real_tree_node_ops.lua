-- tests/integration_real/test_real_tree_node_ops.lua
-- Real-mode Phase 6 (per-node-kind operation dispatch) tests using
-- MiniTest.new_child_neovim.
--
-- LOCKED matrix (requirements §11) exercised via genuine keypresses + the real
-- :ObsidianTask dispatch / <leader>t* keymap path:
--
--   • Task-mutation commands (done/toggle/due/priority) on a description BULLET
--     row → brief "not a task" echo, NO source mutation, NO pass-through to the
--     parent task (parent line stays byte-identical).
--   • The SAME commands on a nested child TASK row still mutate that child's own
--     source line (top-level/nested tasks are unaffected).
--   • Task-mutation on a BLANK row → graceful echo, no mutation.
--   • goto on a bullet row jumps to that bullet's OWN source line.
--
-- See CLAUDE.md: real insert-mode/cursor-dispatch tests must drive a child nvim
-- + type_keys / dispatch so mode() is genuinely correct.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- Source subtree written to disk.
--   1  - [ ] Root task #task
--   2      - [ ] Child task #task     (4-space source indent)
--   3      * a description bullet      (4-space source indent, '*' marker)
--   4                                  (blank, interior)
--   5      + trailing bullet           (4-space source indent, '+' marker)
local SRC_CONTENT = {
  "- [ ] Root task #task",
  "    - [ ] Child task #task",
  "    * a description bullet",
  "",
  "    + trailing bullet",
}

--- Boot a child nvim with a real `show tree` dashboard backed by SRC_CONTENT.
--- The index is stubbed to return the root as the matched task and nodes_for to
--- return the parsed live subtree, exercising the real run→layout→draw→fold path
--- and the real cmd dispatch.
local function spawn_tree_dashboard(content)
  content = content or SRC_CONTENT
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
    [[(function(src_content)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")

    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.nodes_for = function(p)
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or src_content)
      end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then
          local ok, lines = pcall(vim.fn.readfile, src)
          local t = task_parse.parse((ok and lines[1]) or src_content[1])
          return t, src, 1
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "show tree", "```" })
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { content }
  )

  return child
end

--- Boot a child nvim whose matched task is source line *matched_line* (1-based),
--- so its real ancestors render as DIM breadcrumb rows above the lit match (used
--- by the Phase 2 dim-ancestor edit/toggle write-through tests).
local function spawn_tree_dashboard_matched(content, matched_line)
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
    [[(function(src_content, matched_line)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")

    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.nodes_for = function(p)
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or src_content)
      end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then
          local ok, lines = pcall(vim.fn.readfile, src)
          local t = task_parse.parse((ok and lines[matched_line]) or src_content[matched_line])
          return t, src, matched_line
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "show tree", "```" })
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { content, matched_line }
  )

  return child
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

--- Dispatch :ObsidianTask <fargs...> with the cursor on dashboard row `row0`
--- (0-indexed) and return ALL log messages captured via a vim.notify spy, joined
--- with newlines.  Per §11 a refused task-mutation on a known non-task row must
--- emit EXACTLY ONE notice — the specific "not a task" one — and NOT the generic
--- "no task found in the specified range" warning; the joined string lets tests
--- assert both the presence of the former and the absence of the latter.
local function dispatch_at(child, row0, fargs)
  return child.lua_get(
    [[(function(row0, fargs)
      local captured = {}
      local orig = vim.notify
      vim.notify = function(msg, level, opts)
        captured[#captured + 1] = msg
        return orig(msg, level, opts)
      end
      vim.api.nvim_win_set_cursor(0, { row0 + 1, 0 })
      require("obsidian-tasks.cmd").dispatch({
        fargs = fargs,
        line1 = row0 + 1,
        line2 = row0 + 1,
      })
      vim.notify = orig
      return table.concat(captured, "\n")
    end)(...)]],
    { row0, fargs }
  )
end

-- Buffer rows (0-indexed): 0 fence, 1 query, 2 fence,
--   3 root task, 4 child task, 5 '*' description bullet, 6 blank,
--   7 '+' trailing bullet.
local ROOT_ROW = 3
local CHILD_ROW = 4
local BULLET_ROW = 5
local BLANK_ROW = 6

-- ── BULLET row: task-mutation commands are DISABLED (echo, no write) ─────────

local MUTATION_CASES = {
  { name = "done", fargs = { "done" } },
  { name = "toggle", fargs = { "toggle" } },
  { name = "due", fargs = { "due", "2025-01-01" } },
  { name = "priority", fargs = { "priority", "high" } },
}

for _, case in ipairs(MUTATION_CASES) do
  T["bullet: " .. case.name .. " → 'not a task' echo, source UNCHANGED, no pass-through"] = function()
    local child = spawn_tree_dashboard()
    local before = child_src(child)

    local notice = dispatch_at(child, BULLET_ROW, case.fargs)

    local after = child_src(child)
    eq(after, before, case.name .. " on a bullet must NOT mutate ANY source line (no pass-through)")
    eq(
      notice ~= nil and notice:lower():find("not a task") ~= nil,
      true,
      case.name .. " on a bullet must emit a 'not a task' notice, got: " .. tostring(notice)
    )
    -- §11 single-notice rule: the redundant generic "no task found in the
    -- specified range" warning must be suppressed (the specific notice already
    -- explained why nothing happened).
    eq(
      notice ~= nil and notice:lower():find("no task found") == nil,
      true,
      case.name .. " on a bullet must NOT also emit the generic 'no task found' warning, got: " .. tostring(notice)
    )

    child.stop()
  end
end

-- ── BLANK row: task-mutation disabled with a graceful echo, no mutation ──────

T["blank: done → graceful 'not a task' echo, source UNCHANGED"] = function()
  local child = spawn_tree_dashboard()
  local before = child_src(child)

  local notice = dispatch_at(child, BLANK_ROW, { "done" })

  local after = child_src(child)
  eq(after, before, "done on a blank row must NOT mutate any source line")
  eq(
    notice ~= nil and notice:lower():find("not a task") ~= nil,
    true,
    "done on a blank must emit a 'not a task' notice, got: " .. tostring(notice)
  )
  -- §11 single-notice rule: no redundant generic warning on a known non-task row.
  eq(
    notice ~= nil and notice:lower():find("no task found") == nil,
    true,
    "done on a blank must NOT also emit the generic 'no task found' warning, got: " .. tostring(notice)
  )

  child.stop()
end

-- ── Genuinely empty / non-managed range still warns (regression guard) ────────
-- The single-notice suppression must NOT swallow the generic warning when the
-- cursor is on a row that is NOT a managed task at all (no "not a task" notice
-- was emitted).  Dispatch on the query-fence row (row 1) which carries no
-- task-meta → bulk_range returns empty with explained=false → the subcommand
-- must surface its generic "no task found in the specified range" warning.
T["non-managed range: done still emits the generic 'no task found' warning"] = function()
  local child = spawn_tree_dashboard()
  local before = child_src(child)

  local FENCE_QUERY_ROW = 1 -- the "show tree" line inside the ```tasks fence
  local notice = dispatch_at(child, FENCE_QUERY_ROW, { "done" })

  local after = child_src(child)
  eq(after, before, "done on a non-managed row must NOT mutate any source line")
  eq(
    notice ~= nil and notice:lower():find("no task found") ~= nil,
    true,
    "done on a genuinely non-managed range must still emit the generic warning, got: " .. tostring(notice)
  )
  eq(
    notice ~= nil and notice:lower():find("not a task") == nil,
    true,
    "a non-managed row is not a known bullet/blank, so no 'not a task' notice, got: " .. tostring(notice)
  )

  child.stop()
end

-- ── Nested child TASK row: task-mutation still works on its OWN source line ───

T["nested child task: done mutates the child's own source line (parent untouched)"] = function()
  local child = spawn_tree_dashboard()

  dispatch_at(child, CHILD_ROW, { "done" })

  local src = child_src(child)
  eq(src[1], "- [ ] Root task #task", "root/parent source line must be untouched")
  eq(src[2]:find("%[x%]") ~= nil, true, "child's OWN source line must be marked done: " .. tostring(src[2]))
  eq(src[2]:sub(1, 4), "    ", "child keeps its 4-space source indent")
  eq(src[3], "    * a description bullet", "the bullet must be untouched")

  child.stop()
end

T["nested child task: priority high mutates the child's own source line"] = function()
  local child = spawn_tree_dashboard()

  dispatch_at(child, CHILD_ROW, { "priority", "high" })

  local src = child_src(child)
  eq(src[1], "- [ ] Root task #task", "root/parent source line must be untouched")
  -- The high-priority emoji must land on the CHILD line.
  eq(src[2]:find("Child task") ~= nil, true, "child line must survive: " .. tostring(src[2]))
  eq(src[2] ~= "    - [ ] Child task #task", true, "child line must reflect the priority change: " .. tostring(src[2]))

  child.stop()
end

-- ── Top-level matched TASK row still works (regression guard) ─────────────────

T["root task: done mutates the root's own source line"] = function()
  local child = spawn_tree_dashboard()

  dispatch_at(child, ROOT_ROW, { "done" })

  local src = child_src(child)
  eq(src[1]:find("%[x%]") ~= nil, true, "root's own source line must be marked done: " .. tostring(src[1]))
  eq(src[2], "    - [ ] Child task #task", "child must be untouched")

  child.stop()
end

-- ── goto on a bullet row jumps to that bullet's OWN source line ───────────────

T["goto on a bullet jumps to the bullet's source line"] = function()
  local child = spawn_tree_dashboard()

  child.lua([[
    vim.api.nvim_win_set_cursor(0, { ]] .. (BULLET_ROW + 1) .. [[, 0 })
    require("obsidian-tasks.cmd").dispatch({
      fargs = { "goto" },
      line1 = ]] .. (BULLET_ROW + 1) .. [[,
      line2 = ]] .. (BULLET_ROW + 1) .. [[,
    })
  ]])

  -- The current buffer is now the source file, cursor on the bullet's line (3).
  local name = child.lua_get("vim.api.nvim_buf_get_name(0)")
  local srcpath = child.lua_get("_G._src_path")
  eq(name, srcpath, "goto must open the bullet's source file")
  local curline = child.lua_get("vim.api.nvim_win_get_cursor(0)[1]")
  eq(curline, 3, "goto must place the cursor on the bullet's source line (line 3)")
  local linetext = child.lua_get("vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]")
  eq(linetext, "    * a description bullet", "cursor must be on the description bullet line")

  child.stop()
end

-- ── DIM ANCESTOR edit-through (Phase 2 Deliverable 4) ─────────────────────────
--
-- When the matched task is a CHILD, its real ancestors render as DIM, managed,
-- EDITABLE breadcrumb rows carrying real source meta.  Editing a dim ancestor's
-- body, or running a status/field command on it, must write through to its OWN
-- single source line via the normal flush / command path.
--
-- Source (2-space indent): grandparent(0), parent(1, DIM), match(2, MATCHED).
local DIM_SRC = {
  "- [ ] Grandparent #task",
  "  - [ ] Parent #task",
  "    - [ ] Match #task",
}

T["dim ancestor body edit writes through to its OWN source line"] = function()
  local child = spawn_tree_dashboard_matched(DIM_SRC, 3)

  -- Dashboard rows: 3 DIM grandparent(0), 4 DIM parent(1), 5 LIT match(2).
  -- Edit the DIM PARENT's body via a real keypress.  The rendered row carries a
  -- trailing backlink wikilink suffix, so we change a BODY word (ciw on "Parent")
  -- rather than appending at line end, which would land text after the suffix.
  local PARENT_ROW = 4
  local rendered = child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 4, 5, false)[1]")
  eq(rendered:find("Parent", 1, true) ~= nil, true, "dim parent row must render at row 4")
  -- Column of the "Parent" word (0-indexed) for the cursor.
  local pcol = child.lua_get("(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 4, 5, false)[1]):find('Parent') - 1")

  child.api.nvim_win_set_cursor(0, { PARENT_ROW + 1, pcol })
  child.type_keys("ciw", "Renamed", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  -- Only the dim parent's OWN source line changed; grandparent + match untouched.
  eq(src[1], "- [ ] Grandparent #task", "grandparent untouched")
  eq(src[2], "  - [ ] Renamed #task", "dim ancestor body edit writes to its OWN line: " .. tostring(src[2]))
  eq(src[3], "    - [ ] Match #task", "match untouched")

  child.stop()
end

T["dim ancestor status toggle (done) writes through to its OWN source line"] = function()
  local child = spawn_tree_dashboard_matched(DIM_SRC, 3)

  -- :ObsidianTask done on the DIM PARENT row → its OWN checkbox flips to [x].
  local PARENT_ROW = 4
  child.lua([[
    vim.api.nvim_win_set_cursor(0, { ]] .. (PARENT_ROW + 1) .. [[, 0 })
    require("obsidian-tasks.cmd").dispatch({
      fargs = { "done" },
      line1 = ]] .. (PARENT_ROW + 1) .. [[,
      line2 = ]] .. (PARENT_ROW + 1) .. [[,
    })
  ]])
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(src[1], "- [ ] Grandparent #task", "grandparent untouched")
  eq(src[2]:find("%[x%]") ~= nil, true, "dim ancestor's OWN checkbox must be marked done: " .. tostring(src[2]))
  eq(src[2]:sub(1, 2), "  ", "dim ancestor keeps its 2-space source indent: " .. tostring(src[2]))
  eq(src[2]:find("Parent", 1, true) ~= nil, true, "must be the PARENT's line: " .. tostring(src[2]))
  eq(src[3], "    - [ ] Match #task", "match untouched (no pass-through)")

  child.stop()
end

return T
