-- tests/integration_real/test_real_tree_group_attr.lua
-- Phase 2 Deliverable 2: GROUP-ATTR INJECTION on INSERT in a `show tree`
-- dashboard, exercised through REAL keypresses (child nvim + type_keys).
--
-- Rule: on insert, inject the group's defining attribute (here a tag, via
-- `group by tags`) IFF the new row has NO MATCHED ancestor in its resolved parent
-- chain within this group — i.e. it would not otherwise be pulled into the group
-- by subtree-drag:
--   • top-level insert (no parent)                       => inject;
--   • insert whose ancestor chain is only DIM breadcrumbs => inject;
--   • insert beneath a MATCHED task (or its lit descendants) => do NOT inject.
--
-- Layout exploits per-group induced-forest dedup: Parent carries #beta, Child
-- carries #alpha.  In group "alpha" the Child is a LIT root and the Parent is a
-- DIM ancestor (matched only in group "beta").  In group "beta" the Parent is a
-- LIT root that drags the Child in.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

--- Boot a child nvim with a real `show tree` + `group by tags` dashboard.  The
--- two source tasks (Parent #beta at depth 0, Child #alpha at depth 1) are both
--- yielded by tasks_in so the real query groups them by tag.
--- @param content      string[]   source markdown lines
--- @param query_lines  string[]?  dashboard fence body (defaults to the standard
---                                `show tree` + `group by tags` query).  Passed so
---                                a test can add a `sort by …` clause to control
---                                the per-group emission ORDER (needed to position
---                                a separate matched root BETWEEN a deduped dim
---                                ancestor and its lit subtree).
local function spawn_grouped_dashboard(content, query_lines)
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
    -- Yield BOTH source tasks so `group by tags` buckets them by their own tags.
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      lines = ok and lines or src_content
      local emit = {}
      for ln, text in ipairs(lines) do
        local t = task_parse.parse(text)
        if t then
          emit[#emit + 1] = { t, src, ln }
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
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, query_lines)
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    -- Disable autoindent so each typed line's indentation is LITERAL.
    vim.bo[bufnr].autoindent = false
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { { content, query_lines } }
  )

  return child
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

--- 0-indexed dashboard row of the managed task whose group_name == *group* and
--- whose rendered text contains *needle*.  Disambiguates the per-group appearances
--- of the same source task (group-by-tags duplicates each task per tag).
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

local SRC = {
  "- [ ] Parent #task #beta",
  "  - [ ] Child #task #alpha",
}

-- ── (a) insert beneath a MATCHED task → NO injection (already dragged in) ──────

T["(a) insert under a LIT matched task does NOT inject the group tag"] = function()
  local child = spawn_grouped_dashboard(SRC)

  -- In group "#beta" the Parent is a LIT matched root.  Insert an indented child
  -- task under it: it is dragged into "#beta" by subtree-drag → no #beta inject.
  local parent_row = dash_row_in_group(child, "#beta", "Parent")
  eq(parent_row >= 0, true, "lit Parent row in the #beta group must exist")

  child.api.nvim_win_set_cursor(0, { parent_row + 1, 0 })
  -- A 2-space-indented checkbox → child task at depth 1, parented to the lit Parent.
  child.type_keys("o", "  - [ ] under matched", "<Esc>")
  vim.loop.sleep(400)

  local src = child_src(child)
  local joined = table.concat(src, "\n")
  local line = nil
  for _, l in ipairs(src) do
    if l:find("under matched", 1, true) then
      line = l
    end
  end
  eq(line ~= nil, true, "inserted line must be present: " .. joined)
  -- Inserted under a matched task → NOT injected with the group tag.
  eq(line:find("#beta", 1, true) == nil, true, "must NOT inject #beta under a matched task: [" .. tostring(line) .. "]")
  eq(line:find("#alpha", 1, true) == nil, true, "must NOT inject #alpha either: [" .. tostring(line) .. "]")

  child.stop()
end

-- ── (b) insert under a DIM ancestor → INJECT (would not otherwise be dragged) ──

