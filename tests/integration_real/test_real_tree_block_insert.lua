-- tests/integration_real/test_real_tree_block_insert.lua
-- Phase 5c: MULTI-LINE block insert reconciler in a `show tree` dashboard,
-- exercised through REAL keypresses (child nvim + type_keys → mode() is
-- genuinely 'i', vim.schedule fires between keystrokes, the InsertLeave drain is
-- the real autocmd).  A block is typed in ONE insert session (o + lines joined
-- by <CR> + <Esc>) so all the new rows are reconciled together.
--
-- Matrix:
--   (A) clean nested paste under a top-level task: root + child + grandchild
--       keep their relative shape on disk.
--   (B) a col-0 description root promotes under the nearest top-level task and
--       CARRIES its sub-block (the child shifts uniformly with it).
--   (C) a mixed block: a task root stays top-level, a later description root
--       promotes under the anchor.
--   (D) an outdent back to col-0 mid-block re-attaches to a fresh top-level root.
--   (E) a level-skip within the block clamps to parent + 1.
--   (F) a 1-line "block" equals the P5b single-line output byte-for-byte.
--
-- Each test asserts the EXACT source bytes after the block insert.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

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
    -- Disable autoindent so each typed line's indentation is LITERAL (exactly the
    -- leading spaces this test sends).  These tests drive the reconciler with
    -- precise per-line indentation; the autoindent-inheritance behavior is pinned
    -- separately in test_real_tree_insert.lua case (i).
    vim.bo[bufnr].autoindent = false
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { content }
  )

  return child
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

-- Buffer rows (0-indexed): 0 fence, 1 query, 2 fence, then the rendered subtree.
local ROOT_ROW = 3

-- ── (A) clean nested paste: root + child + grandchild keep relative shape ─────

