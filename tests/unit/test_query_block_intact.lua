-- tests/unit/test_query_block_intact.lua
-- Unit tests for render/gate.query_block_intact(bufnr).
--
-- RED phase:
--   Tests that expect true  → PASS  (stub always returns true; these are
--                                    non-regression guards that also pass GREEN).
--   Tests that expect false → FAIL  (stub returns true; expected RED failure;
--                                    will pass once ot-6hvw implements detection).
--
-- Contract under test (see gate.lua module comment for full spec):
--   - Untampered single block → true.
--   - Untampered multi-block buffer → true.
--   - Opening fence removed or overwritten → false.
--   - Closing fence removed or overwritten → false.
--   - Both fences removed → false.
--   - Empty buffer (ggdG equivalent) → false when managed blocks existed.
--   - Fences shifted by a prose insertion above the block → true (block
--     intact; user added prose before it, not dismantled it).
--   - Multi-block: all blocks intact → true.
--   - Multi-block: one block's fences removed → false.

local T = MiniTest.new_set()

local gate = require("obsidian-tasks.render.gate")
local managed = require("obsidian-tasks.render.managed")

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

--- Create a scratch buffer pre-populated with *lines*.
--- @param lines string[]
--- @return integer  bufnr
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Create a buffer with a single tasks block and register the fence mark.
--- Buffer layout (0-indexed rows):
---   0: ```tasks
---   1: not done
---   2: ```
--- Fence mark recorded at open_row=0, close_row=2.
--- @return integer  bufnr
local function make_single_block()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  managed.add_block(bufnr, 0, 2)
  return bufnr
end

--- Tear down a buffer and its managed state.
--- @param bufnr integer
local function teardown(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── Single-block: untampered ──────────────────────────────────────────────────

-- RED: PASSES (stub returns true; will also pass GREEN).
T["query_block_intact: untampered single block → true"] = function()
  local bufnr = make_single_block()
  eq(gate.query_block_intact(bufnr), true, "untampered single block must return true")
  teardown(bufnr)
end

-- ── Multi-block: untampered ───────────────────────────────────────────────────

-- RED: PASSES (stub returns true; will also pass GREEN).
T["query_block_intact: untampered multi-block buffer → true"] = function()
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "some prose",
    "```tasks",
    "due before 2025-01-01",
    "```",
  })
  -- Two blocks: rows 0–2 and rows 4–6.
  managed.add_block(bufnr, 0, 2)
  managed.add_block(bufnr, 4, 6)
  eq(gate.query_block_intact(bufnr), true, "untampered multi-block must return true")
  teardown(bufnr)
end

-- ── Opening fence removed ─────────────────────────────────────────────────────

-- RED: FAILS — stub returns true; expected RED failure.
-- GREEN contract: when the opening fence line is blank the block is incomplete
-- and query_block_intact must return false.
T["query_block_intact: opening fence removed → false"] = function()
  local bufnr = make_single_block()
  -- Remove opening fence: replace with empty line.
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "" })
  -- Row 0 is now empty; no ```tasks opener present.
  eq(gate.query_block_intact(bufnr), false, "removed opening fence must return false")
  teardown(bufnr)
end

-- ── Closing fence removed ─────────────────────────────────────────────────────

-- RED: FAILS — stub returns true; expected RED failure.
-- GREEN contract: when the closing fence line is gone the block is incomplete.
T["query_block_intact: closing fence removed → false"] = function()
  local bufnr = make_single_block()
  -- Remove closing fence: replace with empty line.
  vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "" })
  eq(gate.query_block_intact(bufnr), false, "removed closing fence must return false")
  teardown(bufnr)
end

-- ── Both fences removed ───────────────────────────────────────────────────────

-- RED: FAILS — stub returns true; expected RED failure.
T["query_block_intact: both fences removed → false"] = function()
  local bufnr = make_single_block()
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "" })
  vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "" })
  eq(gate.query_block_intact(bufnr), false, "both fences removed must return false")
  teardown(bufnr)
end

-- ── Empty buffer (ggdG equivalent) ────────────────────────────────────────────

-- RED: FAILS — stub returns true; expected RED failure.
-- GREEN contract: an empty buffer has no fences → false when blocks existed.
T["query_block_intact: empty buffer (ggdG) → false"] = function()
  local bufnr = make_single_block()
  -- Simulate ggdG: delete all lines.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  eq(gate.query_block_intact(bufnr), false, "empty buffer (ggdG) must return false")
  teardown(bufnr)
end

-- ── Fence shifted by prose insertion above the block → true ───────────────────

-- RED: PASSES (stub returns true; will also pass GREEN).
-- Contract: a prose line inserted ABOVE the block shifts the fences but does
-- not dismantle them — the block is still structurally intact.
-- The opening fence extmark (right_gravity=true) drifts to the new row; a
-- scan of the live buffer content still finds a complete ```tasks … ``` pair.
T["query_block_intact: prose inserted above block (fences shift) → true"] = function()
  local bufnr = make_single_block()
  -- Insert prose before the block.  Buffer becomes:
  --   0: # Heading
  --   1: ```tasks      ← opening fence shifted from row 0 to row 1
  --   2: not done
  --   3: ```           ← closing fence shifted from row 2 to row 3
  vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "# Heading" })
  -- The block is still present; only its row numbers shifted.
  eq(gate.query_block_intact(bufnr), true, "prose insertion above block must leave block intact")
  teardown(bufnr)
end

-- ── Closing fence overwritten with prose → false ──────────────────────────────

-- RED: FAILS — stub returns true; expected RED failure.
-- Contract: if the closing fence row is overwritten with arbitrary prose, the
-- block is no longer a complete tasks block.
T["query_block_intact: closing fence overwritten with prose → false"] = function()
  local bufnr = make_single_block()
  -- Overwrite closing fence row with arbitrary prose.
  vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "some prose" })
  eq(gate.query_block_intact(bufnr), false, "overwritten closing fence must return false")
  teardown(bufnr)
end

-- ── Multi-block: one block dismantled → false ─────────────────────────────────

-- RED: FAILS — stub returns true; expected RED failure.
-- Contract: when any one block's opening fence is removed, the whole buffer is
-- no longer intact (atomic per-block semantics).
T["query_block_intact: multi-block buffer with one block dismantled → false"] = function()
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "prose",
    "```tasks",
    "due before 2025-01-01",
    "```",
  })
  managed.add_block(bufnr, 0, 2)
  managed.add_block(bufnr, 4, 6)
  -- Remove the opening fence of the second block (row 4).
  vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { "" })
  eq(gate.query_block_intact(bufnr), false, "partial dismantling of one block must return false")
  teardown(bufnr)
end

-- ── No managed blocks → trivially true ───────────────────────────────────────

-- RED: PASSES (stub returns true; will also pass GREEN).
-- Contract: if there are no managed fence marks, all (zero) blocks are intact.
T["query_block_intact: no managed blocks → true"] = function()
  local bufnr = make_buf({ "just some prose" })
  -- No add_block call → no fence marks.
  eq(gate.query_block_intact(bufnr), true, "buffer with no managed blocks must return true")
  teardown(bufnr)
end

return T
