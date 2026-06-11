-- tests/unit/test_revert_suppress.lua
-- Unit tests for revert.with_suppressed: exception-safe suppress/unsuppress
-- pairing.  If an error escaped between suppress() and unsuppress(), the
-- counter would stick and on_lines would be silently dead for the buffer.

local T = MiniTest.new_set()

local revert = require("obsidian-tasks.render.revert")

-- Synthetic bufnr: suppress state is plain per-bufnr bookkeeping, no real
-- buffer is needed.
local BUF = 4242

T["with_suppressed suppresses during fn and unsuppresses after"] = function()
  revert._cleanup(BUF)
  local during = nil
  revert.with_suppressed(BUF, function()
    during = revert.is_suppressed(BUF)
  end)
  MiniTest.expect.equality(during, true)
  MiniTest.expect.equality(revert.is_suppressed(BUF), false)
  MiniTest.expect.equality(revert._debug_state(BUF).suppress, 0)
end

T["with_suppressed unsuppresses when fn throws and propagates the error"] = function()
  revert._cleanup(BUF)
  local ok, err = pcall(revert.with_suppressed, BUF, function()
    error("boom from fn", 0)
  end)
  MiniTest.expect.equality(ok, false)
  -- Error message preserved verbatim (rethrown at level 0, no position prefix).
  MiniTest.expect.equality(err, "boom from fn")
  -- Counter back to baseline: on_lines is alive again.
  MiniTest.expect.equality(revert.is_suppressed(BUF), false)
  MiniTest.expect.equality(revert._debug_state(BUF).suppress, 0)
end

T["with_suppressed preserves non-string error objects"] = function()
  revert._cleanup(BUF)
  local sentinel = { code = 42 }
  local ok, err = pcall(revert.with_suppressed, BUF, function()
    error(sentinel)
  end)
  MiniTest.expect.equality(ok, false)
  MiniTest.expect.equality(err, sentinel)
  MiniTest.expect.equality(revert._debug_state(BUF).suppress, 0)
end

T["with_suppressed restores an outer suppress level on error (nesting)"] = function()
  revert._cleanup(BUF)
  revert.suppress(BUF) -- outer level, e.g. render_buffer in progress
  MiniTest.expect.equality(revert._debug_state(BUF).suppress, 1)

  pcall(revert.with_suppressed, BUF, function()
    MiniTest.expect.equality(revert._debug_state(BUF).suppress, 2)
    error("inner failure")
  end)

  -- Back to the OUTER baseline, not zero.
  MiniTest.expect.equality(revert._debug_state(BUF).suppress, 1)
  revert.unsuppress(BUF)
  MiniTest.expect.equality(revert.is_suppressed(BUF), false)
  revert._cleanup(BUF)
end

return T