T["(A) nested block under top task keeps root/child/grandchild shape"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  -- One insert session: o, then three lines joined by <CR>, then <Esc>.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "- [ ] root", "<CR>", "  - [ ] child", "<CR>", "    - grandchild", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 4, "three lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  -- root is a col-0 task → top-level sibling.
  eq(src[2], "- [ ] root", "root → top-level task: [" .. tostring(src[2]) .. "]")
  -- child nests one level under root (2-space indent).
  eq(src[3], "  - [ ] child", "child nests under root: [" .. tostring(src[3]) .. "]")
  -- grandchild nests one level under child (4-space indent), description.
  eq(src[4], "    - grandchild", "grandchild nests under child: [" .. tostring(src[4]) .. "]")

  child.stop()
end

-- ── (B) col-0 description root → top-level, carries its sub-block ─────────────

T["(B) description root stays top-level and carries its child (no promotion)"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  -- A col-0 description root with a nested child, in one insert session.
  child.type_keys("o", "- note", "<CR>", "  - subnote", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 3, "two lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  -- Phase 2 literal depth: the col-0 description is a TRUE TOP-LEVEL item (col 0,
  -- no promotion).  Its sub-block rides along one level deeper (2 spaces).
  eq(src[2], "- note", "description root stays top-level at col 0: [" .. tostring(src[2]) .. "]")
  eq(src[3], "  - subnote", "sub-block rides along, one level deeper: [" .. tostring(src[3]) .. "]")
  eq(src[2]:find("%[") == nil, true, "description root must NOT contain a checkbox")

  child.stop()
end

-- ── (C) mixed block: both roots stay top-level (Phase 2: no promotion) ────────

T["(C) mixed block: task root + later description root both stay top-level"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "- [ ] task root", "<CR>", "- desc root", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 3, "two lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  -- The task root is a col-0 task → top-level sibling.
  eq(src[2], "- [ ] task root", "task root stays top-level: [" .. tostring(src[2]) .. "]")
  -- Phase 2: the col-0 description is ALSO a true top-level item (no promotion).
  eq(src[3], "- desc root", "description root stays top-level at col 0: [" .. tostring(src[3]) .. "]")

  child.stop()
end

-- ── (D) outdent back to col-0 mid-block re-attaches to a fresh root ───────────

T["(D) outdent back to col-0 mid-block starts a fresh top-level root"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "- [ ] a", "<CR>", "  - [ ] b", "<CR>", "- [ ] c", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 4, "three lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  eq(src[2], "- [ ] a", "a → top-level: [" .. tostring(src[2]) .. "]")
  eq(src[3], "  - [ ] b", "b nests under a: [" .. tostring(src[3]) .. "]")
  -- c outdented back to col-0 is a FRESH top-level task, NOT a child of b.
  eq(src[4], "- [ ] c", "c outdents back to top-level: [" .. tostring(src[4]) .. "]")

  child.stop()
end

-- ── (E) level-skip within the block clamps ───────────────────────────────────

T["(E) level-skip within the block clamps to parent + 1"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  -- root then an 8-space-indented (depth 4) line: must clamp to root + 1.
  child.type_keys("o", "- [ ] root", "<CR>", "        - [ ] deep", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 3, "two lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  eq(src[2], "- [ ] root", "root → top-level: [" .. tostring(src[2]) .. "]")
  -- deep clamps to within-block depth 1 (2-space indent), child of root.
  eq(src[3], "  - [ ] deep", "level-skip clamps to root + 1: [" .. tostring(src[3]) .. "]")

  child.stop()
end

-- ── (F) a 1-line "block" equals the P5b single-line output byte-for-byte ──────

T["(F) single-line block equals P5b single-line output"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  -- One line, no <CR>: this is the degenerate 1-line block.
  child.type_keys("o", "- a note", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  -- Identical to test_real_tree_insert (b): col-0 description → top-level bullet.
  eq(src[2], "- a note", "1-line block == P5b single-line output (top-level): [" .. tostring(src[2]) .. "]")

  child.stop()
end

-- ── (G) indented paste nests ANCHOR-RELATIVE (like typing the same lines) ─────

T["(G) indented paste root nests under the anchor (anchor-relative, not re-rooted)"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  -- A subtree copied from elsewhere arrives with a leading indent on every line.
  -- We reproduce it via a genuine INSERT-MODE register paste (o, then <C-r>a) so
  -- the whole block is reconciled in ONE InsertLeave (the block path).  The
  -- shallowest line carries a 2-space indent → it resolves ANCHOR-RELATIVE, just
  -- as if the same line were typed: a child of the top-level anchor (depth 1).
  -- The subtree keeps its relative shape, shifted one level deeper under the
  -- anchor.  (This is the corrected behavior: block insert == sequential
  -- single-line inserts; an explicitly col-0 root would instead stay top-level.)
  child.lua([[
    vim.fn.setreg("a", "  - [ ] root\n    - [ ] child\n      - grandchild")
  ]])
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "<C-r>a", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 4, "three lines pasted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  -- root carried a 2-space indent → child of the anchor (one level deeper).
  eq(src[2], "  - [ ] root", "indented paste root nests under the anchor: [" .. tostring(src[2]) .. "]")
  eq(src[3], "    - [ ] child", "child one level deeper than root: [" .. tostring(src[3]) .. "]")
  eq(src[4], "      - grandchild", "grandchild two levels deeper than root: [" .. tostring(src[4]) .. "]")

  child.stop()
end

-- ── (H) REGRESSION: `o` a child then its OWN child keeps the child under the ──
-- ── anchor (was: first child re-rooted to top-level, grandchild nested under) ─

T["(H) o-insert a child then a grandchild: child stays under the anchor"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  -- The exact reported bug: in ONE insert session, type a child (indented one
  -- level under the top-level anchor) and then its own child (indented two
  -- levels).  The block reconciler must place the FIRST line as a child of the
  -- anchor and the SECOND as that child's child — NOT push the first child to
  -- top-level and nest the grandchild under it.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "  - [ ] child", "<CR>", "    - [ ] grandchild", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 3, "two lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "anchor untouched")
  eq(src[2], "  - [ ] child", "child nests UNDER the anchor (not top-level): [" .. tostring(src[2]) .. "]")
  eq(src[3], "    - [ ] grandchild", "grandchild nests under the child: [" .. tostring(src[3]) .. "]")

  child.stop()
end

-- ── (I) same regression one level down: child + grandchild under a depth-1 ────
-- ── anchor land at the anchor's child / grandchild depth ──────────────────────

T["(I) o-insert child + grandchild under a below-top anchor nests correctly"] = function()
  -- Anchor subtree: a top task with a depth-1 child; insert under the child.
  local child = spawn_tree_dashboard({ "- [ ] Root task #task", "  - [ ] existing child" })

  -- The depth-1 "existing child" renders at buffer row ROOT_ROW + 1 (0-indexed
  -- ROOT_ROW is the root).  Insert a deeper child + grandchild under it.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 2, 0 })
  child.type_keys("o", "    - [ ] deep", "<CR>", "      - [ ] deeper", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 4, "two lines inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "top anchor untouched")
  eq(src[2], "  - [ ] existing child", "existing child untouched")
  eq(src[3], "    - [ ] deep", "deep nests under existing child (depth 2): [" .. tostring(src[3]) .. "]")
  eq(src[4], "      - [ ] deeper", "deeper nests under deep (depth 3): [" .. tostring(src[4]) .. "]")

  child.stop()
end

return T