T["(b) insert under a DIM ancestor injects the group tag"] = function()
  local child = spawn_grouped_dashboard(SRC)

  -- In group "#alpha" the Child is the LIT root and the Parent renders DIM above
  -- it.  Target the DIM Parent breadcrumb of the #alpha group precisely.
  local dim_parent_row = dash_row_in_group(child, "#alpha", "Parent")
  eq(dim_parent_row >= 0, true, "dim Parent breadcrumb in the #alpha group must exist")
  local alpha_child_row = dash_row_in_group(child, "#alpha", "Child")
  eq(alpha_child_row == dim_parent_row + 1, true, "lit Child must render directly under its dim Parent")

  -- Insert a child task UNDER the dim Parent (depth 1).  Its ancestor chain is
  -- only the DIM Parent (no matched ancestor in group "alpha") → inject #alpha.
  child.api.nvim_win_set_cursor(0, { dim_parent_row + 1, 0 })
  child.type_keys("o", "  - [ ] under dim", "<Esc>")
  vim.loop.sleep(400)

  local src = child_src(child)
  local line = nil
  for _, l in ipairs(src) do
    if l:find("under dim", 1, true) then
      line = l
    end
  end
  eq(line ~= nil, true, "inserted line must be present: " .. table.concat(src, "\n"))
  -- Under a DIM ancestor (no matched ancestor in this group) → inject the group tag.
  eq(line:find("#alpha", 1, true) ~= nil, true, "must inject #alpha under a dim ancestor: [" .. tostring(line) .. "]")

  child.stop()
end

-- ── (c) top-level insert → INJECT (no parent at all) ──────────────────────────

T["(c) top-level insert injects the group tag"] = function()
  local child = spawn_grouped_dashboard(SRC)

  -- Insert a TOP-LEVEL task (col 0) in the "#beta" group, below the lit Parent.
  -- A top-level insert has no parent chain → inject the group's tag (#beta).
  local parent_row = dash_row_in_group(child, "#beta", "Parent")
  eq(parent_row >= 0, true, "lit Parent row in the #beta group must exist")

  child.api.nvim_win_set_cursor(0, { parent_row + 1, 0 })
  child.type_keys("o", "- [ ] top level", "<Esc>")
  vim.loop.sleep(400)

  local src = child_src(child)
  local line = nil
  for _, l in ipairs(src) do
    if l:find("top level", 1, true) then
      line = l
    end
  end
  eq(line ~= nil, true, "inserted line must be present: " .. table.concat(src, "\n"))
  -- Top-level insert in the beta group → inject #beta.
  eq(line:find("#beta", 1, true) ~= nil, true, "must inject #beta on a top-level insert: [" .. tostring(line) .. "]")
  -- It is a true top-level item (no leading indent).
  eq(line:match("^%s") == nil, true, "top-level insert must have no leading indent: [" .. tostring(line) .. "]")

  child.stop()
end

-- ── (d) insert under a DRAGGED LIT DESCENDANT → NO injection (P3 D4) ───────────
-- The matched root (Parent #beta) drags in a lit Child AND a lit Grandchild (both
-- matched==false, two levels below the matched root).  An insert under the lit
-- GRANDCHILD must NOT inject the group tag: it is already dragged into #beta by
-- subtree-drag.  This is the case the OLD depth-walk gate could mis-decide; the
-- parent_line walk climbs Grandchild → Child → Parent (matched) and correctly
-- suppresses the injection.

local SRC_DEEP = {
  "- [ ] Parent #task #beta",
  "  - [ ] Child #task",
  "    - [ ] Grandchild #task",
}

T["(d) insert under a dragged LIT descendant does NOT inject the group tag"] = function()
  local child = spawn_grouped_dashboard(SRC_DEEP)

  -- In group "#beta" the Parent is the LIT matched root; Child + Grandchild are
  -- lit descendants (matched==false) dragged in.  Target the lit Grandchild.
  local gc_row = dash_row_in_group(child, "#beta", "Grandchild")
  eq(gc_row >= 0, true, "lit Grandchild row in the #beta group must exist")

  -- Insert a task UNDER the lit Grandchild (depth 3, 6-space indent).  Its parent
  -- chain (Grandchild → Child → Parent) hits the MATCHED Parent → NO injection.
  child.api.nvim_win_set_cursor(0, { gc_row + 1, 0 })
  child.type_keys("o", "      - [ ] under descendant", "<Esc>")
  vim.loop.sleep(400)

  local src = child_src(child)
  local joined = table.concat(src, "\n")
  local line = nil
  for _, l in ipairs(src) do
    if l:find("under descendant", 1, true) then
      line = l
    end
  end
  eq(line ~= nil, true, "inserted line must be present: " .. joined)
  -- Dragged in beneath a matched root → must NOT inject the group tag.
  eq(
    line:find("#beta", 1, true) == nil,
    true,
    "must NOT inject #beta under a dragged lit descendant: [" .. tostring(line) .. "]"
  )

  child.stop()
