-- tests/integration_real/test_real_tree_delete.lua
-- Phase 5d: real-mode delete-promote-orphans for `show tree` dashboards.
--
-- Genuine keypresses (nvim_input → real mode(), real InsertLeave/flush drain):
--   (a) dd a parent task with a surviving child bullet → child promotes up one
--       level in SOURCE (exact bytes).
--   (b) dd a parent with a multi-level subtree → whole subtree shifts up one
--       level, relative shape preserved.
--   (c) FOLDED dd on a CHILDREN-ONLY fold deletes all descendants, root survives.
--   (d) dd a leaf (no children) → plain literal delete (unchanged).
--   (e) dd a description bullet that has its own children → children promote.
--   (f) promoted description reaching top level is preserved in source (no crash).
--   (g) same-InsertLeave delete + insert does not corrupt unrelated lines.
--
-- See CLAUDE.md: real insert-mode tests must drive a child nvim + type_keys.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

--- Boot a child nvim with a real `show tree` dashboard backed by *content*.
--- The matched left-most task is ALWAYS source line 1 (the root); nodes_for
--- parses the LIVE file so deletes round-trip on rerender.
local function spawn_tree_dashboard(content)
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
    _G._warns = {}
    local log = require("obsidian-tasks.log")
    log.warn = function(msg) table.insert(_G._warns, tostring(msg)) end
    return src
  end)(...)]],
    { content }
  )

  return child
end

--- Boot a child nvim whose matched task is source line *matched_line* (1-based),
--- so its real ancestors render as DIM breadcrumb rows above the lit match.
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
    _G._warns = {}
    local log = require("obsidian-tasks.log")
    log.warn = function(msg) table.insert(_G._warns, tostring(msg)) end
    return src
  end)(...)]],
    { content, matched_line }
  )

  return child
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

--- Find the 0-indexed dashboard row whose text contains *needle*.
local function dash_row_with(child, needle)
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

-- ── (a) dd a parent task with a surviving child bullet → child promotes ──────

