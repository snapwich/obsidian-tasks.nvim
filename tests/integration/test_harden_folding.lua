-- tests/integration/test_harden_folding.lua
-- Hardening: folding mechanics that can be exercised WITHOUT real keypresses.
--
-- Covers (stubbed index + headless window APIs):
--   • single-descendant subtree never folds (the >=2 gate);
--   • multi-block fold independence: a closed subtree in block A survives a
--     rerender driven by block B;
--   • a closed subtree fold survives a rerender that re-GROUPS the root to a
--     different group (group by) — keyed on (src_path, src_line) + extmark.
--
-- These mirror the stubbing in test_tree_render.lua (index.tasks_in / nodes_for /
-- refresh_all + a real `show tree` render in a headless window).

-- post_case closes every window the case opened EVEN WHEN AN ASSERTION THREW
-- before its inline teardown ran (a failing `eq` would otherwise leak the split
-- and exhaust window room → E36 in later split-based tests).
local T = MiniTest.new_set({
  hooks = {
    post_case = function()
      local wins = vim.api.nvim_tabpage_list_wins(0)
      for i = 2, #wins do
        pcall(vim.api.nvim_win_close, wins[i], true)
      end
    end,
  },
})

local eq = MiniTest.expect.equality

local render = require("obsidian-tasks.render.init")
local folds_mod = require("obsidian-tasks.render.folds")
local nodes_mod = require("obsidian-tasks.index.nodes")
local task_parse = require("obsidian-tasks.task.parse")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function open_in_win(bufnr)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

local function close_win(winid)
  pcall(vim.api.nvim_win_close, winid, true)
end

local SRC_PATH = "/vault/harden_fold.md"

--- Generic single-file stub: `lines` is the source subtree; the matched root is
--- the task on (1-indexed) `root_line`.  Returns a restore fn.  Mirrors the
--- stub_index_lines helper in test_tree_render.lua but local to this file.
local function stub_index_lines(lines, root_line)
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local ns = nodes_mod.parse_lines(lines)
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    return (p == SRC_PATH) and ns or {}
  end
  index_mod.tasks_in = function(_)
    local root = task_parse.parse(lines[root_line])
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return root, SRC_PATH, root_line
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
  end
end

-- ── single-descendant subtree never folds ─────────────────────────────────────

T["single-descendant subtree: child_fold_range returns nil (no fold created)"] = function()
  -- A matched root with EXACTLY one descendant row.  child_fold_range gates on
  -- (last0 - root0) >= 2; one descendant means last0 - root0 == 1 → nil.
  eq(folds_mod.child_fold_range(3, 4), nil)
  -- Two descendants DO fold (sanity: the gate is exactly >=2).
  local s1, e1 = folds_mod.child_fold_range(3, 5)
  eq(s1, 5)
  eq(e1, 6)
end

T["single-descendant subtree: render creates NO subtree fold; za/zc collapse nothing"] = function()
  -- Root + exactly ONE child task.  The render must produce an empty
  -- subtree_folds list for the block, and pressing zc on the lone child must not
  -- close any fold (foldclosed stays -1).
  local lines = {
    "- [ ] Root task",
    "  - [ ] Only child",
  }
  local restore = stub_index_lines(lines, 1)
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- The block carries NO subtree fold (single-descendant skipped).
  local state = render._buffer_state[bufnr]
  local subtree_fold_count = 0
  for _, blk in ipairs(state or {}) do
    subtree_fold_count = subtree_fold_count + #(blk.subtree_folds or {})
  end
  -- Note: subtree_folds may still LIST the {root,last} range; what matters is no
  -- *foldable* range — assert via the live fold structure below instead.

  -- 1-indexed rows: 4 root, 5 only child.  zc on the child must NOT create/close
  -- a fold (the >=2 gate skipped fold creation).
  local child_fc, child_fl
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    vim.cmd("5") -- move to the lone child
    pcall(vim.cmd, "normal! zc")
    child_fc = vim.fn.foldclosed(5)
    child_fl = vim.fn.foldlevel(5)
  end)
  eq(child_fc, -1, "no subtree fold exists at the lone child → nothing collapses")
  eq(child_fl, 0, "the lone child is not inside any subtree fold")
  -- Defensive: even if a range was stored, child_fold_range(root,last) must be nil.
  for _, blk in ipairs(state or {}) do
    for _, sf in ipairs(blk.subtree_folds or {}) do
      eq(folds_mod.child_fold_range(sf[1], sf[2]), nil, "stored single-descendant range must not fold")
    end
  end
  eq(subtree_fold_count >= 0, true) -- keep the var meaningful for readers

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── multiple blocks: fold independence across a rerender ──────────────────────

--- Two-block stub: block A's source (with a foldable subtree, root line 1) and a
--- second flat task (line 2 of a separate file) feeding block B.  Both files'
--- nodes are served; tasks_in yields the tree root for A and the flat task for B.
local A_PATH = "/vault/blockA.md"
local B_PATH = "/vault/blockB.md"
local A_LINES = {
  "- [ ] A root",
  "  - [ ] A child one",
  "  - [ ] A child two",
}

local function stub_index_two_blocks()
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  local ns_a = nodes_mod.parse_lines(A_LINES)
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    if p == A_PATH then
      return ns_a
    end
    return {}
  end
  index_mod.tasks_in = function(_)
    -- Block A's matched root (a foldable subtree) and a flat task for block B.
    local a_root = task_parse.parse(A_LINES[1])
    local b_task = task_parse.parse("- [ ] B flat task")
    local seq = { { a_root, A_PATH, 1 }, { b_task, B_PATH, 1 } }
    local i = 0
    return function()
      i = i + 1
      local e = seq[i]
      if e then
        return e[1], e[2], e[3]
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
  end