end

-- ── (e) DISCRIMINATING lock: TWO matched roots share depths → depth-walk crosses ─
-- Locks `has_matched_ancestor_in_chain` to the parent_line walk.  Case (d) is a
-- single chain where the OLD depth-walk and the NEW parent_line walk AGREE, so it
-- would not catch a revert.  Here ONE #beta group holds TWO matched roots whose
-- breadcrumb chains share depths.  The dim ancestor `DimRoot` is shared by the
-- LIT root `Apple` and by `Cherry`, so it is emitted ONCE (with Apple) and Cherry's
-- breadcrumb run SKIPS it (dedup gap).  `sort by description` orders the #beta
-- group Apple, Banana, Cherry — so the SEPARATE matched root `Banana` (depth 0)
-- is emitted BETWEEN `DimRoot` (depth 0) and Cherry's dim `DimChild` (depth 1):
--
--   group #beta rendered rows (top→bottom):
--     DimRoot   (d0, DIM,     line 1)   ← Cherry's real depth-0 ancestor
--     Apple     (d1, MATCHED, line 2)
--     Banana    (d0, MATCHED, line 5)   ← UNRELATED sibling, NEARER than DimRoot
--     DimChild  (d1, DIM,     line 3)   ← Cherry's real depth-1 ancestor (insert parent)
--     Cherry    (d2, MATCHED, line 4)
--
-- Insert under DimChild (a dim ancestor; its real chain DimChild→DimRoot is ALL
-- DIM → MUST inject #beta).  The OLD walk from DimChild(d1) seeks the nearest
-- depth-0 row ABOVE and lands on Banana (matched) instead of DimRoot → wrongly
-- decides "matched ancestor present" → SUPPRESSES injection (the bug).  The
-- parent_line walk climbs DimChild→DimRoot (dim)→nil → correctly INJECTS.  So this
-- test PASSES under parent_line and FAILS under the depth-walk.

local SRC_SHARED = {
  "- [ ] DimRoot #task", -- line 1: dim shared ancestor (no #beta)
  "  - [ ] Apple #task #beta", -- line 2: matched root, child of DimRoot
  "  - [ ] DimChild #task", -- line 3: dim ancestor of Cherry (sibling of Apple)
  "    - [ ] Cherry #task #beta", -- line 4: matched root, child of DimChild
  "- [ ] Banana #task #beta", -- line 5: matched root, SEPARATE top-level tree
}

T["(e) two matched roots sharing depths: depth-walk crosses to an unrelated sibling; parent_line is correct"] = function()
  -- `sort by description` makes the #beta group emit Apple, Banana, Cherry so the
  -- depth-0 matched Banana lands between DimRoot and DimChild.
  local child = spawn_grouped_dashboard(SRC_SHARED, {
    "```tasks",
    "show tree",
    "group by tags",
    "sort by description",
    "```",
  })

  -- Target the DIM DimChild breadcrumb in the #beta group.
  local dimchild_row = dash_row_in_group(child, "#beta", "DimChild")
  eq(dimchild_row >= 0, true, "dim DimChild breadcrumb in the #beta group must exist")

  -- Sanity: in the #beta group, the matched Banana root renders ABOVE DimChild
  -- (the dedup-gap interleaving the depth-walk trips over).
  local banana_row = dash_row_in_group(child, "#beta", "Banana")
  eq(banana_row >= 0 and banana_row < dimchild_row, true, "matched Banana must render above DimChild in #beta")

  -- Insert a task UNDER the dim DimChild (depth 2, 4-space indent).  Its real
  -- parent chain (DimChild → DimRoot) is ALL DIM → MUST inject #beta.
  child.api.nvim_win_set_cursor(0, { dimchild_row + 1, 0 })
  child.type_keys("o", "    - [ ] under dimchild", "<Esc>")
  vim.loop.sleep(400)

  local src = child_src(child)
  local joined = table.concat(src, "\n")
  local line = nil
  for _, l in ipairs(src) do
    if l:find("under dimchild", 1, true) then
      line = l
    end
  end
  eq(line ~= nil, true, "inserted line must be present: " .. joined)
  -- The real chain is all-dim → MUST inject #beta.  The OLD depth-walk crosses to
  -- the unrelated matched Banana and WRONGLY suppresses this injection.
  eq(
    line:find("#beta", 1, true) ~= nil,
    true,
    "MUST inject #beta under a dim ancestor even when a matched sibling shares depths: [" .. tostring(line) .. "]"
  )

  child.stop()
end

return T
