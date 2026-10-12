-- lua/obsidian-tasks/render/group_top.lua
-- Group-top inserts from cursor provenance (plan D2, ADR 0004).
--
-- A group header is a virtual line attached to the first task of its group, so
-- `O` on that task and `o` on the last task of the group above make the SAME
-- buffer change.  The cursor row read inside on_lines is not reliable (`o`
-- already shows the new row there), so a buffer-local CursorMoved /
-- CursorMovedI tracker stores the cursor row BEFORE each change.
-- revert.on_lines calls M.on_pure_insert for every pure line insert into a
-- managed region; render/insert_intent.lua classifies it against the tracked
-- row.
--
-- CursorMoved alone is not enough: `:normal! ko`, `:normal! jO`, and macros
-- move the cursor and insert in ONE command, so CursorMoved does not fire in
-- between and the tracked row is stale.  A namespaced vim.on_key listener
-- (one for all dashboards; it returns at once unless the current buffer has a
-- tracker) also stores the cursor row just BEFORE each key runs.  on_key sees
-- the keys that `:normal`, macros, and mappings execute, so the row is the one
-- the inserting key starts from.  Limit: Lua code that moves the cursor and
-- changes the buffer in one call, with no key in between
-- (nvim_win_set_cursor + nvim_buf_set_lines or a `:put!` from Lua), still uses
-- the row from before that call.
--
-- Classification:
--
--   "above"          → the cursor was on the pushed-down row (`O`, `P`,
--                      `:put!`, `<C-o>O`, a remapped put).  Move the group
--                      header of that row up to the first inserted row
--                      (draw.move_group_header).  The moved header is the
--                      group-top FLAG: M.rows gives flush the inserted rows
--                      below it, and process_inserts carries the flag instead
--                      of re-deriving it from rows_above.
--   "below" / "none" → nothing to do; the insert keeps the anchor rule.
--
-- No o / O / P keymaps: `:put!`, counts, and plugins that remap put (yanky,
-- substitute) all work, and nothing conflicts with other plugins' mappings.
--
-- Lifecycle: M.attach (from revert.attach, at the end of every render) creates
-- the tracker once per buffer and seeds it; M.detach (from revert's on_detach
-- cleanup) tears it down with the buffer.

local M = {}

-- 0-indexed cursor row before the next change; nil until seeded.
local _tracked = {} -- [bufnr] = integer

-- Buffer-local tracker autocmd group.
local _augroup = {} -- [bufnr] = integer

-- Namespace of the one vim.on_key listener (nil until the first attach).
local _on_key_ns = nil

--- Register the vim.on_key listener once.  It stores the cursor row of the
--- current window before every key, when the current buffer has a tracker.
local function ensure_on_key()
  if _on_key_ns then
    return
  end
  _on_key_ns = vim.api.nvim_create_namespace("ObsidianTasksInsertIntentKey")
  vim.on_key(function()
    local bufnr = vim.api.nvim_get_current_buf()
    if _augroup[bufnr] then
      local ok, cursor = pcall(vim.api.nvim_win_get_cursor, 0)
      if ok then
        _tracked[bufnr] = cursor[1] - 1
      end
    end
  end, _on_key_ns)
end

--- Store the cursor row of a window that shows *bufnr* (the current window
--- first).  No-op when no window shows it.
---
--- @param bufnr integer
function M.seed(bufnr)
  local win
  if vim.api.nvim_get_current_buf() == bufnr then
    win = vim.api.nvim_get_current_win()
  else
    win = vim.fn.win_findbuf(bufnr)[1]
  end
  if win then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
    if ok then
      _tracked[bufnr] = cursor[1] - 1
    end
  end
end

--- Create the CursorMoved / CursorMovedI tracker for *bufnr* (once) and seed it.
---
--- @param bufnr integer
function M.attach(bufnr)
  ensure_on_key()
  if not _augroup[bufnr] then
    local group = vim.api.nvim_create_augroup("ObsidianTasksInsertIntent_" .. bufnr, { clear = true })
    _augroup[bufnr] = group
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
      group = group,
      buffer = bufnr,
      callback = function()
        _tracked[bufnr] = vim.api.nvim_win_get_cursor(0)[1] - 1
      end,
    })
  end
  M.seed(bufnr)
end

--- Tear down the tracker and its state for *bufnr*.
---
--- @param bufnr integer
function M.detach(bufnr)
  if _augroup[bufnr] then
    pcall(vim.api.nvim_del_augroup_by_id, _augroup[bufnr])
  end
  _augroup[bufnr] = nil
  _tracked[bufnr] = nil
end

--- The tracked cursor row (0-indexed) for *bufnr*, or nil.  Exposed for tests.
---
--- @param bufnr integer
--- @return integer|nil
function M.tracked_row(bufnr)
  return _tracked[bufnr]
end

--- Handle one pure line insert inside a managed region (called from on_lines).
---
--- On "above", the row the insert pushed down is now at *new_last*; when it
--- carries a group header, move the header up to *first*.  A header moved
--- before is left-gravity (see draw.move_group_header), so it stays at *first*
--- on its own for "above"; for "below" / "none" it must follow the pushed-down
--- row to *new_last*, the same as an unmoved header (`o` on the last task of
--- the previous group keeps its line in that group).  Only an extmark moves
--- here (no text change), so it is safe while the user is still typing.
---
--- @param bufnr    integer
--- @param first    integer  on_lines first changed row
--- @param old_last integer  on_lines old last row (exclusive)
--- @param new_last integer  on_lines new last row (exclusive)
--- @return "above"|"below"|"none"
function M.on_pure_insert(bufnr, first, old_last, new_last)
  local intent = require("obsidian-tasks.render.insert_intent").classify(first, old_last, new_last, _tracked[bufnr])
  local draw = require("obsidian-tasks.render.draw")
  if intent == "above" then
    draw.move_group_header(bufnr, new_last, first)
  else
    draw.move_group_header(bufnr, first, new_last, true)
  end
  return intent
end

--- True when a header moved since the last draw, so the dashboard shows a
--- group-top slot that only a rerender puts back (e.g. `O` + <Esc> left an
--- empty line under the moved header).
---
--- @param bufnr integer
--- @return boolean
function M.has_moved_header(bufnr)
  return #require("obsidian-tasks.render.draw").moved_group_header_rows(bufnr) > 0
end

--- The group-top rows of *bufnr*: for each moved header, the rows from the
--- header's row down to (not including) the next managed row, inside the
--- managed region that holds the header.  These are the rows typed or pasted
--- in a group-top slot.
---
--- @param bufnr       integer
--- @param meta_by_row table    row → meta snapshot (revert.meta_snapshot)
--- @param regions     table[]  region snapshot { {first, last}, … } (inclusive)
--- @return table<integer, true>
function M.rows(bufnr, meta_by_row, regions)
  local out = {}
  for _, hrow in ipairs(require("obsidian-tasks.render.draw").moved_group_header_rows(bufnr)) do
    for _, region in ipairs(regions) do
      if region[1] <= hrow and hrow <= region[2] then
        local row = hrow
        while row <= region[2] and not meta_by_row[row] do
          out[row] = true
          row = row + 1
        end
        break
      end
    end
  end
  return out
end

return M
