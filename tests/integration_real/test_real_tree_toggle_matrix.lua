-- tests/integration_real/test_real_tree_toggle_matrix.lua
-- Invariant-checked toggle SEQUENCES on a `show tree` dashboard, real vault.
--
-- The bugs in this area (stale linger snapshots, duplicate managed rows,
-- vanishing subtree branches, wrong dim state) all surfaced from SEQUENCES of
-- toggles across rerenders — paths no single-feature test walked.  Instead of
-- asserting one hand-picked outcome, every step here runs a consistency check
-- over the whole dashboard:
--
--   1. every rendered task row's checkbox symbol MATCHES its disk line
--      (catches: stale linger snapshot redrawing pre-edit state);
--   2. no two managed task rows map to the same (src_path, src_line)
--      (catches: linger/live duplicate rows → INSERT source corruption);
--   3. with a `not done` query: open tasks render LIT, done tasks render DIM
--      (catches: lingered block force-dimming a still-matching descendant);
--   4. no notifications fired (catches: spurious "source drift detected").
--
-- Plus per-step visibility assertions (catches: lingered branches vanishing).
--
-- See CLAUDE.md: real-mode behavior needs a child nvim (vim.schedule timing).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- The user's real shape: parent task, child task (markdown link with brackets
-- in the body), a nested bullet under the child, a sibling bullet under the
-- parent, and a DONE grandchild task under that bullet.
local DAILY = {
  "# 2026-05-30",
  "",
  "- [ ] how can i model this workflow around BDD, and how can i turn this into a skill (basically grill-me++)",
  "  - [ ] should this workflow include ADRs as part of its output (example [yak's ADRs](https://github.com/mattwynne/yaks/tree/main/docs/adr))",
  "    - nested note",
  "  - sibling note",
  "    - [x] done grandchild",
  "",
}
local PARENT_LNUM = 3
local CHILD_LNUM = 4
local GRANDCHILD_LNUM = 7

local ALL_NEEDLES = { "model this workflow", "include ADRs", "nested note", "sibling note", "done grandchild" }

local DASHBOARD = {
  "```tasks",
  "path includes daily/",
  "not done",
  "show tree",
  "```",
}

--- Boot a child nvim against a REAL temp vault (rg-backed index, no stubs).
local function spawn(dashboard_lines)
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
    _G._ws = ws
  end)(...)]],
    { DAILY, dashboard_lines or DASHBOARD }
  )

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

