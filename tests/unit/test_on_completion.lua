-- tests/unit/test_on_completion.lua
-- Parity with .deps/obsidian-tasks/tests/Task/OnCompletion.test.ts
--
-- The 🏁 field controls what happens when a task transitions to a completed
-- type.  Supported values:
--   🏁 delete   → the task line is removed from its source file
--   🏁 keep     → default; no special action (line stays with [x])
-- Other values (e.g. "next-recurrence-only") are parsed and preserved but
-- have no special handler in v1.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local serialize = require("obsidian-tasks.task.serialize")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

-- ── Parse + serialize round-trip ─────────────────────────────────────────

T["parse: 🏁 delete is captured as on_completion field"] = function()
  local t = pt("- [ ] Buy milk 🏁 delete")
  eq(t.fields.on_completion, "delete")
end

T["parse: 🏁 keep is captured"] = function()
  local t = pt("- [ ] Recurring task 🔁 every week 🏁 keep")
  eq(t.fields.on_completion, "keep")
end

T["serialize: 🏁 round-trips through parse + serialize"] = function()
  local t1 = pt("- [ ] T 🏁 delete")
  local t2 = pt(serialize.serialize(t1))
  eq(t2.fields.on_completion, "delete")
end

-- ── Behavioral: marking done with 🏁 delete removes the line ─────────────
-- The behavior is exercised end-to-end via :ObsidianTask done.  Unit-level
-- check: the done command computes the new line, then the dispatcher calls
-- cmd.commit_line with an empty replacement when on_completion == "delete".

T["done command: with 🏁 delete, the new-line list passed to commit_line is empty"] = function()
  -- Set up: a buffer-backed scratch task.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] Buy milk 🏁 delete" })
  vim.api.nvim_set_current_buf(buf)

  -- Intercept commit_line to capture what new_lines arg it receives.
  local cmd = require("obsidian-tasks.cmd")
  local captured
  local orig_commit = cmd.commit_line
  cmd.commit_line = function(resolved, new_lines)
    captured = new_lines
    -- Return true so the caller proceeds.
    return true
  end

  -- Run :ObsidianTask done at line 1.
  cmd.dispatch({ fargs = { "done" }, line1 = 1, line2 = 1 })

  cmd.commit_line = orig_commit
  -- Empty list = delete-the-line.
  eq(type(captured), "table")
  eq(#captured, 0)

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

T["done command: without 🏁 delete, commit_line receives a [x]-stamped line"] = function()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "- [ ] Buy milk" })
  vim.api.nvim_set_current_buf(buf)

  local cmd = require("obsidian-tasks.cmd")
  local captured
  local orig_commit = cmd.commit_line
  cmd.commit_line = function(resolved, new_lines)
    captured = new_lines
    return true
  end

  cmd.dispatch({ fargs = { "done" }, line1 = 1, line2 = 1 })

  cmd.commit_line = orig_commit
  eq(type(captured), "table")
  eq(#captured, 1)
  -- The replacement line contains [x] (done marker).
  eq(captured[1]:find("%[x%]") ~= nil, true)

  pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

return T
