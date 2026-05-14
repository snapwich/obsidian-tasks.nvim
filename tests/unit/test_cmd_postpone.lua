-- tests/unit/test_cmd_postpone.lua
-- Parity with .deps/obsidian-tasks/tests/DateTime/Postponer.test.ts
--
-- :ObsidianTask postpone [N] bumps the task's primary date by N days.
-- Priority of date fields to bump: due > scheduled > start.
-- Default N = 1 day.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

--- Run :ObsidianTask postpone in a scratch buffer; return the buffer's line.
--- @param task_line string
--- @param args      table  fargs after "postpone"
--- @return string  the (possibly modified) buffer line
local function run_postpone(task_line, args)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { task_line })
  vim.api.nvim_set_current_buf(buf)
  local cmd = require("obsidian-tasks.cmd")
  local fargs = { "postpone" }
  for _, a in ipairs(args or {}) do
    fargs[#fargs + 1] = a
  end
  cmd.dispatch({ fargs = fargs, line1 = 1, line2 = 1 })
  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
  pcall(vim.api.nvim_buf_delete, buf, { force = true })
  return line
end

-- ── default +1 day ────────────────────────────────────────────────────────

T["postpone: default bumps due by +1 day"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-04-20", {})
  eq(r:find("📅 2024%-04%-21") ~= nil, true)
end

T["postpone: explicit `postpone 3` bumps by +3 days"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-04-20", { "3" })
  eq(r:find("📅 2024%-04%-23") ~= nil, true)
end

T["postpone: negative N pulls the date earlier"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-04-20", { "-2" })
  eq(r:find("📅 2024%-04%-18") ~= nil, true)
end

-- ── field priority: due > scheduled > start ──────────────────────────────

T["postpone: bumps DUE when only due is set"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-04-20", {})
  eq(r:find("📅 2024%-04%-21") ~= nil, true)
end

T["postpone: bumps SCHEDULED when due is absent"] = function()
  local r = run_postpone("- [ ] Task ⏳ 2024-04-20", {})
  eq(r:find("⏳ 2024%-04%-21") ~= nil, true)
end

T["postpone: bumps START when due and scheduled are absent"] = function()
  local r = run_postpone("- [ ] Task 🛫 2024-04-20", {})
  eq(r:find("🛫 2024%-04%-21") ~= nil, true)
end

T["postpone: bumps DUE first when due AND scheduled are both set"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-04-20 ⏳ 2024-04-25", {})
  eq(r:find("📅 2024%-04%-21") ~= nil, true)
  -- Scheduled date is NOT also bumped.
  eq(r:find("⏳ 2024%-04%-25") ~= nil, true)
end

-- ── No date → graceful no-op (with notification) ─────────────────────────

T["postpone: task with no date is a no-op (line unchanged)"] = function()
  local original = "- [ ] Task with no date"
  local r = run_postpone(original, {})
  eq(r, original)
end

-- ── Calendar arithmetic correctness (month rollover) ─────────────────────

T["postpone: bumps across month boundary"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-01-31", {})
  eq(r:find("📅 2024%-02%-01") ~= nil, true)
end

T["postpone: bumps across year boundary"] = function()
  local r = run_postpone("- [ ] Task 📅 2024-12-31", {})
  eq(r:find("📅 2025%-01%-01") ~= nil, true)
end

return T
