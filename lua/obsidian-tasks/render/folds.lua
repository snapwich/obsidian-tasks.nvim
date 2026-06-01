-- lua/obsidian-tasks/render/folds.lua
-- Manual fold helpers for dashboard buffers.
--
-- Public API:
--   M.setup_window(winid)                          — set foldmethod/foldopen
--   M.apply_folds(bufnr, block_list)               — apply manual folds for all blocks
--   M.capture_fold_state(bufnr, fence_lnum)         → "open"|"closed"
--   M.restore_fold_state(bufnr, fence_first, fence_last, state) — re-fold if needed

local M = {}

-- ── Subtree fold-text info ────────────────────────────────────────────────────
--
-- Per-buffer map: bufnr → { [foldstart_1] = { items, tasks_total, tasks_done,
-- indent } } where foldstart_1 is the 1-indexed FIRST-CHILD row of a subtree
-- fold (the value child_fold_range returns as start, equal to v:foldstart for a
-- closed subtree fold).  Built at RENDER TIME (counts computed over the hidden
-- descendant rows, not by parsing line text) and pushed in via M.set_foldinfo so
-- M.foldtext() can branch:
--   • entry present  → subtree fold → "{indent}▸ {T} item(s) · {N}/{M} done"
--   • entry absent    → fence/query fold → legacy "first line  ▸ N" behaviour
--
-- The table is REPLACED wholesale every render (set_foldinfo) so it can never go
-- stale across rerenders or the fold capture/restore path, and cleared on buffer
-- teardown (clear_foldinfo).
--- @type table<integer, table<integer, table>>
M._foldinfo = {}

--- Replace the subtree fold-text info for *bufnr* (rebuilt every render).
--- Passing nil/empty clears the buffer's entry entirely.
--- @param bufnr integer
--- @param info table<integer, table>|nil
function M.set_foldinfo(bufnr, info)
  if info == nil or next(info) == nil then
    M._foldinfo[bufnr] = nil
  else
    M._foldinfo[bufnr] = info
  end
end

--- Drop the subtree fold-text info for *bufnr* (buffer teardown).
--- @param bufnr integer
function M.clear_foldinfo(bufnr)
  M._foldinfo[bufnr] = nil
end

-- ── Window configuration ──────────────────────────────────────────────────────

--- Configure fold-related window options for a dashboard buffer window.
---
--- • foldmethod=manual: fold boundaries are explicit, created by :fold commands.
---   We do NOT use 'expr' to avoid recomputation overhead on every keystroke.
--- • foldopen+=insert: pressing 'i' on a closed fold opens it before entering
---   insert mode.  'foldopen' is a global option (no window-local equivalent),
---   so we set it once; subsequent calls are idempotent via the has_insert guard.
---
--- foldcolumn + a custom foldtext are set ONLY when the buffer carries at least
--- one subtree fold (a `show tree` dashboard).  A plain flat dashboard reaches
--- this path too (it folds the fence even with default_folded=true), and must
--- keep the window's prior foldcolumn / foldtext untouched so its render stays
--- byte-identical to the pre-tree behaviour.
---
--- @param winid    integer  window to configure (pass 0 for current window)
--- @param has_tree boolean? when true, advertise the fold gutter + custom foldtext
function M.setup_window(winid, has_tree)
  vim.wo[winid].foldmethod = "manual"

  if has_tree then
    -- Capture the window's PRIOR foldcolumn / foldtext the first time we switch
    -- it into tree mode, so a later flat re-render (tree → flat transition) can
    -- restore them and leave the window indistinguishable from a never-tree flat
    -- dashboard.  Guard on the stash being absent so repeated tree renders don't
    -- overwrite the genuine prior value with the tree value.
    if vim.w[winid].obsidian_tasks_fold_prior == nil then
      vim.w[winid].obsidian_tasks_fold_prior = {
        foldcolumn = vim.wo[winid].foldcolumn,
        foldtext = vim.wo[winid].foldtext,
      }
    end

    -- Advertise foldability: a 1-column fold gutter shows the +/- markers and
    -- the fold level.  Only for tree dashboards (see header).
    vim.wo[winid].foldcolumn = "1"

    -- Custom foldtext: shows the fold's first line plus a hidden-line count
    -- indicator (e.g. "  ▸ 3").  Resolved as a global function so the foldtext
    -- expression stays a stable string (avoids re-evaluating a closure per line).
    vim.wo[winid].foldtext = "v:lua.require'obsidian-tasks.render.folds'.foldtext()"
  else
    -- Flat dashboard.  If this window was PREVIOUSLY rendered as a tree, the
    -- tree branch set foldcolumn=1 + a custom foldtext; restore the captured
    -- prior values so the tree → flat transition leaves no stale window options
    -- (a flat re-render must be byte-identical to a never-tree flat buffer).
    -- A window that was never a tree has no stash → leave its options untouched.
    local prior = vim.w[winid].obsidian_tasks_fold_prior
    if prior ~= nil then
      vim.wo[winid].foldcolumn = prior.foldcolumn or "0"
      vim.wo[winid].foldtext = prior.foldtext or ""
      vim.w[winid].obsidian_tasks_fold_prior = nil
    end
  end

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

