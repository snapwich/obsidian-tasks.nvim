-- lua/obsidian-tasks/render/edit.lua
-- Tick-coalesced flush queue for managed dashboard edits (P5).
--
-- Design (to be implemented in GREEN task ot-iyw1):
--   • on_lines_hook is called from the on_lines listener for every managed-row
--     edit that the classifier promotes beyond a plain status-flip.
--   • Events within a single event-loop tick are coalesced: only one flush is
--     scheduled per buffer per tick via vim.schedule.
--   • flush(bufnr) groups queued edits by src_path, reads each source file once,
--     applies all per-file edits bottom-up (so row indices stay valid), and
--     writes each source file once.  A single undo block is opened per tick
--     across all affected src_paths.
--   • InsertLeave fires flush(bufnr) synchronously for insert-mode edits.
--   • Per-file write failure: failed files revert their own dashboard rows;
--     other files in the same flush proceed (partial-success notify).
--
-- All functions in this module are stubs returning nil / no-op.
-- Replace with real implementations in GREEN task ot-iyw1.

local M = {}

--- Per-buffer pending flush queue.
--- Shape: flush_queue[bufnr] = { { src_path, row, new_lines, count? }, ... }
---
--- Populated by on_lines_hook; consumed and cleared by flush.
M.flush_queue = {}

--- Hook called from the on_lines listener when a managed row edit is queued
--- for deferred propagation to the source file.
---
--- In the real implementation this:
---   1. Classifies the edit via render/revert.classify.
---   2. On MUTATE / REPAIR_AND_MUTATE: enqueues a per-file edit record into
---      flush_queue[bufnr].
---   3. Schedules flush(bufnr) for end-of-tick via vim.schedule (at most once
---      per buffer per tick — debounced).
---
--- Stub: no-op.
---
--- @param bufnr     integer  dashboard buffer
--- @param row       integer  0-indexed row that changed
--- @param old_text  string   canonical rendered text for this row
--- @param new_text  string   current buffer content for this row
--- @param ctx       table?   extra context forwarded from on_lines
function M.on_lines_hook(_bufnr, _row, _old_text, _new_text, _ctx) end

--- Flush all pending edits for *bufnr* to their respective source files.
---
--- In the real implementation this:
---   1. Drains flush_queue[bufnr].
---   2. Groups edits by src_path.
---   3. For each src_path: locates each row via cmd.locate (drift recovery),
---      reads the file once, applies all edits bottom-up, writes once.
---   4. Opens a single undo block across all src_paths for the tick.
---   5. On per-file write failure: reverts that file's dashboard rows; other
---      files proceed.  Emits a partial-success notification.
---
--- Stub: no-op.
---
--- @param bufnr integer  dashboard buffer whose queued edits should be flushed
function M.flush(_bufnr) end

return M
