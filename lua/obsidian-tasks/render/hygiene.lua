-- lua/obsidian-tasks/render/hygiene.lua
-- Buffer hygiene for plugin-initiated mutations.
--
-- Plugin renders are NOT user edits.  They should not:
--   • mark the buffer modified (causes spurious "save before quit" prompts)
--   • pollute the undo history (pressing u would undo a render)
--   • fire TextChanged / BufModifiedSet (downstream plugins react as if user typed)
--
-- with_clean_buffer() wraps a mutation, suppresses those signals for its
-- duration, restores them after, and conditionally clears `modified` so that
-- a re-render of an otherwise-unchanged buffer doesn't leave it dirty.
--
-- The condition is the `clean_baseline` flag: true when no real user edit has
-- landed since the last save/initial render.  Real user edits (detected by
-- revert.on_lines for changes outside managed regions) flip it to false, and
-- the wrapper then leaves `modified = true` alone — protecting the user's
-- unsaved query edits from being silently cleared by a cross-buffer re-render.

local M = {}

-- ── Mode gate ─────────────────────────────────────────────────────────────────

--- True while the user is in insert or replace mode (any i/R variant).
---
--- Shared predicate for the execution-time gates in edit.on_lines_hook,
--- edit.flush, revert.do_revert, and render/init.rerender_buffer: a plugin
--- write or rerender landing mid-typing would corrupt the user's in-flight
--- edit.  Each call site keeps its own site-specific deferral behavior; only
--- the predicate is shared.
---
--- @return boolean
function M.in_insert_mode()
  return vim.fn.mode():match("[iR]") ~= nil
end

-- ── Per-buffer baseline state ─────────────────────────────────────────────────
-- true  : the buffer has had no real user edit since the last reset (initial
--         render / save / completed revert / completed status-commit).  A
--         subsequent wrapped render is safe to clear `modified`.
-- false : the user has typed something outside a managed region that hasn't
--         been saved yet.  Wrapped renders MUST leave `modified` alone.
local _clean_baseline = {}

--- Mark *bufnr* as clean (no unsaved user edits).
--- Call after: initial render, successful BufWriteCmd, successful revert, and
--- successful status-edit commit + rerender.
--- @param bufnr integer
function M.mark_clean(bufnr)
  _clean_baseline[bufnr] = true
end

--- Mark *bufnr* as dirty (user has unsaved edits outside managed regions).
--- Call from revert.on_lines when the change is not suppressed and at least
--- one changed row falls outside the managed-region snapshot.
--- @param bufnr integer
function M.mark_dirty(bufnr)
  _clean_baseline[bufnr] = false
end

--- Return whether *bufnr*'s baseline is clean.
--- Default for an untracked buffer is true (treat as clean) so that the very
--- first wrapped render on a fresh buffer clears `modified`.
--- @param bufnr integer
--- @return boolean
function M.is_clean(bufnr)
  return _clean_baseline[bufnr] ~= false
end

--- Drop tracking state for *bufnr* on BufDelete.
--- @param bufnr integer
function M._cleanup(bufnr)
  _clean_baseline[bufnr] = nil
end

-- ── Wrap helper ───────────────────────────────────────────────────────────────

--- Run *fn* with plugin-mutation suppressions in effect for *bufnr*.
---
--- Suppresses:
---   • TextChanged / TextChangedI / BufModifiedSet (eventignore append)
---   • undo entries (undolevels = -1)
---   • non-modifiable buffer state (modifiable = true)
---
--- After fn returns, restores all three plus conditionally clears `modified`
--- when `is_clean(bufnr)` is true.
---
--- Nesting is safe: each level saves and restores its own state.
--- vim.opt.eventignore:append is set-semantic so duplicate appends are no-ops.
--- The clean_baseline flag is shared across nest levels, so the inner wrap
--- does not clobber an outer dirty state.
---
--- If *fn* raises, all saves are restored before re-raising.
---
--- @param bufnr integer
--- @param fn    fun()  buffer mutation to perform
-- nvim 0.12 removed BufModifiedSet in favor of OptionSet/modified; only
-- include it when the running nvim still recognizes it, otherwise the
-- append throws E474: Invalid argument.
local _suppress_events = (function()
  local events = { "TextChanged", "TextChangedI" }
  if vim.fn.exists("##BufModifiedSet") == 1 then
    events[#events + 1] = "BufModifiedSet"
  end
  return events
end)()

function M.with_clean_buffer(bufnr, fn)
  local saved_ei = vim.opt.eventignore:get()
  vim.opt.eventignore:append(_suppress_events)

  local saved_ul = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1

  local saved_mod = vim.bo[bufnr].modifiable
  vim.bo[bufnr].modifiable = true

  local ok, err = pcall(fn)

  vim.bo[bufnr].modifiable = saved_mod
  vim.bo[bufnr].undolevels = saved_ul
  if M.is_clean(bufnr) then
    vim.bo[bufnr].modified = false
  end
  vim.opt.eventignore = saved_ei

  if not ok then
    error(err)
  end
end

return M
