-- tests/unit/test_cursor_follow.lua
-- Unit tests for render/cursor.lua — the cursor follows the TASK across a
-- rerender instead of staying on the row number.
--
-- These are NOT insert-mode tests.  They drive cursor.save / cursor.restore
-- directly against a real scratch buffer in a real split window, with two
-- stubs standing in for the render pass:
--
--   • package.loaded["obsidian-tasks.render.draw"] — is_render_line answers
--     from a fixed 0-indexed row table, so save() gets a stable identity;
--   • render._buffer_state[bufnr] — a hand-written list of block states.
--     The test sets the OLD line_map, calls save(), replaces it with the NEW
--     line_map, then calls restore().  That is exactly the sequence
--     rerender_buffer performs around its clear+render pass.
--
-- Row indexing is the main trap: line_map keys and the return of
-- M._rank_candidates are 0-INDEXED buffer rows, while snapshot.row and
-- nvim_win_get_cursor are 1-INDEXED.  Every expectation below states which.

local T = MiniTest.new_set()

local cursor = require("obsidian-tasks.render.cursor")

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

-- ── Fixture ──────────────────────────────────────────────────────────────────

local P = "/vault/notes.md"

-- A rendered dashboard: fence, six task rows, closing fence.
-- 0-indexed rows 1..6 carry the tasks; row 3 is where the cursor starts.
local LINES = {
  "```tasks", -- row0 0
  "- [ ] alpha", -- row0 1
  "- [ ] bravo", -- row0 2
  "- [ ] charlie", -- row0 3
  "- [ ] delta", -- row0 4
  "- [ ] echo", -- row0 5
  "- [ ] foxtrot", -- row0 6
  "```", -- row0 7
}

--- Build one line_map entry for the task at source line *src_line*.
--- @param src_line integer  1-indexed line in the source note
--- @param extra table|nil   extra fields (group_name, dim, ...)
--- @return table
local function meta(src_line, extra)
  local m = { src_path = P, src_line = src_line, src_hash = "0000000000000000" }
  for k, v in pairs(extra or {}) do
    m[k] = v
  end
  return m
end

-- ── Harness ──────────────────────────────────────────────────────────────────

