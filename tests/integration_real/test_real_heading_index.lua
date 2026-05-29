-- tests/integration_real/test_real_heading_index.lua
-- Real-dep coverage for heading tracking.  A full vault walk via the real
-- obsidian.nvim ripgrep search must populate `task.heading` with the nearest
-- ATX heading above each task line.
--
-- The stubbed scan unit tests (test_index.lua) feed pre-built match rows and
-- so cannot catch ripgrep pattern-syntax or result-shape drift; this test
-- exercises the real `search_async` → `scan.walk` path end to end.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

T["refresh_all: real vault walk records task.heading"] = function()
  local idx = require("obsidian-tasks.index")
  idx._reset()

  local done = false
  idx.refresh_all(require("fixture_ws")(), function()
    done = true
  end)
  vim.wait(5000, function()
    return done
  end)
  eq(done, true)

  -- work/sprint.md lays tasks under "# Sprint May 2026", then a trailing
  -- "## Stretch goals" section.
  local heading_of = {}
  for task, abs_path in
    idx.tasks_in(function()
      return true
    end)
  do
    if abs_path:match("work/sprint%.md$") then
      heading_of[task.description] = task.heading
    end
  end

  eq(heading_of["Ship auth refactor #task #work #sprint"], "Sprint May 2026")
  eq(heading_of["Migrate analytics SDK #task #work #sprint"], "Stretch goals")
  eq(heading_of["Onboarding doc refresh #task #work"], "Stretch goals")
end

return T
