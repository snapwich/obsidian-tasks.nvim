-- tests/unit/test_classifier.lua
-- RED-phase tests for render/revert.classify — one test per classification branch.
--
-- All tests fail while classify() is a stub returning nil.
-- They pass once the GREEN task (ot-165d) implements real classification.
--
-- Classification branches under test:
--   DELETE           — new_text is empty or whitespace-only
--   MUTATE           — description/field change on a structurally-valid task line
--   REPAIR_AND_MUTATE — missing `- ` prefix or `[ ]` checkbox; description change
--   INSERT           — unmanaged row appearing between managed rows
--   MULTI_LINE       — neighbouring rows also changed in the same tick
--   REVERT           — no bullet/checkbox in a multi-line context → revert
--   Status flip      — single status-char change routes as MUTATE

local T = MiniTest.new_set()

local revert = require("obsidian-tasks.render.revert")

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  return bufnr
end

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Convenience: call classify with a simple no-context table.
local function classify(bufnr, row, old_text, new_text, ctx)
  return revert.classify(bufnr, row, old_text, new_text, ctx or {})
end

-- ── DELETE branch ─────────────────────────────────────────────────────────────

T["classify DELETE: empty new_text"] = function()
  local bufnr = make_buf({ "- [ ] Some task" })
  local result = classify(bufnr, 0, "- [ ] Some task", "")
  eq(result, "DELETE", "empty line should classify as DELETE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["classify DELETE: whitespace-only new_text"] = function()
  local bufnr = make_buf({ "- [ ] Some task" })
  local result = classify(bufnr, 0, "- [ ] Some task", "   ")
  eq(result, "DELETE", "whitespace-only line should classify as DELETE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── MUTATE branch ─────────────────────────────────────────────────────────────

T["classify MUTATE: description change"] = function()
  local bufnr = make_buf({ "- [ ] Old description" })
  local result = classify(bufnr, 0, "- [ ] Old description", "- [ ] New description")
  eq(result, "MUTATE", "description-only change should classify as MUTATE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["classify MUTATE: field value change (due date)"] = function()
  local bufnr = make_buf({ "- [ ] Task 📅 2024-01-01" })
  local result = classify(bufnr, 0, "- [ ] Task 📅 2024-01-01", "- [ ] Task 📅 2024-12-31")
  eq(result, "MUTATE", "date field change should classify as MUTATE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["classify MUTATE: status flip routes as MUTATE branch"] = function()
  local bufnr = make_buf({ "- [ ] Task" })
  -- Status-flip: [ ] → [x]; structurally valid → MUTATE (same pipeline as description edit)
  local result = classify(bufnr, 0, "- [ ] Task", "- [x] Task")
  eq(result, "MUTATE", "status flip should route through MUTATE branch")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── REPAIR_AND_MUTATE branch ──────────────────────────────────────────────────

T["classify REPAIR_AND_MUTATE: missing dash prefix"] = function()
  local bufnr = make_buf({ "[ ] Task description" })
  -- new_text has description change but is missing the leading `- ` prefix
  local result = classify(bufnr, 0, "- [ ] Task description", "[ ] Task description edited")
  eq(result, "REPAIR_AND_MUTATE", "missing `- ` prefix should classify as REPAIR_AND_MUTATE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["classify REPAIR_AND_MUTATE: missing checkbox"] = function()
  local bufnr = make_buf({ "- Task description" })
  -- new_text is missing `[ ]` but still looks like a list item with text
  local result = classify(bufnr, 0, "- [ ] Task description", "- Task description edited")
  eq(result, "REPAIR_AND_MUTATE", "missing `[ ]` checkbox should classify as REPAIR_AND_MUTATE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── INSERT branch ─────────────────────────────────────────────────────────────

T["classify INSERT: unmanaged row between managed rows"] = function()
  -- Simulate context: the row did not exist at render time (old_text nil)
  -- and the new_text is non-empty → INSERT
  local bufnr = make_buf({ "- [ ] Task A", "brand new unmanaged line", "- [ ] Task B" })
  local result = classify(bufnr, 1, nil, "brand new unmanaged line", { is_insert = true })
  eq(result, "INSERT", "new unmanaged row between managed rows should classify as INSERT")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── MULTI_LINE branch ─────────────────────────────────────────────────────────

T["classify MULTI_LINE: neighbouring rows also changed in same tick"] = function()
  local bufnr = make_buf({ "- [ ] Task A", "- [ ] Task B" })
  -- ctx.is_multi_line = true indicates the tick changed >1 managed row
  local result = classify(bufnr, 0, "- [ ] Task A", "- [ ] Task A edited", { is_multi_line = true })
  eq(result, "MULTI_LINE", "multi-row tick should classify as MULTI_LINE")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── REVERT branch ─────────────────────────────────────────────────────────────

T["classify REVERT: no bullet or checkbox in multi-line context"] = function()
  local bufnr = make_buf({ "just some prose" })
  -- In a multi-line context a row without bullet/checkbox structure reverts
  local result = classify(bufnr, 0, "- [ ] Task", "just some prose", { is_multi_line = true })
  eq(result, "REVERT", "no-bullet row in multi-line context should classify as REVERT")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["classify REVERT: no bullet or checkbox in single-line context"] = function()
  local bufnr = make_buf({ "just some prose" })
  -- Deviation from spec wording: spec says REPAIR_AND_MUTATE for "missing - and/or [ ]",
  -- but a line with NO task-like structure whatsoever (neither bullet nor checkbox) is
  -- not repairable — it is unrecognisably different from a task line.  REVERT is the
  -- correct outcome for single-line prose replacing a managed row.
  local result = classify(bufnr, 0, "- [ ] Task", "just some prose", {})
  eq(result, "REVERT", "no-bullet/no-checkbox single-line should revert (not task-like)")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
