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
-- Implementation note for GREEN (ot-6hvw):
--   Compare the count of live `tasks` blocks found by render.find_blocks(bufnr)
--   against the number of fence marks registered in managed at render time.
--   When the live count is less than the registered count, at least one block
--   was dismantled and the gate should return false.
--
-- RED stub: returns true unconditionally until ot-6hvw implements real
-- detection.  Unit tests expecting false will FAIL as intended in the RED phase.

local M = {}

--- Return true when every managed ``tasks`` block in *bufnr* still has its
--- opening and closing fences present in the buffer.
---
--- RED stub: always returns true.  Real detection is wired in ot-6hvw.
---
--- @param _bufnr integer  dashboard buffer
--- @return boolean
function M.query_block_intact(_bufnr)
  return true
end

return M
