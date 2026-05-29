-- tests/integration_standalone/test_standalone.lua
-- End-to-end proof that obsidian-tasks works with obsidian.nvim NOT loaded.
-- Runs in-process under tests/minit_standalone.lua (mini.nvim + repo only).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

-- ── precondition: obsidian.nvim really is absent ─────────────────────────────

T["obsidian.nvim is not loaded in this process"] = function()
  eq(Obsidian, nil)
  eq(package.loaded["obsidian"], nil)
  eq(#vim.api.nvim_get_runtime_file("lua/obsidian/init.lua", false), 0)
end

-- ── native vault detection ───────────────────────────────────────────────────

T["workspace is detected via the .obsidian/ marker"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local ws = adapter.workspace_for_path(fixture_vault .. "/tasks_a.md")
  eq(type(ws), "table")
  eq(tostring(ws.root), fixture_vault)
end

-- ── native scan populates the index ──────────────────────────────────────────

local function count_all(idx)
  local n = 0
  for _ in
    idx.tasks_in(function()
      return true
    end)
  do
    n = n + 1
  end
  return n
end

T["refresh_all scans the vault with ripgrep and finds tasks"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local idx = require("obsidian-tasks.index")
  idx._reset()

  local ws = adapter.workspace_for_path(fixture_vault .. "/tasks_a.md")
  local done = false
  idx.refresh_all(ws, function()
    done = true
  end)
  vim.wait(3000, function()
    return done
  end, 25)

  eq(done, true)
  -- The fixture vault has many #task lines across several files.
  eq(count_all(idx) > 0, true)
end

T["ignored notes (tasks-plugin.ignore) are excluded via native frontmatter"] = function()
  local idx = require("obsidian-tasks.index")
  idx._reset()
  local adapter = require("obsidian-tasks.util.obsidian")
  local ws = adapter.workspace_for_path(fixture_vault .. "/tasks_a.md")

  local done = false
  idx.refresh_all(ws, function()
    done = true
  end)
  vim.wait(3000, function()
    return done
  end, 25)

  local ignored = fixture_vault .. "/ignored_note.md"
  for task, path in
    idx.tasks_in(function()
      return true
    end)
  do
    local _ = task
    eq(path ~= ignored, true)
  end
end

-- ── dashboard render end-to-end (no obsidian) ────────────────────────────────

T["a tasks dashboard renders results with obsidian.nvim absent"] = function()
  local render = require("obsidian-tasks.render")
  local idx = require("obsidian-tasks.index")
  local adapter = require("obsidian-tasks.util.obsidian")
  idx._reset()

  local dash = fixture_vault .. "/queries/by-tag.md"
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].filetype = "markdown"

  eq(render.has_tasks_block(buf), true)

  local ws = adapter.workspace_for_path(dash)
  render.render_buffer(buf, ws)

  -- render_buffer kicks an async vault walk on first render; wait for the index
  -- to populate (the dashboard re-renders from the on_done callback).
  vim.wait(3000, function()
    return count_all(idx) > 0
  end, 25)

  eq(count_all(idx) > 0, true)

  vim.api.nvim_buf_delete(buf, { force = true })
end

return T
