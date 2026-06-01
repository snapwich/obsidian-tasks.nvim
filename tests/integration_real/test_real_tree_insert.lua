-- tests/integration_real/test_real_tree_insert.lua
-- Phase 5b: single-line free-form INSERT classifier + placement in a `show tree`
-- dashboard, exercised through REAL keypresses (child nvim + type_keys → mode()
-- is genuinely 'i', vim.schedule fires between keystrokes, the InsertLeave drain
-- is the real autocmd).
--
-- Matrix (each is a SINGLE-line insert via o + type + <Esc>):
--   (a) col-0 bare text after a top-level task → new sibling TOP-LEVEL TASK.
--   (b) col-0 "- note" after a top-level task → TOP-LEVEL DESCRIPTION at col 0
--       (Phase 2 literal depth: NO promotion under the task, NO checkbox).
--   (c) two col-0 "- note" lines (separate inserts) → both top-level bullets.
--   (d) an indented "- [ ] sub" typed under a task → child TASK at that depth.
--   (e) an indented "- note" below top level → description at literal clamped depth.
--   (f) a level-skipping indent clamps to parent + 1.
--   (h) "*"/"+" typed marker is preserved on a top-level col-0 bullet.
--   DIM ancestor context (matched task is a CHILD line → real ancestors render
--   DIM above it at their TRUE absolute depths):
--   (j) o on a lit match → sibling at the match's depth.
--   (k) indent one more → child of the lit match.
--   (l) outdent to col 0 → a true TOP-LEVEL task (NOT under the dim grandparent).
--
-- Each test asserts the EXACT source bytes (indent + marker + kind) after insert.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

--- Boot a child nvim with a real `show tree` dashboard backed by *content*.
--- The matched left-most task is line 1; the whole file parses as the subtree.
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
    return src
  end)(...)]],
    { content }
  )

  return child
end

--- Boot a child nvim whose matched task is source line *matched_line* (1-based),
--- so its real ancestors (lines above it on the parent chain) render as DIM
--- breadcrumb rows at their TRUE absolute depths above the lit match.
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

local function child_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

-- Buffer rows (0-indexed): 0 fence, 1 query, 2 fence, then the rendered subtree.
local ROOT_ROW = 3

-- ── (a) col-0 bare text after a top-level task → new sibling TOP-LEVEL TASK ────