T["(a) dd parent task: surviving child bullet promotes up one level in source"] = function()
  -- Root has a child bullet.  The child bullet is a SEPARATE managed row (expanded
  -- dashboard), so dd on the root deletes ONLY the root line and the bullet must
  -- promote to top level in source.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - a child bullet",
  })

  local root_row = dash_row_with(child, "Root task")
  eq(root_row >= 0, true, "root row must exist")
  child.api.nvim_win_set_cursor(0, { root_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(400)

  local src = child_src(child)
  -- Root removed; the child bullet shifted up one level (4-space step → col 0).
  eq(#src, 1, "exactly one line should remain after promotion: " .. vim.inspect(src))
  eq(src[1], "- a child bullet", "child must promote to top level: " .. vim.inspect(src))

  child.stop()
end

-- ── (b) dd a parent with a multi-level subtree → whole subtree shifts up ──────

T["(b) dd parent: multi-level subtree shifts up uniformly, shape preserved"] = function()
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - [ ] Child task #task",
    "        - grandchild bullet",
    "    - second child bullet",
  })

  local root_row = dash_row_with(child, "Root task")
  child.api.nvim_win_set_cursor(0, { root_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(400)

  local src = child_src(child)
  -- Every descendant shifts left by the 4-space step; relative shape preserved.
  eq(src, {
    "- [ ] Child task #task",
    "    - grandchild bullet",
    "- second child bullet",
  }, "subtree must shift up one level, shape preserved: " .. vim.inspect(src))

  child.stop()
end

-- ── (c) FOLDED dd: children-only fold delete removes all descendants ─────────

T["(c) folded dd: closed children-fold delete removes all descendants, root survives"] = function()
  -- Subtree folds are CHILDREN-ONLY: the matched root stays visible + editable and
  -- is OUTSIDE the fold.  Closing the fold (from a child row) and `dd`-ing it
  -- removes every descendant in one stroke; the root line remains.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - [ ] Child task #task",
    "        - grandchild bullet",
    "    - trailing bullet",
  })

  -- Folds are applied only when the buffer is windowed; the harness renders
  -- BEFORE setting the buffer current, so re-render now (buffer is current) to
  -- build the per-subtree manual folds, then open all.
  child.lua([[
    require("obsidian-tasks.render.init").rerender_buffer(_G._dash_bufnr, nil)
    vim.cmd("normal! zR")
  ]])

  local root_row = dash_row_with(child, "Root task")
  eq(root_row >= 0, true, "root row must exist")
  -- The children fold starts at the FIRST CHILD (root_row + 1).  Close it from
  -- there, then dd the closed fold.
  child.api.nvim_win_set_cursor(0, { root_row + 2, 0 }) -- 1-indexed first child
  child.type_keys("z", "c")
  -- Confirm the fold actually closed (foldclosed != -1) before deleting.
  local closed = child.lua_get("vim.fn.foldclosed(" .. (root_row + 2) .. ")")
  eq(closed ~= -1, true, "children fold must be closed before dd: foldclosed=" .. tostring(closed))
  child.type_keys("d", "d")
  vim.loop.sleep(450)

  local src = child_src(child)
  -- Every descendant is gone; the root survives (nothing to promote — all of the
  -- root's children were in the deleted fold).
  eq(src, { "- [ ] Root task #task" }, "children-fold dd must leave only the root: " .. vim.inspect(src))

  child.stop()
end

-- ── (d) dd a leaf (no children) → plain literal delete (unchanged) ───────────

T["(d) dd a leaf child task: plain literal one-line delete"] = function()
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - [ ] Leaf child #task",
    "    - sibling bullet",
  })

  local leaf_row = dash_row_with(child, "Leaf child")
  eq(leaf_row >= 0, true, "leaf row must exist")
  child.api.nvim_win_set_cursor(0, { leaf_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(400)

  local src = child_src(child)
  -- Only the leaf line is gone; root + sibling untouched (no shape change).
  eq(src, {
    "- [ ] Root task #task",
    "    - sibling bullet",
  }, "leaf delete must remove exactly one line, nothing promoted: " .. vim.inspect(src))

  child.stop()
end

-- ── (e) dd a description bullet with its own children → children promote ─────

T["(e) dd a description bullet: its own child bullets promote up one level"] = function()
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - parent bullet",
    "        - child of bullet",
  })

  local parent_bullet_row = dash_row_with(child, "parent bullet")
  eq(parent_bullet_row >= 0, true, "parent bullet row must exist")
  child.api.nvim_win_set_cursor(0, { parent_bullet_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(400)

  local src = child_src(child)
  eq(src, {
    "- [ ] Root task #task",
    "    - child of bullet",
  }, "bullet's child must promote one level: " .. vim.inspect(src))

  child.stop()
end

-- ── (f) promoted description reaching top level is preserved in source ───────

T["(f) promoted description reaching top level survives in source (no crash)"] = function()
  -- Root with a single lonely description child.  dd the root: the description
  -- promotes to top level.  With no preceding top-level task it is a source-
  -- preserved orphan (accepted residual edge).  Must not crash; source keeps it.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - lonely note",
  })

  local root_row = dash_row_with(child, "Root task")
  child.api.nvim_win_set_cursor(0, { root_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(400)

  local src = child_src(child)
  eq(#src, 1, "promoted orphan description must remain in source: " .. vim.inspect(src))
  eq(src[1], "- lonely note", "description promoted to top level, preserved: " .. vim.inspect(src))

  -- No error notification beyond the accepted behavior.
  child.stop()
end

-- ── (g) same-InsertLeave delete + insert does not corrupt unrelated lines ────

T["(g) same-InsertLeave delete + insert: insert lands correctly, no corruption"] = function()
  -- Layout: root with two child tasks and an untouched sibling task that must NOT
  -- be corrupted.  In ONE InsertLeave we visual-select-change BOTH child rows
  -- (deleting two managed rows) and type a replacement task plus a NEW task — a
  -- genuine same-flush delete + insert.  The insert's anchor source_row would be
  -- STALE (pre-delete snapshot); the coordination re-locates it so the new lines
  -- land correctly and the sibling line is never overwritten.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "    - [ ] Child A #task",
    "    - [ ] Child B #task",
    "- [ ] Sibling untouched #task",
  })

  local child_a_row = dash_row_with(child, "Child A")
  eq(child_a_row >= 0, true, "Child A row must exist")
  -- Visual-line select Child A + Child B, `c` to delete both and enter insert,
  -- then type a replacement child and a brand-new child, all in one InsertLeave.
  child.api.nvim_win_set_cursor(0, { child_a_row + 1, 0 })
  child.type_keys("V", "j", "c", "    - [ ] Child R #task", "<CR>", "    - [ ] Child N #task", "<Esc>")
  vim.loop.sleep(500)

  local src = child_src(child)
  local joined = table.concat(src, "\n")
  -- Old children gone; replacement + new present; SIBLING line never corrupted.
  eq(joined:find("Child A", 1, true) == nil, true, "Child A must be deleted: " .. vim.inspect(src))
  eq(joined:find("Child B", 1, true) == nil, true, "Child B must be deleted: " .. vim.inspect(src))
  eq(joined:find("Root task", 1, true) ~= nil, true, "Root must survive: " .. vim.inspect(src))
  eq(joined:find("Child R", 1, true) ~= nil, true, "replacement child must be written: " .. vim.inspect(src))
  eq(joined:find("Child N", 1, true) ~= nil, true, "new child must be written: " .. vim.inspect(src))
  -- The CRITICAL assertion: the sibling line is byte-intact (not clobbered by a
  -- stale-anchor insert landing on its row).
  eq(
    joined:find("- [ ] Sibling untouched #task", 1, true) ~= nil,
    true,
    "sibling line must be byte-intact (no stale-anchor corruption): " .. vim.inspect(src)
  )

  child.stop()
end

-- ── (h) DELETE a DIM ancestor → its lit child promotes one level ──────────────
--
-- Phase 2 Deliverable 3: deleting a DIM ancestor row is a real source-line
-- delete that routes through delete-promote-orphans, exactly like deleting any
-- task.  Source: grandparent(0), parent(1), match(2); the MATCHED task is line 3
-- so the parent (line 2) renders DIM above the lit match.  dd on the dim parent
-- removes line 2 and PROMOTES the lit match up one level (4-space → 2-space), in
-- ONE undo entry.
T["(h) dd a DIM ancestor: its lit child promotes one level (one undo entry)"] = function()
  local child = spawn_tree_dashboard_matched({
    "- [ ] Grandparent #task",
    "  - [ ] Parent #task",
    "    - [ ] Match #task",
  }, 3)

  -- Dashboard rows: 3 DIM grandparent(0), 4 DIM parent(1), 5 LIT match(2).
  local parent_row = dash_row_with(child, "Parent")
  eq(parent_row >= 0, true, "dim parent row must exist")
  child.api.nvim_win_set_cursor(0, { parent_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(450)

  local src = child_src(child)
  -- The dim parent line is gone; the lit match promoted from depth 2 → depth 1
  -- (its 4-space indent shifts to 2 spaces) while the grandparent is untouched.
  eq(src, {
    "- [ ] Grandparent #task",
    "  - [ ] Match #task",
  }, "dim-ancestor delete promotes the lit child one level: " .. vim.inspect(src))

  -- Single undo entry for the whole reflow: the delete + the promotion
  -- replacement are recorded as ONE batch ring entry (one undo block), exactly
  -- like deleting any task — NOT one entry per reflow sub-edit.
  local ring_len = child.lua_get(
    "(function() local r = require('obsidian-tasks.cmd')._undo_ring[_G._dash_bufnr]; return r and #r or 0 end)()"
  )
  eq(ring_len, 1, "the dim-ancestor delete + promote must be ONE undo entry, got: " .. tostring(ring_len))
  local sub_count = child.lua_get(
    "(function() local r = require('obsidian-tasks.cmd')._undo_ring[_G._dash_bufnr]; local e = r and r[1]; local be = e and e.batch_edits; return be and #be or 0 end)()"
  )
  eq(
    sub_count >= 2,
    true,
    "the one entry batches both the delete and the promotion sub-edits, got: " .. tostring(sub_count)
  )

  child.stop()
end

return T
