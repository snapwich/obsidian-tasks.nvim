-- lua/obsidian-tasks/render/folds.lua
-- Manual fold helpers for dashboard buffers.
--
-- Public API:
--   M.setup_window(winid)                          — set foldmethod/foldtext/foldopen
--   M.apply_folds(bufnr, block_list)               — apply manual folds for all blocks
--   M.capture_fold_state(bufnr, fence_lnum)         → "open"|"closed"
--   M.restore_fold_state(bufnr, fence_lnum, region_end, state) — re-fold if needed

local M = {}

-- ── Window configuration ──────────────────────────────────────────────────────

--- Configure fold-related window options for a dashboard buffer window.
---
--- • foldmethod=manual: fold boundaries are explicit, created by :fold commands.
---   We do NOT use 'expr' to avoid recomputation overhead on every keystroke.
--- • foldtext: our Lua summarizer derives a query-summary line from the AST.
--- • foldopen+=insert: pressing 'i' on a closed fold opens it before entering
---   insert mode.  'foldopen' is a global option (no window-local equivalent),
---   so we set it once; subsequent calls are idempotent via the has_insert guard.
---
--- @param winid integer  window to configure (pass 0 for current window)
function M.setup_window(winid)
  vim.wo[winid].foldmethod = "manual"

  -- Our Lua foldtext function; called by Neovim when drawing the fold indicator.
  vim.wo[winid].foldtext = 'v:lua.require("obsidian-tasks.render.foldtext").foldtext()'

  -- foldopen is global-only in Neovim — no per-window equivalent.
  -- Append 'insert' idempotently so pressing 'i' opens closed query folds.
  local fdo = vim.opt.foldopen:get()
  local has_insert = false
  for _, v in ipairs(fdo) do
    if v == "insert" then
      has_insert = true
      break
    end
  end
  if not has_insert then
    vim.opt.foldopen:append("insert")
  end
end

-- ── Internal: apply a single manual fold ─────────────────────────────────────

--- Create a manual fold covering start_lnum..end_lnum (1-indexed).
--- Uses pcall to swallow "E350: Cannot create fold with current 'foldmethod'"
--- if the window's foldmethod was not yet set to 'manual'.
---
--- @param start_lnum integer  1-indexed first line
--- @param end_lnum   integer  1-indexed last line
local function apply_fold(start_lnum, end_lnum)
  if start_lnum > end_lnum then
    return
  end
  pcall(vim.cmd, string.format("%d,%dfold", start_lnum, end_lnum))
end

-- ── Public: apply folds for all blocks in a buffer ────────────────────────────

--- Apply manual folds for every rendered block in bufnr.
---
--- Iterates over all windows currently displaying bufnr, configures each with
--- setup_window(), then folds the range [fence_first+1 .. region_end+1] (the
--- opening fence through the last rendered task line, 1-indexed for :fold).
---
--- @param bufnr      integer
--- @param block_list table[]  list of { fence_first, region_end }  (0-indexed)
function M.apply_folds(bufnr, block_list)
  if #block_list == 0 then
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return
  end
  for _, winid in ipairs(wins) do
    vim.api.nvim_win_call(winid, function()
      M.setup_window(winid)
      for _, block in ipairs(block_list) do
        -- Convert 0-indexed rows to 1-indexed line numbers.
        local start_1 = block.fence_first + 1
        local end_1 = block.region_end + 1
        apply_fold(start_1, end_1)
      end
    end)
  end
end

-- ── Public: fold state capture / restore ─────────────────────────────────────

--- Capture whether the fold at the opening fence is currently open or closed.
---
--- Uses vim.fn.foldclosed(lnum): returns -1 if the line is not in a closed fold,
--- otherwise the start line of the closed fold.
---
--- @param bufnr      integer
--- @param fence_lnum integer  0-indexed opening-fence row
--- @return string  "open" | "closed"
function M.capture_fold_state(bufnr, fence_lnum)
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return "open"
  end
  local lnum_1 = fence_lnum + 1
  local state = "open"
  vim.api.nvim_win_call(wins[1], function()
    if vim.fn.foldclosed(lnum_1) ~= -1 then
      state = "closed"
    end
  end)
  return state
end

--- Open the fold at fence_lnum_1 (1-indexed) in all windows displaying bufnr.
--- Used by rerender_buffer to re-open folds that were open before a re-render.
---
--- @param bufnr       integer
--- @param fence_lnum_1 integer  1-indexed line number of the opening fence
function M.open_fold(bufnr, fence_lnum_1)
  local wins = vim.fn.win_findbuf(bufnr)
  for _, winid in ipairs(wins) do
    vim.api.nvim_win_call(winid, function()
      pcall(vim.cmd, fence_lnum_1 .. "foldopen")
    end)
  end
end

--- Restore fold state for a block after re-rendering.
---
--- If the block was previously closed, re-apply the fold.  If it was open,
--- do nothing — re-rendering removes old folds by deleting + reinserting lines.
---
--- @param bufnr      integer
--- @param fence_lnum integer  0-indexed opening-fence row
--- @param region_end integer  0-indexed last row of the managed region
--- @param state      string   "open" | "closed"
function M.restore_fold_state(bufnr, fence_lnum, region_end, state)
  if state ~= "closed" then
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  for _, winid in ipairs(wins) do
    vim.api.nvim_win_call(winid, function()
      apply_fold(fence_lnum + 1, region_end + 1)
    end)
  end
end

return M