--- Custom 'foldtext' for dashboard folds.
---
--- Two shapes, selected by whether a subtree fold-info entry exists for
--- v:foldstart in the current buffer (see M._foldinfo / M.set_foldinfo):
---
--- • SUBTREE fold (entry present): a CHILDREN-ONLY fold whose first line is the
---   first child of a matched root.  The matched root sits visible above the
---   fold, so the foldtext does NOT repeat a root line; it summarises the
---   collapsed rows:  "{indent}▸ {T} child item(s) · {N}/{M} done"
---     T = every non-blank folded row (lit, dim, context, connector sentinels);
---     M = matched/lit descendant TASKS only; N = those whose status is
---     Done/Cancelled.  When M==0 the "· {N}/{M} done" clause is dropped.
---   Counts are precomputed at render time (folds never parse line text here).
---
--- • FENCE/QUERY fold (entry absent): legacy behaviour — the fold's first
---   (root) line followed by "  ▸ N", N = the number of non-blank hidden rows
---   below the root.  Byte-for-byte unchanged from the pre-subtree-foldtext form.
---
--- @return string
function M.foldtext()
  local fs = vim.v.foldstart

  -- Subtree fold?  Look up the render-time info keyed by the 1-indexed
  -- first-child row (== v:foldstart for a closed subtree fold).
  local info = M._foldinfo[vim.api.nvim_get_current_buf()]
  local entry = info and info[fs]
  if entry then
    local t = entry.items
    local item_word = (t == 1) and "child item" or "child items"
    if entry.tasks_total == 0 then
      return entry.indent .. "▸ " .. t .. " " .. item_word
    end
    return entry.indent
      .. "▸ "
      .. t
      .. " "
      .. item_word
      .. " · "
      .. entry.tasks_done
      .. "/"
      .. entry.tasks_total
      .. " done"
  end

  -- Fence/query fold: legacy "first line  ▸ N".
  local fe = vim.v.foldend
  local first = vim.fn.getline(fs)
  -- Count hidden descendant ITEMS: lines below the root (fs+1..fe) that are not
  -- blank.  getline over the small fold range is cheap and needs no fold→row
  -- metadata threading.
  local hidden = 0
  for lnum = fs + 1, fe do
    local line = vim.fn.getline(lnum)
    if line:match("%S") then
      hidden = hidden + 1
    end
  end
  -- Strip trailing whitespace from the root line for a tidy indicator join.
  first = first:gsub("%s+$", "")
  return first .. "  ▸ " .. hidden
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

--- Open a manual fold spanning start_1..end_1 (1-indexed) so it renders
--- EXPANDED.  Used for per-subtree folds, which default open (upstream parity).
--- @param start_1 integer
--- @param end_1   integer
local function open_fold_range(start_1, end_1)
  if start_1 >= end_1 then
    return
  end
  pcall(vim.cmd, string.format("%dfoldopen", start_1))
end

