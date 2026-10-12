-- lua/obsidian-tasks/render/insert_intent.lua
-- Insert intent from cursor provenance (plan D2, ADR 0004).
--
-- A group header is a virtual line attached to the first task of its group, so
-- `O` on that task and `o` on the last task of the group above make the SAME
-- buffer change: one line inserted between the two tasks.  The cursor row read
-- inside on_lines is not reliable (`o` already shows the new row there), so a
-- CursorMoved / CursorMovedI tracker stores the row BEFORE the change and this
-- classifier compares it with the insert row.
--
-- PURE: no buffer access.  All rows are 0-indexed, in nvim_buf_attach on_lines
-- terms (first, old last, new last).

local M = {}

--- Classify one on_lines change.
---
--- Only a PURE line insert (old_last == first, new_last > first) has an intent;
--- a replacement (old_last > first) or a delete is "none".
---
---   tracked_row == first      → "above": the cursor was on the task that the
---                               insert pushed down (`O`, `P`, `:put!` on it).
---   tracked_row == first - 1  → "below": the cursor was on the row above
---                               (`o`, `p` on that task).
---   anything else (or nil)    → "none": no cursor relation; current behavior.
---
--- @param first       integer       first changed row
--- @param old_last    integer       last changed row + 1, before the change
--- @param new_last    integer       last changed row + 1, after the change
--- @param tracked_row integer|nil   cursor row before the change
--- @return "above"|"below"|"none"
function M.classify(first, old_last, new_last, tracked_row)
  if old_last ~= first or new_last <= first or tracked_row == nil then
    return "none"
  end
  if tracked_row == first then
    return "above"
  end
  -- At row 0 there is no row above: first - 1 == -1 is never a real cursor row.
  if first > 0 and tracked_row == first - 1 then
    return "below"
  end
  return "none"
end

return M