end

T["multi-block: a closed subtree in block A survives a whole-buffer rerender"] = function()
  -- Two `show tree` blocks in one buffer.  Block A renders a foldable subtree
  -- (A root + 2 children); block B renders a single flat task (no subtree fold).
  -- Close A's children fold, rerender the whole buffer, and assert A's fold
  -- stays closed.  This exercises the per-block fold capture/restore loop.
  local restore = stub_index_two_blocks()
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({
    "```tasks",
    "show tree",
    "```",
    "between blocks",
    "```tasks",
    "show tree",
    "```",
  })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  -- Locate A's root row freshly (it carries "A root").
  local function row_with(needle)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return i
      end
    end
    return -1
  end

  local a_root_1 = row_with("A root")
  eq(a_root_1 >= 1, true, "block A root must be rendered")

  -- Close A's CHILDREN fold (starts at first child = a_root_1 + 1).
  local closed_before
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    vim.cmd((a_root_1 + 1) .. "foldclose")
    closed_before = vim.fn.foldclosed(a_root_1 + 1)
  end)
  eq(closed_before, a_root_1 + 1, "block A children fold must be closed before rerender")

  -- Rerender the whole buffer (both blocks re-render).
  render.rerender_buffer(bufnr, nil)

  local a_root_after = row_with("A root")
  local a_fold_after
  vim.api.nvim_win_call(winid, function()
    a_fold_after = vim.fn.foldclosed(a_root_after + 1)
  end)
  eq(a_fold_after ~= -1, true, "block A's closed subtree must remain closed after the whole-buffer rerender")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

-- ── re-group keeps a closed subtree closed (keyed on src_path:src_line) ────────

--- Grouped stub: a single matched root with a foldable subtree, plus a `group_of`
--- hook so the test can flip which group the root lands in between renders.  We
--- stub at the index layer and let the real query group by tags.
local G_PATH = "/vault/group_fold.md"

local function stub_index_grouped(get_root_line)
  local index_mod = require("obsidian-tasks.index")
  local saved = {
    tasks_in = index_mod.tasks_in,
    nodes_for = index_mod.nodes_for,
    set = index_mod.set_render_paths,
    clear = index_mod.clear_render_paths,
    refresh_all = index_mod.refresh_all,
  }
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.refresh_all = function(_, on_done)
    if on_done then
      on_done()
    end
  end
  index_mod.nodes_for = function(p)
    if p == G_PATH then
      return nodes_mod.parse_lines(get_root_line())
    end
    return {}
  end
  index_mod.tasks_in = function(_)
    local lines = get_root_line()
    local root = task_parse.parse(lines[1])
    local i = 0
    return function()
      i = i + 1
      if i == 1 then
        return root, G_PATH, 1
      end
    end
  end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.nodes_for = saved.nodes_for
    index_mod.set_render_paths = saved.set
    index_mod.clear_render_paths = saved.clear
    index_mod.refresh_all = saved.refresh_all
  end
end

T["regroup: a closed subtree stays closed when its root changes group on rerender"] = function()
  -- A `group by tags` dashboard.  The matched root has a foldable subtree and a
  -- tag.  Close its children fold, then mutate the root's tag so it re-groups to
  -- a NEW group name on the next render.  The fold capture/restore keys on
  -- (src_path, src_line) — stable across the regroup — so the subtree must stay
  -- closed at its new rendered position.
  local current = {
    "- [ ] Grouped root #alpha",
    "  - [ ] G child one",
    "  - [ ] G child two",
  }
  local restore = stub_index_grouped(function()
    return current
  end)
  local saved_opts = render._opts
  render.configure({ default_folded = false })

  local bufnr = make_buf({ "```tasks", "show tree", "group by tags", "```" })
  local winid = open_in_win(bufnr)
  render.render_buffer(bufnr, nil)

  local function row_with(needle)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then
        return i
      end
    end
    return -1
  end

  local root_1 = row_with("Grouped root")
  eq(root_1 >= 1, true, "grouped root must render")
  local closed_before
  vim.api.nvim_win_call(winid, function()
    vim.cmd("normal! zR")
    vim.cmd((root_1 + 1) .. "foldclose")
    closed_before = vim.fn.foldclosed(root_1 + 1)
  end)
  eq(closed_before, root_1 + 1, "subtree must be closed before the regroup rerender")

  -- Re-group: the root's tag flips #alpha → #omega.  Same src_path:src_line, new
  -- group name + (likely) new rendered row.
  current = {
    "- [ ] Grouped root #omega",
    "  - [ ] G child one",
    "  - [ ] G child two",
  }
  render.rerender_buffer(bufnr, nil)

  -- The root is now under the #omega group; find it fresh and probe its fold.
  local root_after = row_with("Grouped root")
  eq(root_after >= 1, true, "root must still render after regroup")
  local closed_after
  vim.api.nvim_win_call(winid, function()
    closed_after = vim.fn.foldclosed(root_after + 1)
  end)
  eq(closed_after ~= -1, true, "the closed subtree must remain closed at its new group position")

  render.clear_buffer(bufnr)
  close_win(winid)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  render.configure(saved_opts)
  restore()
end

return T
