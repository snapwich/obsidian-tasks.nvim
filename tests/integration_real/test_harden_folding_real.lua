-- tests/integration_real/test_harden_folding_real.lua
-- Hardening: folding mechanics exercised through REAL keypresses (child nvim +
-- type_keys → real mode(), real InsertLeave/flush drain, real za/zc/zR/zM).
--
-- Covers the folding edge-cases that genuinely need the terminal-equivalent path:
--   • closed-fold-survives-grouped-rerender — a `group by tags` dashboard, one
--     subtree user-closed, an unrelated edit triggers the GROUPED whole-dashboard
--     rerender; the closed subtree must stay closed.
--   • group-by-tags-regroup-closed-fold — editing a task's tag re-groups it to a
--     different group; its closed subtree must stay closed at the new position.
--   • default-folded-false-with-tree — a manually-closed subtree persists across a
--     rerender even with default_folded=false.
--   • nested-subtrees-fold-independence — a nested child subtree's closed state
--     survives closing+reopening the parent fold.
--   • group-footer-visibility-last-subtree-closed — the group footer virt line
--     stays visible when the last subtree in the group is closed.
--   • zR-zM-nested-folds — global fold commands affect fence + nested subtrees.
--   • eof-sentinel-with-closed-fold — <CR> on the EOF sentinel while a subtree is
--     closed: the newline persists and the closed fold survives.
--   • linger-subtree-fold-structure-preserved — a closed root toggled Done lingers
--     dimmed; how is its fold rendered?  (open question: best-guess = OPEN.)
--
-- See CLAUDE.md: real fold/insert tests must drive a child nvim via type_keys;
-- do NOT pre-set vim.b.obsidian_tasks_dashboard (let the first render's
-- draw → save.attach register the BufWriteCmd strip handler).

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── grouped `show tree` dashboard (group by tags) ─────────────────────────────
--
-- Yields BOTH source tasks so the real `group by tags` buckets them by their own
-- tags.  nodes_for parses the LIVE file so edits round-trip on rerender.  Modeled
-- on test_real_tree_group_attr.lua's spawner.
local function spawn_grouped(content, query_lines)
  query_lines = query_lines or { "```tasks", "show tree", "group by tags", "```" }
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
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or src_content)
      end
      return {}
    end
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      lines = ok and lines or src_content
      local emit = {}
      for ln, text in ipairs(lines) do
        local t = task_parse.parse(text)
        if t then emit[#emit + 1] = { t, src, ln } end
      end
      local i = 0
      return function()
        i = i + 1
        if emit[i] then return emit[i][1], emit[i][2], emit[i][3] end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, query_lines)
    -- Display the buffer BEFORE rendering: apply_folds iterates win_findbuf, so
    -- subtree folds are only created when a window already shows the buffer.
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].autoindent = false
    render.render_buffer(bufnr, nil)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { { content, query_lines } }
  )

  return child
end

-- ── flat-tree (no grouping) `show tree` dashboard ─────────────────────────────
--
-- One matched root (source line 1); nodes_for parses the live file.  Modeled on
-- test_real_tree_delete.lua's spawner.
local function spawn_tree(content, default_folded)
  if default_folded == nil then
    default_folded = false
  end
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
    local src_content, default_folded = args[1], args[2]
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")

    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.reverse_index = function() return {} end
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
          return task_parse.parse((ok and lines[1]) or src_content[1]), src, 1
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = default_folded })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "show tree", "```" })
    -- Display the buffer BEFORE rendering so apply_folds (win_findbuf) creates
    -- the subtree folds in the showing window.
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].autoindent = false
    render.render_buffer(bufnr, nil)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { { content, default_folded } }
  )

  return child
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

local function buflines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
end

--- 0-indexed dashboard row whose text contains *needle* (first match).
local function dash_row(child, needle)
  return child.lua_get(
    [[(function(needle)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find(needle, 1, true) then return i - 1 end
    end
    return -1
  end)(...)]],
    { needle }
  )
end

