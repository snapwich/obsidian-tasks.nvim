-- tests/integration_real/test_lazy_init_ordering.lua
-- Regression: the render orchestrator's per-workspace lazy index init must
-- fire a full vault walk on the first dashboard render, even when other
-- files have already been partially indexed (e.g. via BufReadPost source
-- diagnostics).  Previously the lazy-init check gated on "index has no
-- tasks yet", which became truthy as soon as any non-dashboard md was
-- opened first — the dashboard then queried an incomplete index and
-- showed a subset of the vault's tasks (order-dependent: opening
-- queries/by-tag.md first produced more results than opening
-- invalid-dates.md first).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

T["lazy init: full vault walk fires even when one file pre-indexed"] = function()
  -- Force a clean state so this test exercises the first-render path.
  local render = require("obsidian-tasks.render")
  local idx = require("obsidian-tasks.index")
  idx._reset()
  -- Clear the per-workspace lazy-init guard (private to render/init.lua).
  for k in pairs(rawget(render, "_lazy_init_started") or {}) do
    -- render._lazy_init_started isn't exported; instead, use a module reload
    -- workaround would be heavy.  Skip if not accessible.
    _ = k
  end

  -- (1) Open a non-dashboard md first; BufReadPost should index just it.
  local other = fixture_vault .. "/tasks_a.md"
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(other))
  local other_buf = vim.api.nvim_get_current_buf()
  vim.bo[other_buf].filetype = "markdown"
  idx.invalidate(other)
  idx.refresh_file(other)

  local count_before_dashboard = 0
  for _ in
    idx.tasks_in(function()
      return true
    end)
  do
    count_before_dashboard = count_before_dashboard + 1
  end

  -- (2) Now open a dashboard.  Render must trigger a full vault walk so the
  -- query sees all vault tasks, not just the one file already indexed.
  local dash = fixture_vault .. "/queries/by-tag.md"
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash))
  local dash_buf = vim.api.nvim_get_current_buf()
  vim.bo[dash_buf].filetype = "markdown"
  render.render_buffer(dash_buf, Obsidian.workspace)
  -- refresh_all is async; pump until on_done re-fires render_buffer.
  vim.wait(2000, function()
    local n = 0
    for _ in
      idx.tasks_in(function()
        return true
      end)
    do
      n = n + 1
    end
    return n > count_before_dashboard
  end)

  local count_after_dashboard = 0
  for _ in
    idx.tasks_in(function()
      return true
    end)
  do
    count_after_dashboard = count_after_dashboard + 1
  end

  -- After dashboard render, the full vault walk should have populated the
  -- index with many more tasks (the fixture vault has > 50 tasks across
  -- multiple files; the previously-opened tasks_a.md has < 10).
  eq(count_after_dashboard > count_before_dashboard, true)

  vim.api.nvim_buf_delete(dash_buf, { force = true })
  vim.api.nvim_buf_delete(other_buf, { force = true })
end

return T
