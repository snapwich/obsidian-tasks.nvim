-- tests/integration_obsidian/test_daily_note_create.lua
-- Plan D5 (group-top insert): with real obsidian.nvim loaded and no
-- `daily_note` option, the default daily-note resolver gives obsidian.nvim's
-- daily note path, and a missing daily note is created BY obsidian.nvim, so its
-- daily template and frontmatter apply.  The group-top task then goes into the
-- template's heading section.
--
-- A child Neovim with its own temp vault keeps the shared fixture vault clean
-- (the write creates daily/<today>.md).  The gesture is real input (`O` +
-- typing + <Esc>), per CLAUDE.md.

local T = MiniTest.new_set()

local function eq(actual, expected, msg)
  local ok, err = pcall(MiniTest.expect.equality, actual, expected)
  if not ok then
    error((msg and (tostring(msg) .. "\n") or "") .. tostring(err), 2)
  end
end

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

T["group-top insert creates the daily note through obsidian.nvim (template + frontmatter)"] = function()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/obsidian.nvim")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end

    local vault = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()) .. "-vault")
    for _, d in ipairs({ "/.obsidian", "/templates", "/projects", "/daily" }) do
      vim.fn.mkdir(vault .. d, "p")
    end
    vim.fn.writefile({ "# {{title}}", "", "## technical debt" }, vault .. "/templates/daily.md")
    vim.fn.writefile({
      "## refactoring",
      "- [ ] Refactor A #task",
      "## technical debt",
      "- [ ] Debt B #task",
      "- [ ] Debt C #task",
    }, vault .. "/projects/work.md")
    vim.fn.writefile(
      { "# Dashboard", "", "```tasks", "not done", "group by heading", "```", "", "Trailing prose." },
      vault .. "/dashboard.md"
    )
    _G._vault = vault

    require("obsidian").setup({
      workspaces = { { name = "tmp-vault", path = vault } },
      log_level = vim.log.levels.ERROR,
      completion = { nvim_cmp = false, blink = false },
      picker = { name = nil },
      ui = { enable = false },
      templates = { folder = "templates" },
      daily_notes = { folder = "daily", template = "daily.md", workdays_only = false },
    })
    require("obsidian-tasks").setup({ global_filter = "#task" })

    _G._msgs = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, o)
      _G._msgs[#_G._msgs + 1] = msg
      return orig_notify(msg, level, o)
    end

    local index = require("obsidian-tasks.index")
    local ws = require("obsidian-tasks.util.obsidian").workspace_for_path(vault .. "/dashboard.md")
    local done = false
    index.refresh_all(ws, function() done = true end)
    vim.wait(5000, function() return done end)
    index.refresh_all = function(_, on_done) if on_done then on_done() end end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(vault .. "/dashboard.md"))
    local b = vim.api.nvim_get_current_buf()
    vim.b[b].obsidian_tasks_dashboard = true
    vim.bo[b].autoindent = false
    render.render_buffer(b, ws)
    vim.cmd("normal! zR")
    _G._b = b
  ]],
    { cwd, deps_dir }
  )

  local daily = child.lua_get([[vim.fs.normalize(tostring((require("obsidian.daily").daily_note_path(os.time()))))]])
  eq(daily, child.lua_get("_G._vault") .. "/daily/" .. os.date("%Y-%m-%d") .. ".md", "obsidian.nvim daily path")
  eq(child.lua_get("vim.fn.filereadable(...)", { daily }), 0, "the daily note is missing before the insert")

  local row = child.lua_get([[(function()
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
      if l:find("Debt B", 1, true) then return i - 1 end
    end
    return -1
  end)()]])
  eq(row >= 0, true, "Debt B is rendered")
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.loop.sleep(50)
  child.type_keys("<Ignore>")
  vim.loop.sleep(50)
  child.type_keys("O", "New debt", "<Esc>")
  vim.loop.sleep(700)

  local lines = child.lua_get("vim.fn.readfile(...)", { daily })
  eq(lines[1], "---", "obsidian.nvim wrote frontmatter: " .. vim.inspect(lines))
  local h
  for i, l in ipairs(lines) do
    if l == "## technical debt" then
      h = i
    end
  end
  eq(h ~= nil, true, "the template heading is in the note: " .. vim.inspect(lines))
  eq(
    { lines[h + 1], lines[h + 2] },
    { "", "- [ ] New debt #task" },
    "task in the template's section: " .. vim.inspect(lines)
  )
  eq(#vim.tbl_filter(function(l)
    return l:find("{{title}}", 1, true) ~= nil
  end, lines), 0, "template substitutions ran: " .. vim.inspect(lines))

  local msgs = child.lua_get("_G._msgs")
  local created = false
  for _, m in ipairs(msgs) do
    if m:find("› ## technical debt (created)", 1, true) then
      created = true
    end
  end
  eq(created, true, vim.inspect(msgs))

  -- The invariant: the new task shows in the technical debt group.
  local shown = child.lua_get([[(function()
    local ns = require("obsidian-tasks.util.extmark").NS
    local lines = vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)
    local row
    for i, l in ipairs(lines) do
      if l:find("New debt", 1, true) then row = i - 1 end
    end
    if not row then return "missing" end
    local header, best = nil, -1
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(_G._b, ns, 0, -1, { details = true })) do
      if m[2] <= row and m[2] >= best then
        for _, chunks in ipairs(m[4].virt_lines or {}) do
          for _, c in ipairs(chunks) do
            if c[2] == "ObsidianTasksGroupHeader" then best, header = m[2], c[1] end
          end
        end
      end
    end
    return header
  end)()]])
  eq(shown, "## technical debt", vim.inspect(child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")))
  child.stop()
end

return T