--- Run the whole-dashboard consistency check inside the child; returns a list
--- of human-readable violations (empty == consistent).
local function violations(child)
  return child.lua_get([[(function()
    local render = require("obsidian-tasks.render")
    local bufnr = _G._dash_bufnr
    local v = {}
    local seen = {}
    local disk_cache = {}
    local function disk(p)
      if not disk_cache[p] then
        local ok, lines = pcall(vim.fn.readfile, p)
        disk_cache[p] = ok and lines or {}
      end
      return disk_cache[p]
    end
    for _, blk in ipairs(render._buffer_state[bufnr] or {}) do
      for lnum, meta in pairs(blk.line_map or {}) do
        local text = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)[1] or ""
        local sym = text:match("^%s*[-*+] %[(.)%]")
        if meta.src_path and meta.src_line and sym ~= nil then
          local key = meta.src_path .. ":" .. meta.src_line
          if seen[key] ~= nil then
            v[#v + 1] = ("duplicate managed task rows for %s at rows %d and %d"):format(key, seen[key], lnum)
          end
          seen[key] = lnum
          local dline = disk(meta.src_path)[meta.src_line] or ""
          local dsym = dline:match("^%s*[-*+] %[(.)%]")
          if dsym ~= nil and dsym ~= sym then
            v[#v + 1] = ("row %d renders [%s] but disk line %d has [%s]"):format(lnum, sym, meta.src_line, dsym)
          end
          -- `not done` query over this fixture: every open task matches → LIT;
          -- every done task is context → DIM.
          if dsym == " " and meta.dim then
            v[#v + 1] = ("row %d: open task rendered DIM: %s"):format(lnum, text)
          end
          if dsym == "x" and not meta.dim then
            v[#v + 1] = ("row %d: done task rendered LIT: %s"):format(lnum, text)
          end
        end
      end
    end
    for _, m in ipairs(_G._notes) do
      v[#v + 1] = "notification: " .. m
    end
    return v
  end)()]])
end

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

local function dash_lines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
end

local function daily_src(child)
  return child.lua_get("vim.fn.readfile(_G._daily_path)")
end

--- Toggle the checkbox on the row containing *needle* (obsidian.nvim
--- smart_action shape: normal-mode line replace), then drain.
local function toggle(child, needle, from, to)
  local row = find_row(child, needle)
  eq(row >= 0, true, "row '" .. needle .. "' must be present to toggle: " .. vim.inspect(dash_lines(child)))
  child.lua(
    [[(function(row, from, to)
    local l = vim.api.nvim_buf_get_lines(_G._dash_bufnr, row, row + 1, false)[1]
    local new = l:gsub(vim.pesc(from), to, 1)
    vim.api.nvim_buf_set_lines(_G._dash_bufnr, row, row + 1, false, { new })
  end)(...)]],
    { row, from, to }
  )
  vim.loop.sleep(500)
end

--- Assert consistency + that every needle in *visible* is rendered.
local function check(child, step, visible)
  local v = violations(child)
  eq(#v, 0, step .. ": consistency violations: " .. vim.inspect(v))
  for _, needle in ipairs(visible or ALL_NEEDLES) do
    eq(
      find_row(child, needle) >= 0,
      true,
      step .. ": '" .. needle .. "' must be visible: " .. vim.inspect(dash_lines(child))
    )
  end
end

-- ── sequences ─────────────────────────────────────────────────────────────────

T["full cycle, parent first: P✓ C✓ C✗ P✗ — consistent at every step"] = function()
  local child = spawn()
  check(child, "initial")

  toggle(child, "model this workflow", "[ ]", "[x]")
  check(child, "after P done")

  toggle(child, "include ADRs", "[ ]", "[x]")
  check(child, "after C done")

  toggle(child, "include ADRs", "[x]", "[ ]")
  check(child, "after C undone")

  toggle(child, "model this workflow", "[x]", "[ ]")
  check(child, "after P undone")

  eq(daily_src(child), DAILY, "round trip must restore the exact original file")
  child.stop()
end

T["full cycle, child first: C✓ P✓ P✗ C✗ — consistent at every step"] = function()
  local child = spawn()

  toggle(child, "include ADRs", "[ ]", "[x]")
  check(child, "after C done")

  toggle(child, "model this workflow", "[ ]", "[x]")
  check(child, "after P done")

  toggle(child, "model this workflow", "[x]", "[ ]")
  check(child, "after P undone")

  toggle(child, "include ADRs", "[x]", "[ ]")
  check(child, "after C undone")

  eq(daily_src(child), DAILY, "round trip must restore the exact original file")
  child.stop()
end

T["double-toggle parent: P✓ P✗ — consistent, file restored"] = function()
  local child = spawn()

  toggle(child, "model this workflow", "[ ]", "[x]")
  check(child, "after P done")

  toggle(child, "model this workflow", "[x]", "[ ]")
  check(child, "after P undone")

  eq(daily_src(child), DAILY, "round trip must restore the exact original file")
  child.stop()
end

T["un-toggle the dim DONE grandchild: goes lit, disk updates, round-trips"] = function()
  local child = spawn()

  -- D5: dim rows are editable.  The done grandchild sits dim inside the live
  -- parent's subtree; un-toggling it must write through and re-render it lit.
  toggle(child, "done grandchild", "[x]", "[ ]")
  check(child, "after grandchild undone")
  local src = daily_src(child)
  eq(
    src[GRANDCHILD_LNUM]:find("%[ %]") ~= nil,
    true,
    "grandchild must be [ ] on disk: " .. tostring(src[GRANDCHILD_LNUM])
  )

  toggle(child, "done grandchild", "[ ]", "[x]")
  check(child, "after grandchild re-done")
  eq(daily_src(child), DAILY, "round trip must restore the exact original file")
  child.stop()
end

T["edit child description inside the lingered block: writes through, stays consistent"] = function()
  local child = spawn()

  toggle(child, "model this workflow", "[ ]", "[x]")
  check(child, "after P done")

  -- Replace a word on the (still lit) child row inside the lingered block.
  local row = find_row(child, "include ADRs")
  eq(row >= 0, true, "child row must be present")
  child.lua(
    [[(function(row)
    local l = vim.api.nvim_buf_get_lines(_G._dash_bufnr, row, row + 1, false)[1]
    local new = l:gsub("include ADRs", "include DECISIONS", 1)
    vim.api.nvim_buf_set_lines(_G._dash_bufnr, row, row + 1, false, { new })
  end)(...)]],
    { row }
  )
  vim.loop.sleep(500)

  local src = daily_src(child)
  eq(
    src[CHILD_LNUM]:find("include DECISIONS", 1, true) ~= nil,
    true,
    "child description edit must write through: " .. tostring(src[CHILD_LNUM])
  )
  eq(src[CHILD_LNUM]:sub(1, 2), "  ", "child must keep its 2-space indent")
  check(
    child,
    "after child description edit",
    { "model this workflow", "include DECISIONS", "nested note", "sibling note", "done grandchild" }
  )
  child.stop()
end

T["<leader>tr mid-state: lingers clear, then further toggles stay consistent"] = function()
  local child = spawn()

  toggle(child, "model this workflow", "[ ]", "[x]")
  check(child, "after P done")

  child.lua([[require("obsidian-tasks.render").refresh_with_clear_lingers(_G._dash_bufnr, _G._ws)]])
  vim.loop.sleep(500)

  -- After refresh the linger is gone: the still-open child renders as a lit
  -- root with the done parent as its dim breadcrumb; the parent's OTHER branch
  -- (sibling note / done grandchild) is correctly out of the induced forest.
  check(child, "after tr", { "model this workflow", "include ADRs", "nested note" })
  eq(find_row(child, "sibling note"), -1, "non-matching branch must drop after explicit refresh")

  toggle(child, "include ADRs", "[ ]", "[x]")
  check(child, "after C done post-tr", { "model this workflow", "include ADRs", "nested note" })

  local src = daily_src(child)
  eq(src[CHILD_LNUM]:find("%[x%]") ~= nil, true, "child must be [x] on disk: " .. tostring(src[CHILD_LNUM]))
  eq(src[PARENT_LNUM]:find("%[x%]") ~= nil, true, "parent must still be [x] on disk")
  child.stop()
end

T["grouped tree block (group by heading): P✓ C✓ P✗ — consistent at every step"] = function()
  local child = spawn({
    "```tasks",
    "path includes daily/",
    "not done",
    "group by heading",
    "show tree",
    "```",
  })

  toggle(child, "model this workflow", "[ ]", "[x]")
  check(child, "after P done")

  toggle(child, "include ADRs", "[ ]", "[x]")
  check(child, "after C done")

  toggle(child, "model this workflow", "[x]", "[ ]")
  check(child, "after P undone")

  local src = daily_src(child)
  eq(#src, #DAILY, "no source-line duplication: " .. vim.inspect(src))
  child.stop()
end

return T
