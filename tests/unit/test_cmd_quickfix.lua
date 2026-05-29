-- tests/unit/test_cmd_quickfix.lua
-- Integration tests for cmd/quickfix.lua.
-- Drives a REAL render/draw (no stubbing of extmark/managed/setqflist), then
-- dispatches the `quickfix` subcommand and asserts vim.fn.getqflist().
-- All vim.api calls are valid because mini.test runs in headless Neovim.

local T = MiniTest.new_set()

-- ── module handles ────────────────────────────────────────────────────────────

local draw_mod = require("obsidian-tasks.render.draw")
local managed = require("obsidian-tasks.render.managed")
local cmd = require("obsidian-tasks.cmd")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Create a scratch buffer pre-populated with lines, name it after a real path,
--- and make it the current buffer (so quickfix.lua's nvim_get_current_buf and
--- cursor reads operate on it).
--- @param lines string[]  raw lines (1-indexed)
--- @return integer  bufnr
local function make_current_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

--- Build a fence_range for lines at indices first..last (0-indexed).
local function fence(first, last)
  return { first, last }
end

--- Build a "task" layout record.  Mirrors the fields draw.lua reads off each
--- layout entry (kind/text/src_path/src_line/src_hash, plus optional linger/dim).
--- @param text     string   rendered task line
--- @param src_path string   absolute source-file path
--- @param src_line integer  1-indexed source row
--- @param opts     table?   { linger = bool, source_text = string }
local function task_line(text, src_path, src_line, opts)
  opts = opts or {}
  return {
    kind = "task",
    text = text,
    src_path = src_path,
    src_line = src_line,
    src_hash = vim.fn.sha256(text):sub(1, 16),
    -- source_text becomes managed.task_text verbatim (else strip_wikilink(text)).
    source_text = opts.source_text or text,
    -- Lingered rows carry both flags in real layout records (see layout.lua
    -- build_linger_line); quickfix keys off `linger` only.
    linger = opts.linger or nil,
    dim = opts.linger or nil,
  }
end

--- Dispatch the `quickfix` subcommand for a single cursor line L (1-indexed),
--- positioning the cursor first so quickfix.lua's win-cursor fallback also works.
--- @param bufnr integer
--- @param L integer  1-indexed line
local function run_quickfix(bufnr, L)
  -- Position the real cursor too (quickfix.lua falls back to it when no range).
  local win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(win) == bufnr then
    vim.api.nvim_win_set_cursor(win, { L, 0 })
  end
  cmd.dispatch({ fargs = { "quickfix" }, line1 = L, line2 = L })
end

--- getqflist with title.
local function qf()
  return vim.fn.getqflist({ title = true, items = true })
end

--- bufname for a qf item's bufnr (qf items resolve filename → bufnr).
local function item_filename(item)
  return vim.api.nvim_buf_get_name(item.bufnr)
end

-- ── (a) basic: region with >=2 live tasks ─────────────────────────────────────