--- 0-indexed dashboard row of the managed task whose group_name == *group* and
--- whose rendered text contains *needle* (disambiguates group-by duplicates).
local function dash_row_in_group(child, group, needle)
  return child.lua_get(
    [[(function(group, needle)
    local bs = require("obsidian-tasks.render.init")._buffer_state[_G._dash_bufnr]
    for _, blk in ipairs(bs or {}) do
      for lnum, m in pairs(blk.line_map or {}) do
        if m.group_name == group and m.rendered_text and m.rendered_text:find(needle, 1, true) then
          return lnum
        end
      end
    end
    return -1
  end)(...)]],
    { group, needle }
  )
end

local function foldclosed(child, lnum_1)
  return child.lua_get("vim.fn.foldclosed(" .. lnum_1 .. ")")
end

-- A grouped source where the matched Parent (#alpha) drags in two children, so
-- in the #alpha group it is a LIT root with a FOLDABLE (>=2 descendant) subtree.
local GROUPED_SRC = {
  "- [ ] Parent #task #alpha",
  "  - [ ] Child one #task",
  "  - [ ] Child two #task",
  "- [ ] Other #task #beta",
}

-- ════════════════════════════════════════════════════════════════════════════
-- (1) closed subtree survives a GROUPED whole-dashboard rerender
-- ════════════════════════════════════════════════════════════════════════════

T["grouped rerender: a user-closed subtree stays closed after editing an unrelated task"] = function()
  local child = spawn_grouped(GROUPED_SRC)

  -- In the #alpha group, Parent is a LIT root with a 2-child foldable subtree.
  local parent0 = dash_row_in_group(child, "#alpha", "Parent")
  eq(parent0 >= 0, true, "lit Parent root in #alpha must exist")

  -- Close Parent's CHILDREN fold (first child = parent0 + 1, 1-indexed parent0+2).
  child.api.nvim_win_set_cursor(0, { parent0 + 2, 0 })
  child.type_keys("z", "c")
  local closed_before = foldclosed(child, parent0 + 2)
  eq(closed_before ~= -1, true, "Parent subtree must be closed before the rerender")

  -- Edit an UNRELATED task (the #beta "Other" root) by re-typing its line with a
  -- real `cc` — a MUTATE flush.  In a `group by` dashboard this drives the GROUPED
  -- whole-dashboard rerender (re-groups, syncs siblings).
  local other0 = dash_row_in_group(child, "#beta", "Other")
  eq(other0 >= 0, true, "the #beta Other root must exist")
  child.api.nvim_win_set_cursor(0, { other0 + 1, 0 })
  child.type_keys("c", "c", "- [x] Other #task #beta", "<Esc>")
  vim.loop.sleep(500)

  -- Find Parent fresh (rows may have shifted) and assert its subtree is STILL closed.
  local parent_after = dash_row_in_group(child, "#alpha", "Parent")
  eq(parent_after >= 0, true, "Parent must still render after the grouped rerender")
  local closed_after = foldclosed(child, parent_after + 2)
  eq(closed_after ~= -1, true, "the user-closed subtree must remain closed after a grouped rerender")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (2) regroup via tag edit keeps the closed subtree closed
-- ════════════════════════════════════════════════════════════════════════════

T["regroup: editing the root's tag moves it to a new group; its closed subtree stays closed"] = function()
  local child = spawn_grouped(GROUPED_SRC)

  local parent0 = dash_row_in_group(child, "#alpha", "Parent")
  eq(parent0 >= 0, true, "lit Parent root in #alpha must exist")

  -- Close Parent's children fold.
  child.api.nvim_win_set_cursor(0, { parent0 + 2, 0 })
  child.type_keys("z", "c")
  eq(foldclosed(child, parent0 + 2) ~= -1, true, "subtree must be closed before the regroup")

  -- Edit the Parent root line: replace #alpha with #gamma so it re-groups.  Use a
  -- real change-word over the tag via normal-mode :s on the cursor line is unsafe
  -- here (managed row), so type the edit with A (append) after deleting the tag.
  -- Simplest robust path: cursor on the root, enter insert at end, but the tag is
  -- mid-line.  Instead drive a structured tag swap by replacing the line through a
  -- real `cc` re-type of the whole task body.
  child.api.nvim_win_set_cursor(0, { parent0 + 1, 0 })
  child.type_keys("c", "c", "- [ ] Parent #task #gamma", "<Esc>")
  vim.loop.sleep(500)

  -- Source now carries #gamma on the parent.
  local src = child_src(child)
  local parent_line
  for _, l in ipairs(src) do
    if l:find("Parent", 1, true) then
      parent_line = l
    end
  end
  eq(
    parent_line ~= nil and parent_line:find("#gamma", 1, true) ~= nil,
    true,
    "parent tag must be #gamma now: " .. tostring(parent_line)
  )

  -- The Parent now lives in the #gamma group.  Locate it there and probe its fold.
  local parent_after = dash_row_in_group(child, "#gamma", "Parent")
  eq(parent_after >= 0, true, "Parent must render under the #gamma group after the tag edit")
  local closed_after = foldclosed(child, parent_after + 2)
  eq(closed_after ~= -1, true, "the closed subtree must remain closed at the new group position")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (3) default_folded=false: a manually-closed subtree persists across a rerender
-- ════════════════════════════════════════════════════════════════════════════

T["default_folded=false: a manually-closed subtree persists across a rerender"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "  - [ ] Child one #task",
    "  - [ ] Child two #task",
  }, false)

  local root0 = dash_row(child, "Root task")
  eq(root0 >= 0, true, "root must render")

  -- The fence is OPEN by default (default_folded=false).  Close the children fold.
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  eq(foldclosed(child, root0 + 2) ~= -1, true, "subtree must be closed before rerender")

  -- A plain rerender (e.g. BufWritePost / FocusGained path).
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._dash_bufnr, nil)")
  vim.loop.sleep(300)

  local root_after = dash_row(child, "Root task")
  -- Fence must remain OPEN (default_folded=false re-open gate must not fire on it).
  local fence_after = foldclosed(child, dash_row(child, "```tasks") + 1)
  eq(fence_after, -1, "the fence must stay OPEN with default_folded=false")
  -- Subtree must stay CLOSED (re-close logic has no default_folded gate).
  eq(foldclosed(child, root_after + 2) ~= -1, true, "manually-closed subtree must persist with default_folded=false")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (4) nested subtrees fold as a SINGLE level (children-only folds don't nest)
-- ════════════════════════════════════════════════════════════════════════════
-- BOTH the root and a nested child are matched.  PRODUCT DECISION (2026-05-31):
-- children-only subtree folds collapse the whole descendant range as ONE level;
-- they are intentionally NOT independently-nesting inner folds.  This test pins
-- that accepted behavior so a future change that (re)introduces true nesting is
-- a conscious, reviewed change rather than an accident.  See show-tree-bugfixes.

local function spawn_nested()
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
  child.lua([[(function()
    -- Root + nested child BOTH matched; the nested child has >=2 of its own
    -- descendants so it forms its own foldable subtree inside the root subtree.
    local content = {
      "- [ ] Root task #task",
      "  - [ ] Nested parent #task",
      "    - [ ] Deep one #task",
      "    - [ ] Deep two #task",
      "  - [ ] Tail child #task",
    }
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(content, src)
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
    -- Yield BOTH the root (line 1) and the nested parent (line 2) as matched.
    index.tasks_in = function()
      local seq = { { tp.parse(content[1]), src, 1 }, { tp.parse(content[2]), src, 2 } }
      local i = 0
      return function() i = i + 1; if seq[i] then return seq[i][1], seq[i][2], seq[i][3] end end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(b, 0, -1, false, { "```tasks", "show tree", "```" })
    -- Display BEFORE rendering so apply_folds creates the nested subtree folds.
    vim.api.nvim_set_current_buf(b)
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._dash_bufnr = b
    _G._src_path = src
  end)()]])
  return child
end

T["nested subtrees fold as a single level: closing the root collapses the whole descendant range"] = function()
  local child = spawn_nested()

  local nested0 = dash_row(child, "Nested parent")
  local root0 = dash_row(child, "Root task")
  eq(nested0 >= 0 and root0 >= 0, true, "root + nested parent must render")

  -- Closing the root's children fold (start = root0 + 2, the first child) collapses
  -- the ENTIRE descendant range as one level — the deep grandchildren included.
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  vim.loop.sleep(100)
  eq(foldclosed(child, root0 + 2) ~= -1, true, "the root children fold must close")

  -- Single-level fold: every descendant row (the nested parent, its deep children,
  -- the tail child) is hidden under the SAME fold — foldclosed() reports the same
  -- fold-start row for all of them, i.e. they are not independent inner folds.
  local fc_start = child.lua_get("vim.fn.foldclosed(" .. (root0 + 2) .. ")")
  for _, off in ipairs({ 2, 3, 4, 5 }) do
    eq(
      child.lua_get("vim.fn.foldclosed(" .. (root0 + off) .. ")"),
      fc_start,
      "descendant row " .. off .. " is collapsed under the SAME single-level fold"
    )
  end

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (5) zR / zM affect the fence fold AND all nested subtree folds
-- ════════════════════════════════════════════════════════════════════════════

T["zR/zM: global fold commands open/close the fence and all subtree folds"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "  - [ ] Child one #task",
    "  - [ ] Child two #task",
  }, true) -- default_folded=true so the fence starts CLOSED

  -- zR opens everything: fence + subtree become open.
  child.lua("vim.api.nvim_win_call(0, function() vim.cmd('normal! zR') end)")
  local fence0 = dash_row(child, "```tasks")
  local root0 = dash_row(child, "Root task")
  eq(foldclosed(child, fence0 + 1), -1, "zR must open the fence fold")
  eq(foldclosed(child, root0 + 2), -1, "zR must open the subtree fold")

  -- zM closes everything: the fence closes (so the root is hidden under it).
  child.lua("vim.api.nvim_win_call(0, function() vim.cmd('normal! zM') end)")
  eq(foldclosed(child, fence0 + 1) ~= -1, true, "zM must close the fence fold")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (6) group footer stays visible when the last subtree in the group is closed