--- Translate a stored subtree range {root0, last0} (0-indexed: the matched root
--- row plus all its descendant rows) into the 1-indexed CHILDREN-ONLY fold range
--- to actually create — i.e. [root+1 .. last], EXCLUDING the root.
---
--- Returns (start_1, end_1) or nil when the subtree has fewer than two descendant
--- rows.  Two reasons we fold the children only, never the root:
---   • Folding the root would hide it (collapsed into foldtext) and make it
---     uneditable without first opening the fold; keeping the root visible lets
---     the user edit / toggle it directly.
---   • It keeps the root row OUTSIDE every closed fold, so a group header
---     attached to the first task as a virt_lines_above extmark is never swallowed
---     by the fold (Neovim hides virt_lines_above on a fold's first line).
--- A subtree with a single descendant is left UNFOLDED: collapsing one line into
--- a one-line foldtext saves no space.
---
--- @param root0 integer  0-indexed matched-root row
--- @param last0 integer  0-indexed last descendant row
--- @return integer|nil start_1, integer|nil end_1
function M.child_fold_range(root0, last0)
  if (last0 - root0) < 2 then
    return nil
  end
  return root0 + 2, last0 + 1
end

--- Apply manual folds for every rendered block in bufnr.
---
--- Iterates over all windows currently displaying bufnr, configures each with
--- setup_window(), then for each block:
---   • folds the fence lines [fence_first+1 .. fence_last+1] — the query — so
---     it can collapse while rendered tasks below stay visible (AC1).  The
---     fence fold is created CLOSED only when *close_fence* is true (governed
---     by default_folded upstream).
---   • for `show tree` blocks, creates ONE manual fold per subtree fold_group
---     (block.subtree_folds), each defaulting OPEN (expanded).  These let
---     za/zo/zc/zR/zM collapse an individual subtree under its matched root.
---
--- Subtree folds are always (re)built so the fold structure exists even when
--- the fence fold is left open; only the fence-fold CLOSE is gated.
---
--- @param bufnr      integer
--- @param block_list table[]  list of { fence_first, fence_last, subtree_folds? }  (0-indexed)
--- @param close_fence boolean?  when false, create no closed fence fold (default_folded=false)
--- @param foldinfo    table<integer, table>?  render-time subtree fold-text info,
---                    keyed by 1-indexed first-child row (see M.set_foldinfo)
function M.apply_folds(bufnr, block_list, close_fence, foldinfo)
  -- Replace any prior subtree fold-text info FIRST so a render that produced no
  -- subtree folds (flat dashboard, or no foldable subtrees) clears stale state
  -- and foldtext() falls back to the legacy fence form.
  M.set_foldinfo(bufnr, foldinfo)
  if #block_list == 0 then
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins == 0 then
    return
  end
  if close_fence == nil then
    close_fence = true
  end
  -- A tree dashboard carries at least one subtree fold; only then do we
  -- advertise the fold gutter + custom foldtext (a flat dashboard folds only
  -- its fence and must keep the window's prior foldcolumn / foldtext).
  local has_tree = false
  for _, block in ipairs(block_list) do
    if block.subtree_folds and #block.subtree_folds > 0 then
      has_tree = true
      break
    end
  end
  for _, winid in ipairs(wins) do
    vim.api.nvim_win_call(winid, function()
      M.setup_window(winid, has_tree)
      -- Delete ALL existing manual folds before re-applying.  Without this,
      -- stale folds from a prior render survive line deletions/insertions and
      -- accumulate as nested / overlapping folds that confuse foldclosed().
      pcall(vim.cmd, "normal! zE")
      for _, block in ipairs(block_list) do
        -- Subtree folds FIRST: create each as a manual fold then open it so it
        -- defaults expanded.  Creating the fence fold afterward (and closing it)
        -- does not disturb these already-open subtree folds.
        for _, sf in ipairs(block.subtree_folds or {}) do
          -- sf = { root, last } 0-indexed buffer rows (root + descendants).  Fold
          -- the CHILDREN ONLY ([root+1..last]); the root stays visible + editable
          -- and outside the fold so its group-header virt line is never hidden.
          -- Single-descendant subtrees are skipped (nil) — no space saved.
          local s1, e1 = M.child_fold_range(sf[1], sf[2])
          if s1 then
            apply_fold(s1, e1)
            open_fold_range(s1, e1)
          end
        end
        -- Fence fold (the query).  Convert 0-indexed rows to 1-indexed.
        local start_1 = block.fence_first + 1
        local end_1 = block.fence_last + 1
        if close_fence then
          apply_fold(start_1, end_1)
        end
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

--- Re-create + close a manual fold spanning start_1..end_1 (1-indexed) in all
--- windows displaying bufnr.  Used by rerender_buffer to re-close a subtree fold
--- the user had collapsed before the re-render (subtree folds default open).
---
--- @param bufnr   integer
--- @param start_1 integer  1-indexed first row
--- @param end_1   integer  1-indexed last row
function M.close_fold_range(bufnr, start_1, end_1)
  if start_1 >= end_1 then
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  for _, winid in ipairs(wins) do
    vim.api.nvim_win_call(winid, function()
      apply_fold(start_1, end_1)
    end)
  end
end

--- Restore fold state for a block after re-rendering.
---
--- If the block was previously closed, re-apply the fold.  If it was open,
--- do nothing — re-rendering removes old folds by deleting + reinserting lines.
---
--- @param bufnr       integer
--- @param fence_first integer  0-indexed opening-fence row
--- @param fence_last  integer  0-indexed closing-fence row
--- @param state       string   "open" | "closed"
function M.restore_fold_state(bufnr, fence_first, fence_last, state)
  if state ~= "closed" then
    return
  end
  local wins = vim.fn.win_findbuf(bufnr)
  for _, winid in ipairs(wins) do
    vim.api.nvim_win_call(winid, function()
      apply_fold(fence_first + 1, fence_last + 1)
    end)
  end
end

return M
