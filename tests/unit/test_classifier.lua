-- tests/unit/test_classifier.lua
-- Tests for render/revert.classify — one test per classification branch.
--
-- Classification branches under test:
--   DELETE           — new_text is empty or whitespace-only
--   MUTATE           — description/field change on a structurally-valid task line
--   REPAIR_AND_MUTATE — missing `- ` prefix or `[ ]` checkbox; description change
--   Status flip      — single status-char change routes as MUTATE
--
-- INSERT and MULTI_LINE branches were removed (dead code): flush() detects
-- INSERTs via region scan and never passes a multi-line ctx, so the
-- corresponding classify paths were never reached in production.

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

T["classify REPAIR_AND_MUTATE: no bullet or checkbox in single-line context"] = function()
  local bufnr = make_buf({ "just some prose" })
  -- Per edit_in_place.md plan: single-line, no bullet/checkbox → REPAIR_AND_MUTATE.
  -- The flush layer re-adds the full "- [ ] " prefix so that accidentally deleted
  -- task structure is silently restored (Q10 cursor-shift invariant).
  local result = classify(bufnr, 0, "- [ ] Task", "just some prose", {})
  eq(result, "REPAIR_AND_MUTATE", "no-bullet/no-checkbox single-line should repair (not revert)")
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
