-- tests/unit/test_harden_foldtext.lua
-- Hardening: foldtext counting (unit-level).
--
-- Two product surfaces are exercised directly, without a full render:
--   • render/folds.lua foldtext() — driven by installing a synthetic
--     _foldinfo entry for the closed fold's v:foldstart row, so we can assert the
--     exact rendered string for pluralization / dropped-done-clause / indent.
--   • task/status.lua is_completed() — the classifier the render-time count loop
--     calls on each row's status_symbol to decide N (tasks_done).
--
-- These mirror the foldtext exploration's UNIT cases.  No product code is
-- modified; new file only.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local folds = require("obsidian-tasks.render.folds")
local status = require("obsidian-tasks.task.status")

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Render folds.foldtext() as if a subtree fold starting at 1-indexed `fs` were
--- closed, with the supplied precomputed count entry installed in _foldinfo.
---
--- We build a tiny buffer + window, create a real closed fold so v:foldstart is
--- set to `fs`, install the foldinfo entry keyed by `fs`, then read
--- foldtextresult.  This is the same path render/init.lua + apply_folds drive,
--- minus the layout pipeline — letting us assert exact strings for arbitrary
--- count tuples (T/M/N) that are awkward to provoke through a real render.
local function foldtext_for(entry, fs, nlines)
  fs = fs or 2
  nlines = nlines or (fs + 4)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, nlines do
    lines[i] = "line " .. i
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.cmd("split")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)

  local ft
  vim.api.nvim_win_call(winid, function()
    vim.wo[winid].foldmethod = "manual"
    -- Wire the product foldtext function (same expression setup_window installs)
    -- so foldtextresult evaluates folds.foldtext() rather than nvim's default.
    vim.wo[winid].foldtext = "v:lua.require'obsidian-tasks.render.folds'.foldtext()"
    -- Fold from fs..fs+1 (>=2 lines so the fold is real) and close it.
    vim.cmd(string.format("%d,%dfold", fs, fs + 1))
    vim.cmd(fs .. "foldclose")
    -- Install the synthetic count entry keyed by the closed fold's foldstart.
    folds.set_foldinfo(bufnr, { [fs] = entry })
    ft = vim.fn.foldtextresult(fs)
  end)

  folds.set_foldinfo(bufnr, nil)
  pcall(vim.api.nvim_win_close, winid, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  return ft
end

local function reset_status()
  status.merge({})
end

-- ── foldtext string shaping ───────────────────────────────────────────────────

-- pluralization-T-equals-1: T==1 → singular "child item".
T["foldtext: T==1 renders singular 'child item'"] = function()
  local ft = foldtext_for({ items = 1, tasks_total = 1, tasks_done = 0, indent = "  " })
  eq(ft, "  ▸ 1 child item · 0/1 done", "T==1 must be singular: [" .. ft .. "]")
end

-- pluralization plural sanity (T>1).
T["foldtext: T>1 renders plural 'child items'"] = function()
  local ft = foldtext_for({ items = 3, tasks_total = 2, tasks_done = 1, indent = "  " })
  eq(ft, "  ▸ 3 child items · 1/2 done", "T>1 must be plural: [" .. ft .. "]")
end

-- M-equals-0-done-clause-dropped: M==0 drops the "· N/M done" clause entirely.
T["foldtext: M==0 drops the done clause"] = function()
  local ft = foldtext_for({ items = 2, tasks_total = 0, tasks_done = 0, indent = "  " })
  eq(ft, "  ▸ 2 child items", "M==0 must drop done clause: [" .. ft .. "]")
end

-- M==0 with a single item: singular AND no done clause.
T["foldtext: M==0 and T==1 → singular, no done clause"] = function()
  local ft = foldtext_for({ items = 1, tasks_total = 0, tasks_done = 0, indent = "" })
  eq(ft, "▸ 1 child item", "M==0,T==1: [" .. ft .. "]")
end

-- rendered-text-indent-match-leading-whitespace: the entry's indent is emitted
-- verbatim as the foldtext prefix (a depth-2 child contributes 4 spaces).
T["foldtext: deep indent is preserved verbatim in the prefix"] = function()
  local ft = foldtext_for({ items = 2, tasks_total = 1, tasks_done = 0, indent = "    " })
  eq(ft, "    ▸ 2 child items · 0/1 done", "depth-2 indent (4 spaces) preserved: [" .. ft .. "]")
end

-- N<=M invariant holds for a typical fully-done subtree (N==M, all done).
T["foldtext: N==M renders 'M/M done' (full subtree done)"] = function()
  local ft = foldtext_for({ items = 4, tasks_total = 3, tasks_done = 3, indent = "  " })
  eq(ft, "  ▸ 4 child items · 3/3 done")
end

-- ── status.is_completed classifier (drives N) ─────────────────────────────────

-- status-symbol-missing-no-crash: is_completed(nil) returns false, no crash.
T["is_completed: nil symbol returns false (no crash)"] = function()
  reset_status()
  local ok, res = pcall(status.is_completed, nil)
  eq(ok, true, "is_completed(nil) must not error")
  eq(res, false)
end

-- ON_HOLD-and-IN_PROGRESS-not-done: [h] and [/] never count toward N.
T["is_completed: ON_HOLD [h] and IN_PROGRESS [/] are NOT done"] = function()
  reset_status()
  eq(status.is_completed("h"), false, "[h] ON_HOLD must not count as done")
  eq(status.is_completed("/"), false, "[/] IN_PROGRESS must not count as done")
end

-- DONE [x] and CANCELLED [-] ARE done; Todo [ ] is not.
T["is_completed: only DONE [x] and CANCELLED [-] count as done"] = function()
  reset_status()
  eq(status.is_completed("x"), true, "[x] DONE counts")
  eq(status.is_completed("-"), true, "[-] CANCELLED counts")
  eq(status.is_completed(" "), false, "[ ] Todo does not count")
end

-- An unknown symbol (no entry) returns false.
T["is_completed: unknown symbol returns false"] = function()
  reset_status()
  eq(status.is_completed("Z"), false, "unknown symbol must not count as done")
end

-- custom-status-symbol-obsidian-bridge: a bridged Obsidian symbol registers as
-- TODO-type, so is_completed on it is false (not done).  We register the symbol
-- via the same code path the bridge uses (merge with a TODO override), then
-- assert it is classified pending.  OPEN: the bridge always assigns type=TODO,
-- so even a glyph a user *thinks* of as "done" is not counted unless its type is
-- explicitly DONE/CANCELLED.
T["is_completed: a bridged custom TODO symbol '>' is NOT done"] = function()
  reset_status()
  status.merge({ [">"] = { name = "Forwarded", next = ">", type = "TODO" } })
  eq(status.is_completed(">"), false, "a TODO-typed custom symbol must not count as done")
  reset_status()
end

-- custom-status DONE override IS counted: if a user explicitly types a custom
-- symbol as DONE, is_completed returns true (the classifier is type-driven, not
-- glyph-driven).
T["is_completed: a custom symbol typed DONE IS counted as done"] = function()
  reset_status()
  status.merge({ ["X"] = { name = "Strong done", next = " ", type = "DONE" } })
  eq(status.is_completed("X"), true, "a DONE-typed custom symbol counts as done")
  reset_status()
end

return T
