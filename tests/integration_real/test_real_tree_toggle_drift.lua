-- tests/integration_real/test_real_tree_toggle_drift.lua
-- Regression: sequential checkbox toggles on a `show tree` dashboard, real vault.
--
-- Mirrors a user-reported bug with this exact shape:
--   • vault: daily/2026-05-30.md holds a top-level task + 2-space child task
--     (no global filter; the child's text contains a markdown link with
--     brackets), tasks.md holds TWO ```tasks blocks — the first ungrouped
--     (`path includes daily/` + `not done` + `show tree`), the second with
--     `group by heading` (so flush's has_grouping rerender path is live).
--   • Toggle the parent [ ]→[x] in the dashboard (normal-mode line replace,
--     the same buffer edit obsidian.nvim's smart_action <CR> makes).  Works.
--   • Toggle the child the same way.  BUG: the edit is committed-then-reverted
--     and every retry warns "source drift detected — run <leader>tr".
--   • After both are [x], un-toggling the parent DUPLICATES the child line
--     above the parent in the source file.
--
-- See CLAUDE.md: real-mode behavior needs a child nvim (vim.schedule timing).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local PARENT =
  "- [ ] how can i model this workflow around BDD, and how can i turn this into a skill (basically grill-me++)"
local CHILD =
  "  - [ ] should this workflow include ADRs as part of its output (example [yak's ADRs](https://github.com/mattwynne/yaks/tree/main/docs/adr))"

local DAILY = {
  "# 2026-05-30",
  "",
  "some prose above the tasks.",
  "",
  PARENT,
  CHILD,
  "",
  "trailing prose.",
}
local PARENT_LNUM = 5
local CHILD_LNUM = 6

local DASHBOARD = {
  "## open tasks from daily notes",
  "```tasks",
  "path includes daily/",
  "sort by filename reverse",
  "not done",
  "show tree",
  "```",
  "",
  "## projects",
  "```tasks",
  "path does not include daily/",
  "group by heading",
  "group by tags",
  "sort by priority",
  "not done",
  "show tree",
  "```",
}

--- Boot a child nvim against a REAL temp vault (rg-backed index, no stubs).
--- *daily_lines* overrides the daily note's content (defaults to DAILY).
local function spawn_vault_dashboard(daily_lines)
  daily_lines = daily_lines or DAILY
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian-tasks").setup({})

    _G._notes = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, opts)
      _G._notes[#_G._notes + 1] = tostring(msg)
      return orig_notify(msg, level, opts)
    end
  ]],
    { cwd, deps_dir }
  )

  child.lua(
    [[(function(daily, dashboard)
    local vault = vim.fn.tempname()
    vim.fn.mkdir(vault .. "/.obsidian", "p")
    vim.fn.mkdir(vault .. "/daily", "p")
    local daily_path = vault .. "/daily/2026-05-30.md"
    local dash_path = vault .. "/tasks.md"
    vim.fn.writefile(daily, daily_path)
    vim.fn.writefile(dashboard, dash_path)

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = "markdown"
    local ws = require("obsidian-tasks.util.obsidian").workspace_for_path(dash_path)
    require("obsidian-tasks.render").render_buffer(bufnr, ws)

    _G._dash_bufnr = bufnr
    _G._daily_path = daily_path
    _G._vault = vault
  end)(...)]],
    { daily_lines, DASHBOARD }
  )

  -- Wait for the async rg walk + render to land the parent row in the buffer.
  local ok = false
  for _ = 1, 50 do
    vim.loop.sleep(100)
    local found = child.lua_get([[(function()
      for _, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
        if l:find("model this workflow", 1, true) then return true end
      end
      return false
    end)()]])
    if found then
      ok = true
      break
    end
  end
  eq(ok, true, "dashboard must render the parent task")
  child.cmd("normal! zR")

  return child
end

--- 0-based dashboard row whose text contains *needle* (-1 if absent).
local function find_row(child, needle)
  return child.lua_get(
    [[(function(needle)
    local lines = vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)
    for i, l in ipairs(lines) do
      if l:find(needle, 1, true) then return i - 1 end
    end
    return -1
  end)(...)]],
    { needle }
  )
end

--- Toggle the checkbox on dashboard row *row0* the way obsidian.nvim's
--- smart_action <CR> does: replace the line in normal mode.
local function toggle_row(child, row0, from, to)
  child.lua(
    [[(function(row, from, to)
    local l = vim.api.nvim_buf_get_lines(_G._dash_bufnr, row, row + 1, false)[1]
    local new = l:gsub(vim.pesc(from), to, 1)
    vim.api.nvim_buf_set_lines(_G._dash_bufnr, row, row + 1, false, { new })
  end)(...)]],
    { row0, from, to }
  )
  vim.loop.sleep(500)
end

local function daily_src(child)
  return child.lua_get("vim.fn.readfile(_G._daily_path)")
end

local function dash_lines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
end

local function drift_warnings(child)
  return child.lua_get([[(function()
    local n = 0
    for _, m in ipairs(_G._notes) do
      if m:find("drift", 1, true) then n = n + 1 end
    end
    return n
  end)()]])
end