-- ════════════════════════════════════════════════════════════════════════════

T["group footer: stays visible when the group's last subtree is closed"] = function()
  -- One group (#alpha) whose only/last matched root has a foldable subtree.  The
  -- footer ("─ N results ─") is a virt_lines extmark BELOW the last task, outside
  -- any fold.  Closing the subtree must not hide it.
  local child = spawn_grouped({
    "- [ ] Solo #task #alpha",
    "  - [ ] Child one #task",
    "  - [ ] Child two #task",
  })

  local root0 = dash_row_in_group(child, "#alpha", "Solo")
  eq(root0 >= 0, true, "lit Solo root in #alpha must exist")

  -- Close the subtree.
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  eq(foldclosed(child, root0 + 2) ~= -1, true, "subtree must be closed")

  -- Scan the rendered screen for a footer (the "results" virt line).  It must
  -- still be drawn while the subtree is collapsed.
  local footer_visible = child.lua_get([[(function()
    vim.o.lines = 24
    vim.o.columns = 80
    vim.cmd("redraw")
    for row = 1, 22 do
      local s = ""
      for col = 1, 78 do s = s .. (vim.fn.screenstring(row, col) or "") end
      if s:find("result", 1, true) then return true end
    end
    return false
  end)()]])
  eq(footer_visible, true, "the group footer virt line must remain visible when the last subtree is closed")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (7) EOF sentinel <CR> while a subtree is closed
-- ════════════════════════════════════════════════════════════════════════════

T["eof sentinel: <CR> on the sentinel adds a real newline and the closed subtree survives"] = function()
  -- File-backed dashboard so the EOF sentinel exists and :w round-trips.  Close a
  -- subtree, then press <CR> on the sentinel (release_sentinel_growth).  The
  -- closed subtree must survive whatever rerender the release triggers.
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
  ]],
    { cwd, deps_dir }
  )
  child.lua([[(function()
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile({
      "- [ ] Root task #task",
      "  - [ ] Child one #task",
      "  - [ ] Child two #task",
    }, src)
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "```tasks", "show tree", "```" }, note)
    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local tp = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function(p)
      if p == src then return nodes_mod.parse_lines(vim.fn.readfile(src)) end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function() i = i + 1; if i == 1 then return tp.parse(vim.fn.readfile(src)[1]), src, 1 end end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._dash_bufnr = b
    _G._note = note
    _G._src_path = src
  end)()]])

  local root0 = dash_row(child, "Root task")
  eq(root0 >= 0, true, "root must render in the file-backed dashboard")

  -- Close the subtree.
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  eq(foldclosed(child, root0 + 2) ~= -1, true, "subtree must be closed before the sentinel <CR>")

  -- The sentinel is the LAST buffer line (empty managed row at EOF).
  local last_line = child.lua_get("vim.api.nvim_buf_line_count(_G._dash_bufnr)")
  child.api.nvim_win_set_cursor(0, { last_line, 0 })
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(500)

  -- A real newline now exists at EOF (buffer grew by a real line).
  local lines = buflines(child)
  eq(lines[#lines], "", "a real trailing newline must exist after the sentinel <CR>")

  -- The closed subtree must survive.  Find the root fresh and probe its fold.
  local root_after = dash_row(child, "Root task")
  eq(root_after >= 0, true, "root must still render after the sentinel <CR>")
  eq(foldclosed(child, root_after + 2) ~= -1, true, "the closed subtree must survive the EOF sentinel <CR> / release")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (8) linger: a closed subtree toggled Done lingers with its fold STILL CLOSED
-- ════════════════════════════════════════════════════════════════════════════
-- D1 (2026-05-31): a MANUAL close stays closed until the USER opens it — across
-- EVERY edit-triggered rerender, the linger rerender included.  The linger toggle
-- here drives rerender_buffer, whose (src_path:src_line) subtree-fold capture/
-- restore re-closes the user-collapsed subtree even though the row is now dimmed.
-- We assert the root still renders dimmed AND its subtree fold survives CLOSED.

T["linger: a closed subtree toggled Done lingers with its fold STILL CLOSED (D1)"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "  - [ ] Child one #task",
    "  - [ ] Child two #task",
  }, false)
  -- Enable lingering on the live module.
  child.lua(
    "require('obsidian-tasks.render.init').configure({ default_folded = false, linger_on_filter_exit = true, dim_completed_tasks = true })"
  )

  local root0 = dash_row(child, "Root task")
  eq(root0 >= 0, true, "root must render")

  -- Close the subtree.
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  eq(foldclosed(child, root0 + 2) ~= -1, true, "subtree must be closed before the toggle")

  -- Toggle the root Done so it leaves the filter and lingers as a dimmed subtree.
  -- Drive via the public linger record + rerender (matches test_tree_render.lua),
  -- since a real <leader>tt also writes to the source file which is fine here.
  child.lua([[(function()
    local render = require("obsidian-tasks.render.init")
    local tp = require("obsidian-tasks.task.parse")
    render._record_pending_linger(_G._dash_bufnr, _G._src_path, 1, nil, tp.parse("- [x] Root task #task"))
    -- Make the live filter drop the root: tasks_in now yields nothing.
    local index = require("obsidian-tasks.index")
    index.tasks_in = function() return function() return nil end end
    render.rerender_buffer(_G._dash_bufnr, nil)
  end)()]])
  vim.loop.sleep(400)

  -- The lingered root still renders; its subtree fold survives CLOSED (D1).
  local root_after = dash_row(child, "Root task")
  eq(root_after >= 0, true, "lingered root must still render")
  local lingered = child.lua_get([[(function()
    local bs = require("obsidian-tasks.render.init")._buffer_state[_G._dash_bufnr]
    for _, blk in ipairs(bs or {}) do
      for _, m in pairs(blk.line_map or {}) do
        if m.linger then return true end
      end
    end
    return false
  end)()]])
  eq(lingered, true, "the root must be in a lingered (dimmed) state")
  eq(
    foldclosed(child, root_after + 2) ~= -1,
    true,
    "D1: a manually-closed subtree stays CLOSED across the linger rerender"
  )

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- (9) INVARIANT: the top-most lit item of a subtree can fold ALL its children
--     (lit or dim) iff it has >= 2 descendant rows.  Dim ancestor breadcrumbs
--     above it are never the fold owner.  The sole exception is a 1-descendant
--     subtree, which is intentionally not foldable (a one-line fold saves no
--     space).  See render/folds.lua:child_fold_range + query/tree.lua fold_group.
-- ════════════════════════════════════════════════════════════════════════════

T["invariant: top lit item with >=2 DIM descendants can fold them"] = function()
  -- spawn_tree matches ONLY the root, so the two children are DIM context — yet
  -- they ride under the root's fold_group, so the lit root folds them.
  local child = spawn_tree({
    "- [ ] Root task #task",
    "  - [ ] Child one #task",
    "  - [ ] Child two #task",
  })
  local root0 = dash_row(child, "Root task")
  eq(root0 >= 0, true, "lit root must render")
  -- A fold exists over the children ([root+1..last]); the first child is root0+2 (1-indexed).
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  vim.loop.sleep(80)
  eq(foldclosed(child, root0 + 2) ~= -1, true, "the lit root must be able to fold its (dim) children")
  child.type_keys("z", "o")
  vim.loop.sleep(50)
  eq(foldclosed(child, root0 + 2), -1, "zo reopens the children fold")
  child.stop()
end

T["invariant: top lit item with >=2 LIT descendants can fold them"] = function()
  -- spawn_grouped (ungrouped query) yields ALL tasks as matched, so the children
  -- are LIT.  The lit root still owns the single subtree fold over them.
  local child = spawn_grouped({
    "- [ ] Root task #task",
    "  - [ ] Child one #task",
    "  - [ ] Child two #task",
  }, { "```tasks", "show tree", "```" })
  local root0 = dash_row(child, "Root task")
  eq(root0 >= 0, true, "lit root must render")
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.type_keys("z", "c")
  vim.loop.sleep(80)
  eq(foldclosed(child, root0 + 2) ~= -1, true, "the lit root must be able to fold its lit children")
  child.stop()
end

T["invariant: top lit item with EXACTLY ONE descendant is NOT foldable"] = function()
  -- A single descendant row → child_fold_range returns nil → no fold is created.
  local child = spawn_tree({
    "- [ ] Root task #task",
    "  - [ ] Only child #task",
  })
  local root0 = dash_row(child, "Root task")
  eq(root0 >= 0, true, "lit root must render")
  -- No subtree fold exists: attempting to close one is a no-op (no fold found).
  child.api.nvim_win_set_cursor(0, { root0 + 2, 0 })
  child.lua("vim.api.nvim_win_call(0, function() pcall(vim.cmd, 'silent! normal! zc') end)")
  vim.loop.sleep(60)
  eq(foldclosed(child, root0 + 2), -1, "a single-descendant subtree must not be foldable")
  -- And the product agrees: child_fold_range over this subtree's range returns nil.
  local foldable = child.lua_get([[(function()
    local folds = require("obsidian-tasks.render.folds")
    local bs = require("obsidian-tasks.render.init")._buffer_state[_G._dash_bufnr]
    for _, blk in ipairs(bs or {}) do
      for _, sf in ipairs(blk.subtree_folds or {}) do
        if folds.child_fold_range(sf[1], sf[2]) ~= nil then return true end
      end
    end
    return false
  end)()]])
  eq(foldable, false, "child_fold_range must return nil for a 1-descendant subtree")
  child.stop()
end

return T