T["quickfix: builds qf list from a region with two live tasks"] = function()
  -- Trailing prose keeps the dashboard off EOF (no sentinel needed); the region
  -- still brackets both task rows.
  local bufnr = make_current_buf({ "```tasks", "not done", "```", "trailing prose" })
  local src_a = vim.fn.tempname() .. ".md"
  local src_b = vim.fn.tempname() .. ".md"
  local layout = {
    task_line("- [ ] Alpha", src_a, 10),
    task_line("- [ ] Beta", src_b, 20),
    { kind = "footer", text = "─ 2 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Tasks inserted at rows 3 and 4 (0-indexed). Cursor on the first → row 4 (1-idx).
  run_quickfix(bufnr, 4)

  local list = qf()
  eq(list.title, "ObsidianTasks")
  eq(#list.items, 2)
  -- Dashboard order preserved.
  eq(item_filename(list.items[1]), src_a)
  eq(item_filename(list.items[2]), src_b)
  -- lnum = source_row + 1 = src_line (draw stores source_row = src_line - 1).
  eq(list.items[1].lnum, 10)
  eq(list.items[2].lnum, 20)
  eq(list.items[1].col, 1)
  -- text = trimmed task_text (source_text passed through verbatim).
  eq(list.items[1].text, "- [ ] Alpha")
  eq(list.items[2].text, "- [ ] Beta")

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
  vim.fn.delete(src_b)
end

-- ── (b) lingers excluded ──────────────────────────────────────────────────────

T["quickfix: excludes lingered rows, keeps live tasks"] = function()
  local bufnr = make_current_buf({ "```tasks", "not done", "```", "trailing prose" })
  local src_live = vim.fn.tempname() .. ".md"
  local src_linger = vim.fn.tempname() .. ".md"
  local layout = {
    task_line("- [ ] Live one", src_live, 5),
    task_line("- [x] Lingering", src_linger, 6, { linger = true }),
    { kind = "footer", text = "─ 2 results ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Cursor anywhere in the region (row 3, 0-idx → line 4).
  run_quickfix(bufnr, 4)

  local list = qf()
  eq(#list.items, 1)
  eq(item_filename(list.items[1]), src_live)
  eq(list.items[1].text, "- [ ] Live one")
  -- The lingered source must NOT appear.
  for _, it in ipairs(list.items) do
    MiniTest.expect.equality(item_filename(it) ~= src_linger, true)
  end

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_live)
  vim.fn.delete(src_linger)
end

-- ── (c) empty: region with zero live tasks leaves qf list UNCHANGED ───────────

T["quickfix: region with only lingers leaves pre-seeded qf list unchanged"] = function()
  -- Seed a distinct qf list first; quickfix must NOT touch it when no items.
  vim.fn.setqflist({}, " ", {
    title = "SEED",
    items = { { filename = "/seed/file.md", lnum = 7, text = "seed entry" } },
  })

  local bufnr = make_current_buf({ "```tasks", "not done", "```", "trailing prose" })
  local src_linger = vim.fn.tempname() .. ".md"
  local layout = {
    task_line("- [x] Only a linger", src_linger, 3, { linger = true }),
    { kind = "footer", text = "─ 1 result ─" },
  }
  draw_mod.draw(bufnr, fence(0, 2), layout)

  -- Cursor on the lone (lingered) task row 3 (0-idx) → line 4.
  run_quickfix(bufnr, 4)

  local list = qf()
  -- Untouched: still the seed.
  eq(list.title, "SEED")
  eq(#list.items, 1)
  eq(list.items[1].text, "seed entry")
  eq(list.items[1].lnum, 7)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_linger)
end

-- ── (d) cursor outside any region leaves qf list unchanged ────────────────────

T["quickfix: cursor outside any rendered region leaves qf list unchanged"] = function()
  vim.fn.setqflist({}, " ", {
    title = "SEED2",
    items = { { filename = "/seed/other.md", lnum = 99, text = "untouched" } },
  })

  -- Leading prose row 0 sits BEFORE the fence → no managed region there.
  local bufnr = make_current_buf({ "plain prose", "```tasks", "not done", "```" })
  local src_a = vim.fn.tempname() .. ".md"
  draw_mod.draw(bufnr, fence(1, 3), {
    task_line("- [ ] In block", src_a, 1),
    { kind = "footer", text = "─ 1 result ─" },
  })

  -- Sanity: row 0 is not in any region.
  eq(managed.region_for_row(bufnr, 0), nil)

  -- Cursor on the prose line (line 1, 1-idx → row 0) → outside region.
  run_quickfix(bufnr, 1)

  local list = qf()
  eq(list.title, "SEED2")
  eq(#list.items, 1)
  eq(list.items[1].text, "untouched")
  eq(list.items[1].lnum, 99)

  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
end

-- ── (e) window layout: qf opens full-width even with a sidebar split ──────────
-- Regression: plain `copen` docks the quickfix window under the CURRENT window's
-- column, so with a vertical sidebar split open (e.g. a file explorer) it lands
-- cramped at partial width.  `botright copen` forces it full-width at the bottom.
-- Also asserts focus stays on the dashboard window (copen must not steal it).

--- Return the window id of the quickfix window in the current tab, or nil.
local function qf_win()
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.bo[b].buftype == "quickfix" then
      return w
    end
  end
  return nil
end

T["quickfix: opens full-width with a sidebar vertical split present"] = function()
  vim.cmd("cclose") -- start from a clean qf-window state

  local bufnr = make_current_buf({ "```tasks", "not done", "```", "trailing prose" })
  local src_a = vim.fn.tempname() .. ".md"
  draw_mod.draw(bufnr, fence(0, 2), {
    task_line("- [ ] Alpha", src_a, 10),
    { kind = "footer", text = "─ 1 result ─" },
  })

  -- The dashboard lives in the current window; open a sidebar on the far left so
  -- the dashboard window is NO LONGER full screen width.
  local dash_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vnew") -- new empty window spanning the left column
  vim.api.nvim_set_current_win(dash_win)
  vim.api.nvim_win_set_cursor(dash_win, { 4, 0 }) -- a task row inside the region

  -- Sanity: with the split, the dashboard window is narrower than the screen.
  MiniTest.expect.equality(vim.api.nvim_win_get_width(dash_win) < vim.o.columns, true)

  run_quickfix(bufnr, 4)

  local qw = qf_win()
  MiniTest.expect.equality(qw ~= nil, true)
  -- botright copen ⇒ the qf window spans the full screen width.
  eq(vim.api.nvim_win_get_width(qw), vim.o.columns)
  -- Focus must remain on the dashboard window, not the quickfix window.
  eq(vim.api.nvim_get_current_win(), dash_win)

  vim.cmd("cclose")
  draw_mod.clear(bufnr)
  -- Close the sidebar (leave a single window for the next test).
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if w ~= dash_win and vim.api.nvim_win_is_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_a)
end

return T