T["(a) col-0 bare text after top task → new sibling top-level task (existing behavior)"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  -- o below the root task, type bare text, Esc.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "another root", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  -- Bare text col-0 → repaired into a well-formed TOP-LEVEL task (no indent).
  eq(src[2], "- [ ] another root", "col-0 bare text → top-level sibling task: [" .. tostring(src[2]) .. "]")

  child.stop()
end

-- ── (b) col-0 "- note" after a top-level task → TOP-LEVEL description ──────────

T["(b) col-0 '- note' after top task → top-level description bullet (NO promotion, NO checkbox)"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "- a note", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  -- Phase 2 literal depth: a col-0 bullet is a TRUE TOP-LEVEL item (no indent,
  -- no promotion), marker preserved, NO checkbox forced.
  eq(src[2], "- a note", "col-0 description → top-level bullet at col 0: [" .. tostring(src[2]) .. "]")
  eq(src[2]:find("%[") == nil, true, "description must NOT contain a checkbox")

  child.stop()
end

-- ── (c) col-0 "- note" below a RENDERED child stays top-level (no scan-up) ─────

T["(c) col-0 '- note' below a rendered child → top-level (NOT promoted/attached)"] = function()
  -- Root with a rendered child bullet.  Typing a col-0 bullet below the child must
  -- NOT scan up and attach to the root — it is a TRUE TOP-LEVEL item at col 0.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "  - existing child",
  })

  -- Dashboard rows: 3 root, 4 child.  o below the child inherits the child's
  -- 2-space indent via 'autoindent'; <C-u> clears it so the bullet is genuinely
  -- col 0.  It must NOT scan up and attach to the root.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 2, 0 })
  child.type_keys("o", "<C-u>", "- topnote", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 3, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  eq(src[2], "  - existing child", "existing child must be untouched")
  -- The new bullet is top-level (col 0), NOT a depth-1 child of the root.
  eq(src[3], "- topnote", "col-0 bullet stays top-level, no scan-up promotion: [" .. tostring(src[3]) .. "]")

  child.stop()
end

-- ── (d) indented "- [ ] sub" typed under a task → child TASK at that depth ─────

T["(d) indented '- [ ] sub' under a task → child task at depth 1"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  -- Type a 2-space-indented checkbox line.
  child.type_keys("o", "  - [ ] sub task", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  -- A typed checkbox at depth 1 stays a TASK at that depth (child of root).
  eq(src[2], "  - [ ] sub task", "indented checkbox → child task at depth 1: [" .. tostring(src[2]) .. "]")

  child.stop()
end

-- ── (e) indented "- note" below top level → description at literal clamped depth

T["(e) indented '- note' below top level → description at literal depth 2"] = function()
  -- Source: root (0), child task (2-space). Dashboard rows: 3 root, 4 child.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "  - [ ] Child task #task",
  })

  local CHILD_ROW = ROOT_ROW + 1
  -- Confirm the child rendered at depth 1 (2-space dashboard indent).
  eq(child_line(child, CHILD_ROW):sub(1, #"  - [ ] Child"), "  - [ ] Child")

  -- o below the child task, type a 4-space-indented bullet (depth 2).
  child.api.nvim_win_set_cursor(0, { CHILD_ROW + 1, 0 })
  child.type_keys("o", "    - deep note", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 3, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  eq(src[2], "  - [ ] Child task #task", "child must be untouched")
  -- Literal depth 2 (no promotion): bullet sits one level under the child task,
  -- i.e. 4-space source indent.
  eq(src[3], "    - deep note", "below-top description keeps literal depth 2: [" .. tostring(src[3]) .. "]")

  child.stop()
end

-- ── (f) level-skipping indent clamps to parent + 1 ────────────────────────────

T["(f) level-skipping indent clamps to anchor depth + 1"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  -- Type an 8-space-indented checkbox (depth 4) below the depth-0 root.  Must
  -- clamp to depth 1 (2-space source indent).
  child.type_keys("o", "        - [ ] way deep", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  eq(src[2], "  - [ ] way deep", "level-skip clamps to depth 1 (2-space indent): [" .. tostring(src[2]) .. "]")

  child.stop()
end

-- ── (h) "*"/"+" typed marker is preserved on a top-level col-0 bullet ──────────

T["(h) col-0 '* note' preserves the '*' marker (top-level bullet)"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "* star note", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[2], "* star note", "'*' marker preserved on a top-level col-0 bullet: [" .. tostring(src[2]) .. "]")

  child.stop()
end

T["(h2) col-0 '+ note' preserves the '+' marker (top-level bullet)"] = function()
  local child = spawn_tree_dashboard({ "- [ ] Root task #task" })

  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "+ plus note", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  eq(#src, 2, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[2], "+ plus note", "'+' marker preserved on a top-level col-0 bullet: [" .. tostring(src[2]) .. "]")

  child.stop()
end

-- ── (i) AUTOINDENT pin: o under an INDENTED anchor keeps the literal depth ────
--
-- This PINS the spec-correct "literal below top level" rule against a future
-- pass wrongly "fixing" the typed indentation.  With 'autoindent' ON, pressing
-- `o` under a depth-1 child task inherits the anchor's 2-space indent; typing a
-- bullet (without re-typing indentation) yields a line at literal depth 1.  Per
-- §7 that bullet keeps its LITERAL depth (no promotion to top-level): it is
-- written at a 2-space source indent (a child of the top task / sibling of the
-- anchor), NEVER stripped to col 0.  The typed indentation — including editor
-- autoindent — is intentional and load-bearing; the classifier/insert call must
-- NOT strip it.
T["(i) autoindent: o under an indented anchor → literal depth (not promoted/stripped)"] = function()
  -- Source: root (0), child task (2-space). Dashboard rows: 3 root, 4 child.
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "  - [ ] Child task #task",
  })

  -- Enable autoindent so `o` inherits the anchor's leading whitespace (the real
  -- editor behavior this pin guards against being stripped).
  child.lua("vim.bo[_G._dash_bufnr].autoindent = true")

  local CHILD_ROW = ROOT_ROW + 1
  -- o under the depth-1 child task; type ONLY the bullet (no manual indent) so
  -- the 2-space indent comes purely from autoindent inheriting the child's.
  child.api.nvim_win_set_cursor(0, { CHILD_ROW + 1, 0 })
  child.type_keys("o", "- inherited note", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 3, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root untouched")
  eq(src[2], "  - [ ] Child task #task", "child untouched")
  -- Literal depth 1 (autoindent inherited): a 2-space source indent.  The pin:
  -- it is NOT promoted/stripped to col 0.
  eq(src[3], "  - inherited note", "autoindent depth kept literal, NOT stripped: [" .. tostring(src[3]) .. "]")
  eq(src[3]:match("^  "), "  ", "must keep its inherited 2-space indent (not col 0)")

  child.stop()
end

-- ── (m) first-child insert lands BEFORE existing children (Bug 2) ─────────────
--
-- Regression: a new line typed as a child of a task that ALREADY has children
-- must become the FIRST child (immediately after the parent), not the LAST.
-- Previously insert_after_anchor always walked past the parent's whole subtree,
-- dropping the new child after every existing one.

T["(m) first child of a task with existing children → inserted FIRST, not last"] = function()
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "  - [ ] existing child one",
    "  - [ ] existing child two",
  })

  -- Dashboard rows: 3 root, 4 child one, 5 child two.  `o` on the ROOT opens a
  -- line between the root and its first child; type a depth-1 child bullet.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "  - [ ] new first child", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 4, "exactly one line inserted: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root untouched")
  eq(src[2], "  - [ ] new first child", "new child is FIRST, immediately after parent: " .. vim.inspect(src))
  eq(src[3], "  - [ ] existing child one", "existing child one pushed down")
  eq(src[4], "  - [ ] existing child two", "existing child two pushed down")

  child.stop()
end

-- ── (n) inserted child renders IN PLACE in the dashboard, not dumped last ─────
--
-- Regression (user-reported): a child inserted FIRST wrote to source correctly
-- but the DASHBOARD dumped it at the END of the subtree.  Cause was the layout
-- emit engine buffering EVERY dim row as an ancestor breadcrumb — a dim
-- DESCENDANT (a non-matching child, fold_group > 0) was deferred and flushed
-- after all lit siblings instead of rendering in source order.

T["(n) first child renders IN PLACE in the dashboard (dim descendant not dumped last)"] = function()
  local child = spawn_tree_dashboard({
    "- [ ] Root task #task",
    "  - [ ] child one #task",
    "  - [ ] child two #task",
  })

  -- `o` on the ROOT, type a depth-1 bullet → first child.
  child.api.nvim_win_set_cursor(0, { ROOT_ROW + 1, 0 })
  child.type_keys("o", "  - first note", "<Esc>")
  vim.loop.sleep(350)

  -- Source: bullet is the FIRST child.
  local src = child_src(child)
  eq(src[2], "  - first note", "source: bullet is FIRST child: " .. vim.inspect(src))

  -- Dashboard rows: 3 root, 4 first note, 5 child one, 6 child two.  The bullet
  -- must render BETWEEN the root and child one — NOT dumped last.
  eq(
    child_line(child, ROOT_ROW + 1):find("first note", 1, true) ~= nil,
    true,
    "dashboard: inserted bullet is FIRST child (row 4), not last: " .. tostring(child_line(child, ROOT_ROW + 1))
  )
  eq(
    child_line(child, ROOT_ROW + 3):find("child two", 1, true) ~= nil,
    true,
    "child two stays last: " .. tostring(child_line(child, ROOT_ROW + 3))
  )

  child.stop()
end

-- ── DIM-ANCESTOR context: matched task is a CHILD; ancestors render DIM above ──
--
-- Source (2-space indent per level so depth maps cleanly):
--   line 1  - [ ] Grandparent #task          (depth 0)
--   line 2    - [ ] Parent #task             (depth 1)
--   line 3      - [ ] Match #task            (depth 2, the MATCHED task)
-- Dashboard rows: 3 DIM grandparent(0), 4 DIM parent(1), 5 LIT match(2).
local DIM_SRC = {
  "- [ ] Grandparent #task",
  "  - [ ] Parent #task",
  "    - [ ] Match #task",
}

-- ── (j) o on the lit match → SIBLING at the match's depth (2) ─────────────────

T["(j) o on lit match → sibling at the match's depth (autoindent inherits)"] = function()
  local child = spawn_tree_dashboard_matched(DIM_SRC, 3)
  child.lua("vim.bo[_G._dash_bufnr].autoindent = true")

  local MATCH_ROW = 5 -- 0-indexed: 3 grandparent, 4 parent, 5 match
  eq(child_line(child, MATCH_ROW):find("Match", 1, true) ~= nil, true, "lit match must render at row 5")

  -- o on the lit match; autoindent inherits the match's 4-space dashboard indent
  -- (depth 2).  Type only the body → a sibling task at depth 2.
  child.api.nvim_win_set_cursor(0, { MATCH_ROW + 1, 0 })
  child.type_keys("o", "- [ ] sibling", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(src[1], "- [ ] Grandparent #task", "grandparent untouched")
  eq(src[2], "  - [ ] Parent #task", "parent untouched")
  eq(src[3], "    - [ ] Match #task", "match untouched")
  -- Sibling of the match: 4-space source indent (depth 2, child of the dim parent).
  eq(src[4], "    - [ ] sibling", "o on lit match → sibling at depth 2: [" .. tostring(src[4]) .. "]")

  child.stop()
end

-- ── (k) indent one more → CHILD of the lit match (depth 3) ─────────────────────

T["(k) indent one more under lit match → child at depth 3"] = function()
  local child = spawn_tree_dashboard_matched(DIM_SRC, 3)

  local MATCH_ROW = 5
  -- Type a 6-space-indented checkbox (depth 3) below the lit match (depth 2).
  child.api.nvim_win_set_cursor(0, { MATCH_ROW + 1, 0 })
  child.type_keys("o", "      - [ ] deeper", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(src[3], "    - [ ] Match #task", "match untouched")
  -- Child of the match: 6-space source indent (depth 3).
  eq(src[4], "      - [ ] deeper", "indent one more → child of lit match at depth 3: [" .. tostring(src[4]) .. "]")

  child.stop()
end

-- ── (l) SAFETY-REVIEW: outdent to col 0 → TRUE TOP-LEVEL, NOT under grandparent ─

T["(l) col-0 note below the lit subtree → top-level task, NOT under dim grandparent"] = function()
  local child = spawn_tree_dashboard_matched(DIM_SRC, 3)

  local MATCH_ROW = 5
  -- Type a genuinely outdented col-0 line below the lit match.  The dashboard
  -- buffer has 'autoindent' ON, so `o` inherits the match's 4-space indent; the
  -- user clears it with <C-u> (delete-to-start-of-insert) to genuinely outdent to
  -- col 0.  The result must be a TRUE TOP-LEVEL task — NOT attached under the dim
  -- grandparent (depth 0) as a depth-1 child (the old promotion misfire).
  child.api.nvim_win_set_cursor(0, { MATCH_ROW + 1, 0 })
  child.type_keys("o", "<C-u>", "outdented top", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(src[1], "- [ ] Grandparent #task", "grandparent untouched")
  eq(src[2], "  - [ ] Parent #task", "parent untouched")
  eq(src[3], "    - [ ] Match #task", "match untouched")
  -- The col-0 line is a TRUE TOP-LEVEL task at col 0 (no indent), NOT a 2-space
  -- child dragged under the dim grandparent.
  eq(
    src[4],
    "- [ ] outdented top",
    "col-0 line → top-level task, NOT under dim grandparent: [" .. tostring(src[4]) .. "]"
  )
  eq(src[4]:match("^%s"), nil, "must have NO leading indent (true top level)")

  child.stop()
end

return T