--- Open *lines* in a scratch buffer shown by a fresh split window, cursor at
--- (row, col).  A real window is required: save() calls winline/winsaveview
--- inside it and restore() calls winrestview.
--- @param lines string[]
--- @param row integer  1-indexed
--- @param col integer  0-indexed
--- @return integer bufnr, integer win
local function open_buf(lines, row, col)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.cmd("split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.api.nvim_win_set_cursor(win, { row, col })
  return bufnr, win
end

--- Close the test window and drop the orchestrator state we planted.
local function cleanup(bufnr, win)
  require("obsidian-tasks.render")._buffer_state[bufnr] = nil
  pcall(vim.api.nvim_win_close, win, true)
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

--- Install a draw stub whose is_render_line answers from *by_row* (0-indexed
--- keys).  Returns the restore function.
--- @param by_row table  { [lnum0] = { src_path, src_line } }
--- @return fun()
local function install_draw(by_row)
  local orig = package.loaded["obsidian-tasks.render.draw"]
  package.loaded["obsidian-tasks.render.draw"] = {
    is_render_line = function(_bufnr, lnum0)
      return by_row[lnum0]
    end,
  }
  return function()
    package.loaded["obsidian-tasks.render.draw"] = orig
  end
end

--- Replace render._buffer_state[bufnr] with a single block holding *line_map*.
--- @param bufnr integer
--- @param line_map table  0-indexed row keys
local function set_state(bufnr, line_map)
  require("obsidian-tasks.render")._buffer_state[bufnr] = { { line_map = line_map } }
end

--- Run *fn* with the follow gate pinned to *enabled*, then put the opt back.
--- The gate is read at runtime inside restore(), and an absent key means ON,
--- so pinning it keeps these tests independent of any config a previous test
--- installed through render.configure().
--- @param enabled boolean
--- @param fn fun()
local function with_follow(enabled, fn)
  local render = require("obsidian-tasks.render")
  local prev = render._opts.follow_cursor_on_rerender
  render._opts.follow_cursor_on_rerender = enabled
  local ok, err = pcall(fn)
  render._opts.follow_cursor_on_rerender = prev
  if not ok then
    error(err)
  end
end

-- The old render: four tasks at 0-indexed rows 1..4, one group.
local function old_line_map(group)
  return {
    [1] = meta(10, { group_name = group }),
    [2] = meta(20, { group_name = group }),
    [3] = meta(30, { group_name = group }),
    [4] = meta(40, { group_name = group }),
  }
end

-- ── 1. Task moves up ─────────────────────────────────────────────────────────

T["follow: task moved up — cursor lands on the task, not the row"] = function()
  local bufnr, win = open_buf(LINES, 4, 0) -- row0 3 = task 30
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  -- The snapshot must carry the identity; without it every case below would
  -- silently exercise the legacy path instead.
  eq(snap[win].id.src_path, P)
  eq(snap[win].id.src_line, 30)
  eq(snap[win].row, 4, "snapshot.row is 1-indexed")

  -- New render: task 30 moved from 0-indexed row 3 up to row 1.
  set_state(bufnr, {
    [1] = meta(30, { group_name = "Group A" }),
    [2] = meta(10, { group_name = "Group A" }),
    [3] = meta(20, { group_name = "Group A" }),
    [4] = meta(40, { group_name = "Group A" }),
  })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  eq(vim.api.nvim_win_get_cursor(win)[1], 2, "0-indexed row 1 → 1-indexed cursor row 2")
  cleanup(bufnr, win)
end

-- ── 2. Task moves down ───────────────────────────────────────────────────────

T["follow: task moved down — cursor lands on the task, not the row"] = function()
  local bufnr, win = open_buf(LINES, 4, 0)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  -- New render: task 30 moved from 0-indexed row 3 down to row 5.
  set_state(bufnr, {
    [1] = meta(10),
    [2] = meta(20),
    [3] = meta(40),
    [5] = meta(30),
  })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  eq(vim.api.nvim_win_get_cursor(win)[1], 6, "0-indexed row 5 → 1-indexed cursor row 6")
  cleanup(bufnr, win)
end

-- ── 3. Duplicate identity, one lit and one dim ───────────────────────────────
-- Tree mode renders a matched task as a LIT fold owner plus DIM breadcrumb
-- copies.  Rule 1 must prefer the lit copy even when the dim copy is nearer to
-- the saved row — hence the dim copy sits 1 row away and the lit copy 3 rows.

T["follow: duplicate identity — the lit copy wins over the nearer dim copy"] = function()
  local bufnr, win = open_buf(LINES, 4, 0)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  set_state(bufnr, {
    [2] = meta(30, { dim = true }), -- breadcrumb copy, distance 1
    [6] = meta(30), -- lit copy, distance 3
  })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  eq(vim.api.nvim_win_get_cursor(win)[1], 7, "the lit copy at 0-indexed row 6 wins")
  cleanup(bufnr, win)
end

-- ── 4. Duplicate identity in two groups ──────────────────────────────────────
-- A task that matches several group keys renders once per group.  Rule 2 must
-- prefer the saved group even when the other group's copy is nearer.

T["follow: duplicate identity — the saved group_name wins over the nearer copy"] = function()
  local bufnr, win = open_buf(LINES, 4, 0)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  -- The cursor row carries group "Beta", so the snapshot hint is "Beta".
  set_state(bufnr, old_line_map("Beta"))

  local snap = cursor.save(bufnr)
  restore_draw()

  eq(snap[win].group_name, "Beta", "the hint is accepted because the identities match")

  set_state(bufnr, {
    [1] = meta(30, { group_name = "Alpha" }), -- distance 2
    [6] = meta(30, { group_name = "Beta" }), -- distance 3
  })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  eq(vim.api.nvim_win_get_cursor(win)[1], 7, "the Beta copy at 0-indexed row 6 wins")
  cleanup(bufnr, win)
end

-- ── 5. Duplicate identity with no group hint ─────────────────────────────────
-- Rule 2 is skipped when the snapshot has no group_name, so rule 3 decides.

T["follow: duplicate identity without a group hint — the nearest row wins"] = function()
  local bufnr, win = open_buf(LINES, 4, 0)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map(nil)) -- no group_name anywhere

  local snap = cursor.save(bufnr)
  restore_draw()

  eq(snap[win].group_name, nil)

  set_state(bufnr, {
    [1] = meta(30), -- distance 2 from the saved 0-indexed row 3
    [6] = meta(30), -- distance 3
  })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  eq(vim.api.nvim_win_get_cursor(win)[1], 2, "the nearest copy at 0-indexed row 1 wins")
  cleanup(bufnr, win)
end

-- ── 6. Task gone — land on the neighbor ──────────────────────────────────────
-- The task left the filter set or was deleted.  The cursor must land on the
-- task that came after it, which is the familiar vim `dd` behavior.

