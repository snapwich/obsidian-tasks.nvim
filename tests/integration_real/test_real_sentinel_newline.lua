-- tests/integration_real/test_real_sentinel_newline.lua
-- Pressing <CR> on the EOF sentinel adds a REAL file newline, not a dashboard row.
--
-- The sentinel is a single empty managed row at EOF, BELOW the virtual footer —
-- it is outside the dashboard.  A <CR> there is the user adding a newline to the
-- end of the file: it must persist (and save), and the now-unneeded sentinel is
-- released (a real EOF line separates our footer from obsidian.nvim's).  Earlier
-- the blank rows were absorbed into the managed region and stripped on the next
-- render — losing the newline.  Driven through REAL keypresses.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local function buflines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")
end

local function managed_regions(child)
  return child.lua_get("require('obsidian-tasks.render.managed').all_regions(_G._b)")
end

-- ── (A) zero-result dashboard ────────────────────────────────────────────────

local function spawn_zero()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "```tasks", "path includes NONE", "```" }, note)
    local index = require("obsidian-tasks.index")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function() return {} end
    index.tasks_in = function() return function() return nil end end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    -- Let the first render's draw → save.attach set obsidian_tasks_dashboard AND
    -- register the BufWriteCmd strip handler (pre-setting the flag would skip it).
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._b = b
    _G._note = note
  ]],
    { cwd, deps_dir }
  )
  return child
end

T["zero-result: <CR> on the sentinel adds real newlines that survive refocus + :w"] = function()
  local child = spawn_zero()
  -- Buffer: 0 '# Daily', 1 '```tasks', 2 'path includes NONE', 3 '```', 4 sentinel.
  child.api.nvim_win_set_cursor(0, { 5, 0 }) -- sentinel (1-indexed line 5)
  child.type_keys("i", "<CR>", "<CR>", "<Esc>")
  vim.loop.sleep(450)

  -- The inserted blanks are released from management: no managed region remains
  -- (zero-result dashboards drop the region once a real EOF line exists).
  eq(managed_regions(child), {}, "the grown sentinel region must be released")

  local b = buflines(child)
  -- Three trailing blank lines: the original sentinel (now real) split by two
  -- <CR>s.  The closing fence is unchanged.
  eq(b[4], "```", "closing fence intact")
  eq(b[5], "", "newline 1 persisted")
  eq(b[6], "", "newline 2 persisted")
  eq(b[7], "", "newline 3 persisted")
  eq(#b, 7, "exactly the fence rows + three real blank lines: " .. vim.inspect(b))

  -- A refocus re-render must NOT strip them (this was the data-loss path).
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(200)
  eq(#buflines(child), 7, "refocus must keep the real newlines: " .. vim.inspect(buflines(child)))

  -- And :w persists them to disk.
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(150)
  local disk = child.lua_get("vim.fn.readfile(_G._note)")
  eq(
    disk,
    { "# Daily", "```tasks", "path includes NONE", "```", "", "", "" },
    "newlines on disk: " .. vim.inspect(disk)
  )

  child.stop()
end

-- ── (B) results dashboard: newline lands below the footer, task untouched ─────

local function spawn_with_task()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })
    -- A separate source file holds the one matching task; the dashboard note is
    -- file-backed so :w round-trips.
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "- [ ] the only task #task" }, src)
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "```tasks", "not done", "```" }, note)
    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local tp = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function(p)
      if p == src then return nodes_mod.parse_lines(vim.fn.readfile(src)) end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then return tp.parse(vim.fn.readfile(src)[1]), src, 1 end
      end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    -- Do NOT pre-set obsidian_tasks_dashboard: the first render's draw → save.attach
    -- both sets that flag AND registers the BufWriteCmd strip handler.  Pre-setting
    -- it makes save.attach a no-op (idempotent on the flag), so :w would fall back
    -- to Neovim's default writer and never strip the rendered task row.
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._b = b
    _G._note = note
    _G._src = src
  ]],
    { cwd, deps_dir }
  )
  return child
end

T["results: <CR> on the sentinel keeps the task + persists the newline below the footer"] = function()
  local child = spawn_with_task()
  -- Buffer: 0 '# Daily',1 '```tasks',2 'not done',3 '```',4 rendered task,5 sentinel.
  local b0 = buflines(child)
  eq(b0[5]:sub(1, #"- [ ] the only task"), "- [ ] the only task", "task is rendered: " .. vim.inspect(b0))

  child.api.nvim_win_set_cursor(0, { 6, 0 }) -- sentinel (1-indexed line 6)
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(450)

  local b = buflines(child)
  -- The rendered task row is untouched; two trailing blank lines persist below it.
  eq(b[5]:sub(1, #"- [ ] the only task"), "- [ ] the only task", "task row preserved: " .. vim.inspect(b))
  eq(b[6], "", "real newline 1 below the task")
  eq(b[7], "", "real newline 2 below the task")
  eq(#b, 7, "task + two real blank lines: " .. vim.inspect(b))

  -- :w strips the rendered task row (managed) but keeps the real blank lines.
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(150)
  local disk = child.lua_get("vim.fn.readfile(_G._note)")
  eq(disk, { "# Daily", "```tasks", "not done", "```", "", "" }, "blanks persist, task stripped: " .. vim.inspect(disk))
  -- The source task file is untouched by all of this.
  eq(child.lua_get("vim.fn.readfile(_G._src)"), { "- [ ] the only task #task" }, "source task file unchanged")

  child.stop()
end

return T
