-- lua/obsidian-tasks/render/gate.lua
-- P7: mass-delete safety gate helper.
--
-- query_block_intact(bufnr) inspects the managed `tasks` fenced blocks in
-- bufnr and returns true iff every block's opening and closing fences are
-- still present in the buffer.
--
-- Contract (enforced by unit tests in test_query_block_intact.lua):
--   - Untampered buffer → true.
--   - Opening fence missing or overwritten → false.
--   - Closing fence missing or overwritten → false.
--   - Both fences gone (e.g. ggdG clears the whole buffer) → false.
--   - Empty buffer (all lines deleted) → false when managed blocks existed.
--   - Fences shifted by a prose insertion above the block → true (block is
--     structurally intact; the user only added prose before it).
--   - Multi-block buffer: all blocks intact → true; any block's fences
--     missing → false.
--
-- Implementation:
--   For each fence extmark registered via managed.add_block, look up the
--   current position of the opening-fence extmark (right_gravity=true, so it
--   drifts as lines are inserted before it) and verify:
--     1. The buffer line at current_open_row still starts with "```tasks".
--     2. The buffer line at current_open_row + (recorded_close - recorded_open)
--        still matches "```" (the closing fence).
--   Both checks must pass for every registered block.

local M = {}

--- Return true when every managed ``tasks`` block in *bufnr* still has its
--- opening and closing fences present in the buffer.
---
--- For each fence registered via managed.add_block:
---   • Resolves the current opening-fence row from the live extmark position
---     (the extmark has right_gravity=true, so it drifts with the fence when
---     prose is inserted above).
---   • Checks that buffer[current_open_row] starts with "```tasks".
---   • Derives the expected closing-fence row as:
---       current_open_row + (recorded_close_row - recorded_open_row)
---     This preserves the fence-to-fence offset, so a block whose fences were
---     shifted uniformly (e.g. prose inserted above) is still considered intact.
---   • Checks that buffer[expected_close_row] matches "```" (bare closing fence).
--- Returns false as soon as any check fails; returns true when all pass
--- (including the trivial case of no registered blocks).
---
--- @param bufnr integer  dashboard buffer
--- @return boolean
function M.query_block_intact(bufnr)
  local managed = require("obsidian-tasks.render.managed")
  local iter = managed.fence_marks(bufnr)

  local mid, recorded, current_open_row = iter()
  while mid ~= nil do
    -- Extmark was deleted externally or is otherwise invalid.
    if current_open_row == nil then
      return false
    end

    -- Check opening fence: must still contain "```tasks".
    local open_lines = vim.api.nvim_buf_get_lines(bufnr, current_open_row, current_open_row + 1, false)
    if not open_lines[1] or not open_lines[1]:match("^```tasks") then
      return false
    end

    -- Derive expected closing-fence row using the recorded open/close offset.
    -- recorded = { fence_start_row, fence_end_row } captured at add_block time.
    local close_row = current_open_row + (recorded[2] - recorded[1])
    local close_lines = vim.api.nvim_buf_get_lines(bufnr, close_row, close_row + 1, false)
    -- Closing fence must be a bare triple-backtick line (optional trailing whitespace).
    if not close_lines[1] or not close_lines[1]:match("^```%s*$") then
      return false
    end

    mid, recorded, current_open_row = iter()
  end

  -- All blocks intact (or no blocks registered → trivially true).
  return true
end

return M