T["toggle parent then child: both commit, no drift warning"] = function()
  local child = spawn_vault_dashboard()

  local prow = find_row(child, "model this workflow")
  eq(prow >= 0, true, "parent row must render: " .. vim.inspect(dash_lines(child)))
  toggle_row(child, prow, "[ ]", "[x]")

  local src = daily_src(child)
  eq(src[PARENT_LNUM]:find("%[x%]") ~= nil, true, "parent must be [x] on disk: " .. tostring(src[PARENT_LNUM]))
  eq(src[CHILD_LNUM], CHILD, "child line untouched by parent toggle: " .. tostring(src[CHILD_LNUM]))

  local crow = find_row(child, "include ADRs")
  eq(crow >= 0, true, "child row must still render: " .. vim.inspect(dash_lines(child)))
  toggle_row(child, crow, "[ ]", "[x]")

  src = daily_src(child)
  eq(#src, #DAILY, "daily note must keep its line count: " .. vim.inspect(src))
  eq(src[CHILD_LNUM]:find("%[x%]") ~= nil, true, "child must be [x] on disk: " .. tostring(src[CHILD_LNUM]))
  eq(src[CHILD_LNUM]:sub(1, 2), "  ", "child must keep its 2-space indent: " .. tostring(src[CHILD_LNUM]))

  -- The dashboard must NOT redraw the child back to [ ] (the original bug: the
  -- kept linger replayed its promotion-time subtree snapshot over the flushed
  -- row, visually undoing the toggle and poisoning the row meta so every
  -- following toggle false-positived the drift check).
  crow = find_row(child, "include ADRs")
  eq(crow >= 0, true, "child row must still render: " .. vim.inspect(dash_lines(child)))
  local crow_text =
    child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. crow .. ", " .. crow + 1 .. ", false)[1]")
  eq(crow_text:find("%[x%]") ~= nil, true, "dashboard child row must stay [x]: " .. tostring(crow_text))
  eq(drift_warnings(child), 0, "no drift warning expected; notes: " .. child.lua_get("vim.inspect(_G._notes)"))

  -- Toggling the (now correctly-rendered) child back must also work — before
  -- the fix every retry hit "source drift detected" and reverted.
  toggle_row(child, crow, "[x]", "[ ]")
  src = daily_src(child)
  eq(src[CHILD_LNUM], CHILD, "child must toggle back cleanly: " .. tostring(src[CHILD_LNUM]))
  eq(drift_warnings(child), 0, "still no drift warning; notes: " .. child.lua_get("vim.inspect(_G._notes)"))

  child.stop()
end

T["complete the parent: non-matching subtree branches stay visible (lingered block)"] = function()
  -- The parent's subtree has branches that are visible ONLY because the parent
  -- matched: a plain bullet ("- test") and a done grandchild task.  When the
  -- parent is toggled Done it must linger as a WHOLE subtree block — being kept
  -- visible as the still-matching child's connector breadcrumb is NOT enough
  -- (the breadcrumb carries only the ancestor chain, so the other branches
  -- would vanish until refresh).
  local daily = {
    "# 2026-05-30",
    "",
    PARENT,
    CHILD,
    "    - nested note",
    "  - sibling note",
    "    - [x] done grandchild",
    "",
  }
  local child = spawn_vault_dashboard(daily)

  local prow = find_row(child, "model this workflow")
  toggle_row(child, prow, "[ ]", "[x]")

  local dash = dash_lines(child)
  for _, needle in ipairs({ "include ADRs", "nested note", "sibling note", "done grandchild" }) do
    eq(
      find_row(child, needle) >= 0,
      true,
      "subtree row '" .. needle .. "' must stay visible after parent toggle: " .. vim.inspect(dash)
    )
  end
  eq(drift_warnings(child), 0, "no drift warning expected; notes: " .. child.lua_get("vim.inspect(_G._notes)"))

  -- The lingered block stays editable: toggle the (still not-done) child too.
  toggle_row(child, find_row(child, "include ADRs"), "[ ]", "[x]")
  local src = daily_src(child)
  eq(src[4]:find("%[x%]") ~= nil, true, "child must be [x] on disk: " .. tostring(src[4]))
  eq(drift_warnings(child), 0, "still no drift warning; notes: " .. child.lua_get("vim.inspect(_G._notes)"))

  child.stop()
end

T["both done → un-toggle parent: no duplicated child line in source"] = function()
  local child = spawn_vault_dashboard()

  toggle_row(child, find_row(child, "model this workflow"), "[ ]", "[x]")
  toggle_row(child, find_row(child, "include ADRs"), "[ ]", "[x]")

  local prow = find_row(child, "model this workflow")
  eq(prow >= 0, true, "parent row must still render: " .. vim.inspect(dash_lines(child)))
  toggle_row(child, prow, "[x]", "[ ]")

  local src = daily_src(child)
  eq(#src, #DAILY, "daily note must keep its line count (no duplication): " .. vim.inspect(src))
  local child_count = 0
  for _, l in ipairs(src) do
    if l:find("include ADRs", 1, true) then
      child_count = child_count + 1
    end
  end
  eq(child_count, 1, "child line must appear exactly once: " .. vim.inspect(src))
  eq(src[PARENT_LNUM]:find("%[ %]") ~= nil, true, "parent must be back to [ ]: " .. tostring(src[PARENT_LNUM]))

  child.stop()
end

return T
