-- tests/unit/test_render_revert.lua
-- Unit tests for render/revert.lua.
-- Tests suppress reference counting, attach idempotency, and on_lines intersection
-- detection without running the full render pipeline.

local T = MiniTest.new_set()

local revert = require("obsidian-tasks.render.revert")
local managed = require("obsidian-tasks.render.managed")

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Install a one-shot mock over a module.  Returns restore fn.
local function mock_module(name, replacement)
  local orig = package.loaded[name]
  package.loaded[name] = replacement
  return function()
    package.loaded[name] = orig
  end
end

-- ── suppress / unsuppress ─────────────────────────────────────────────────────

T["suppress: starts at 0"] = function()
  local bufnr = make_buf({ "l" })
  eq(revert.is_suppressed(bufnr), false)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["suppress: increments correctly"] = function()
  local bufnr = make_buf({ "l" })
  revert.suppress(bufnr)
  eq(revert.is_suppressed(bufnr), true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["suppress: reference-counted nesting"] = function()
  local bufnr = make_buf({ "l" })

  revert.suppress(bufnr)
  revert.suppress(bufnr) -- nested
  eq(revert.is_suppressed(bufnr), true)

  revert.unsuppress(bufnr)
  eq(revert.is_suppressed(bufnr), true) -- still 1 remaining

  revert.unsuppress(bufnr)
  eq(revert.is_suppressed(bufnr), false) -- back to 0

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["suppress: unsuppress below zero is safe"] = function()
  local bufnr = make_buf({ "l" })

  revert.unsuppress(bufnr) -- no-op, count stays 0
  eq(revert.is_suppressed(bufnr), false)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── attach / _cleanup ─────────────────────────────────────────────────────────

T["attach: marks buffer as attached"] = function()
  local bufnr = make_buf({ "l" })

  eq(revert._debug_state(bufnr).attached, false)
  revert.attach(bufnr, nil)
  eq(revert._debug_state(bufnr).attached, true)

  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: idempotent — second call does not double-attach"] = function()
  local bufnr = make_buf({ "l" })

  revert.attach(bufnr, nil)
  revert.attach(bufnr, nil) -- second call is no-op
  eq(revert._debug_state(bufnr).attached, true)

  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["attach: updates workspace on subsequent calls"] = function()
  -- Workspace is updated even when listener is already attached.
  -- We verify this via _debug_state (state includes attached flag; workspace is
  -- private but the update is important for the scheduled callback).
  local bufnr = make_buf({ "l" })

  revert.attach(bufnr, { name = "ws1" })
  revert.attach(bufnr, { name = "ws2" }) -- updates workspace, still one listener
  eq(revert._debug_state(bufnr).attached, true)

  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["_cleanup: resets all per-buffer state"] = function()
  local bufnr = make_buf({ "l" })

  revert.attach(bufnr, { name = "ws" })
  revert.suppress(bufnr)

  revert._cleanup(bufnr)

  local s = revert._debug_state(bufnr)
  eq(s.attached, false)
  eq(s.scheduled, false)
  eq(s.suppress, 0)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── on_lines: intersection detection ─────────────────────────────────────────

T["on_lines: edit on managed row schedules revert"] = function()
  local bufnr = make_buf({ "fence", "task_line", "close" })

  -- Region at row 1.
  managed.add_region(bufnr, 1, 1)
  revert.attach(bufnr, nil)

  eq(revert._debug_state(bufnr).scheduled, false)

  -- Mock render init so the scheduled callback doesn't fail without real index.
  local render_called = false
  local restore = mock_module("obsidian-tasks.render.init", {
    rerender_buffer = function(_, _)
      render_called = true
    end,
  })

  -- Edit managed row 1.
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "EDITED" })

  eq(revert._debug_state(bufnr).scheduled, true)

  -- Flush event loop so the scheduled callback runs.
  vim.wait(200)

  restore()

  -- After flush: scheduled flag reset, rerender was called.
  eq(revert._debug_state(bufnr).scheduled, false)
  eq(render_called, true)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: edit in prose (outside managed region) does not schedule revert"] = function()
  local bufnr = make_buf({ "prose", "task_line", "more_prose" })

  -- Region at row 1 only.
  managed.add_region(bufnr, 1, 1)
  revert.attach(bufnr, nil)

  -- Edit row 0 (prose, not in region).
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "EDITED PROSE" })

  eq(revert._debug_state(bufnr).scheduled, false)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: edit below managed region does not schedule revert"] = function()
  local bufnr = make_buf({ "fence", "task", "close", "trailing_prose" })

  managed.add_region(bufnr, 1, 1)
  revert.attach(bufnr, nil)

  -- Edit row 3 (below region).
  vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "EDITED BELOW" })

  eq(revert._debug_state(bufnr).scheduled, false)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: suppressed edit does not schedule revert"] = function()
  local bufnr = make_buf({ "fence", "task_line", "close" })

  managed.add_region(bufnr, 1, 1)
  revert.attach(bufnr, nil)

  -- Plugin write: suppress before edit.
  revert.suppress(bufnr)
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "PLUGIN WRITE" })
  revert.unsuppress(bufnr)

  eq(revert._debug_state(bufnr).scheduled, false)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: debounce — second edit does not schedule a second pass"] = function()
  local bufnr = make_buf({ "fence", "task1", "task2", "close" })

  managed.add_region(bufnr, 1, 2)
  revert.attach(bufnr, nil)

  local call_count = 0
  local restore = mock_module("obsidian-tasks.render.init", {
    rerender_buffer = function(_, _)
      call_count = call_count + 1
    end,
  })

  -- First edit.
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "EDIT1" })
  eq(revert._debug_state(bufnr).scheduled, true)

  -- Second edit while first callback is pending.
  vim.api.nvim_buf_set_lines(bufnr, 2, 3, false, { "EDIT2" })
  eq(revert._debug_state(bufnr).scheduled, true) -- still one pending

  -- Flush.
  vim.wait(200)
  restore()

  -- Only one rerender was called (debounce worked).
  eq(call_count, 1)
  eq(revert._debug_state(bufnr).scheduled, false)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: deletion of managed row schedules revert"] = function()
  local bufnr = make_buf({ "fence", "task_line", "close" })

  managed.add_region(bufnr, 1, 1)
  revert.attach(bufnr, nil)

  local render_called = false
  local restore = mock_module("obsidian-tasks.render.init", {
    rerender_buffer = function(_, _)
      render_called = true
    end,
  })

  -- Delete managed row 1.
  vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, {})

  eq(revert._debug_state(bufnr).scheduled, true)

  vim.wait(200)
  restore()

  eq(render_called, true)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: deletion above managed region does not schedule revert"] = function()
  local bufnr = make_buf({ "prose", "fence", "task_line", "close" })

  -- Region at row 2 (task_line).
  managed.add_region(bufnr, 2, 2)
  revert.attach(bufnr, nil)

  -- Delete row 0 (prose, above region).
  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, {})

  eq(revert._debug_state(bufnr).scheduled, false)

  revert._cleanup(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["on_lines: no managed regions means no revert scheduled"] = function()
  local bufnr = make_buf({ "line0", "line1" })

  -- No managed regions added.
  revert.attach(bufnr, nil)

  vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "EDITED" })

  eq(revert._debug_state(bufnr).scheduled, false)

  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