T["follow: task gone — the cursor lands on the saved neighbor"] = function()
  local bufnr, win = open_buf(LINES, 4, 0)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  -- The neighbor is the lowest 0-indexed row above 3 that names a task: row 4.
  eq(snap[win].neighbor_id.src_line, 40)

  -- New render: task 30 is gone; task 40 sits at 0-indexed row 2.
  set_state(bufnr, {
    [1] = meta(10),
    [2] = meta(40),
    [3] = meta(20),
  })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  eq(vim.api.nvim_win_get_cursor(win)[1], 3, "task 40 at 0-indexed row 2 → cursor row 3")
  cleanup(bufnr, win)
end

-- ── 7. Task and neighbor both gone — legacy clamp ────────────────────────────

T["fallback: task and neighbor both gone — the legacy row/column clamp runs"] = function()
  local bufnr, win = open_buf(LINES, 4, 2)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  -- The rerender emptied the dashboard: neither 30 nor 40 renders any more,
  -- and the buffer is now shorter than the saved row.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "abcdef", "```" })
  set_state(bufnr, { [1] = meta(10) })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  local pos = vim.api.nvim_win_get_cursor(win)
  eq(pos[1], 3, "saved row 4 clamped to the new line count of 3")
  eq(pos[2], 2, "saved column 2 fits inside the 3-byte line ```")
  cleanup(bufnr, win)
end

-- ── 8. Feature off — legacy clamp ────────────────────────────────────────────
-- Same reorder as case 1.  With the gate off the cursor must stay on row 4,
-- which is the old behavior the option preserves.

T["fallback: follow_cursor_on_rerender = false — the legacy clamp runs"] = function()
  local bufnr, win = open_buf(LINES, 4, 2)
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  set_state(bufnr, {
    [1] = meta(30),
    [2] = meta(10),
    [3] = meta(20),
    [4] = meta(40),
  })
  with_follow(false, function()
    cursor.restore(bufnr, snap)
  end)

  local pos = vim.api.nvim_win_get_cursor(win)
  eq(pos[1], 4, "the row is kept even though task 30 moved to 0-indexed row 1")
  eq(pos[2], 2)
  cleanup(bufnr, win)
end

-- ── 9. Column longer than the new line ───────────────────────────────────────
-- The followed task shrank.  follow_restore clamps the column to the byte
-- length of the new line; Neovim then clamps a normal-mode cursor to the last
-- byte, so the result is #line - 1.

T["follow: column past the end of the new line clamps"] = function()
  local bufnr, win = open_buf(LINES, 4, 12) -- "- [ ] charlie" is 13 bytes
  local restore_draw = install_draw({ [3] = { src_path = P, src_line = 30 } })
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  eq(snap[win].col, 12)

  -- The task moved to 0-indexed row 1 and its rendered text got much shorter.
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "- [ ] ab" }) -- 8 bytes
  set_state(bufnr, { [1] = meta(30) })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  local pos = vim.api.nvim_win_get_cursor(win)
  eq(pos[1], 2)
  eq(pos[2], 7, "column 12 clamped to the 8-byte line, then to its last byte")
  cleanup(bufnr, win)
end

-- ── 10. Cursor not on a rendered row ─────────────────────────────────────────
-- Prose, a fence line, or freshly typed text: is_render_line returns nil, so
-- the snapshot has no identity and the legacy clamp must run.  This is the
-- wanted result for render/edit_insert.lua's no-anchor fallback.

T["fallback: cursor not on a rendered task row — no identity, legacy clamp runs"] = function()
  local bufnr, win = open_buf(LINES, 8, 1) -- the closing fence
  local restore_draw = install_draw({}) -- nothing is a render line
  set_state(bufnr, old_line_map("Group A"))

  local snap = cursor.save(bufnr)
  restore_draw()

  eq(snap[win].id, nil)

  set_state(bufnr, { [1] = meta(30) })
  with_follow(true, function()
    cursor.restore(bufnr, snap)
  end)

  local pos = vim.api.nvim_win_get_cursor(win)
  eq(pos[1], 8)
  eq(pos[2], 1)
  cleanup(bufnr, win)
end

-- ── 11. Hidden buffer ────────────────────────────────────────────────────────
-- cmd/init.lua refreshes other dashboards that no window shows.  win_findbuf
-- returns nothing, so save gives an empty snapshot and restore is a no-op.

T["save: buffer shown by no window returns an empty snapshot"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, LINES)

  local snap = cursor.save(bufnr)
  eq(next(snap), nil, "no window ⇒ no entries")

  MiniTest.expect.no_error(function()
    cursor.restore(bufnr, snap)
  end)

  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

return T
