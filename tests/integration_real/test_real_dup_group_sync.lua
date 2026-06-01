-- tests/integration_real/test_real_dup_group_sync.lua
-- Editing ONE instance of a task that renders under MULTIPLE groups must sync
-- ALL instances LIVE (on InsertLeave / normal-mode flush), not only on :w.
--
-- Bug: with `group by tags`, one source task that carries two tags renders as
-- TWO rows in the dashboard (one per group).  Editing ONE rendered row writes
-- back to source, but the OTHER instance stayed stale until :w forced a full
-- re-render.  The fix issues a single canonical rerender at the end of flush
-- when an applied edit was a MUTATE, so every instance picks up the new
-- text/tags AND a newly-added tag re-groups the task.  Driven through REAL
-- keypresses (child_neovim + type_keys), mirroring test_real_sentinel_newline.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local function buflines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")
end

--- Count dashboard rows whose text contains *needle* (substring match).
local function count_rows(child, needle)
  return child.lua_get(string.format(
    [[(function()
        local n = 0
        for _, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
          if l and l:find(%q, 1, true) then n = n + 1 end
        end
        return n
      end)()]],
    needle
  ))
end

--- Find the 0-indexed dashboard row containing *needle* (first match).
local function find_row(child, needle)
  return child.lua_get(string.format(
    [[(function()
        local lines = vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)
        for i, l in ipairs(lines) do
          if l and l:find(%q, 1, true) then return i - 1 end
        end
        return -1
      end)()]],
    needle
  ))
end

-- A dashboard grouped `by tags` over a single source task carrying two tags.
-- The real query layer duplicates the task into one group per tag, so it
-- renders under BOTH the #alpha and #beta groups (two instances).
local function spawn()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    -- No global filter: a status flip must NOT drop the task from the result set
    -- (both instances must stay visible so we can prove they synced).
    require("obsidian-tasks").setup({})

    -- A separate source file holds the ONE matching task carrying two tags; the
    -- dashboard note is file-backed so the first render's save.attach can set the
    -- dashboard flag + BufWriteCmd handler.
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "- [ ] dup task #alpha #beta" }, src)
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "```tasks", "group by tags", "```" }, note)

    local index = require("obsidian-tasks.index")
    local tp = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function() return {} end
    -- Re-read source on every call so a post-edit refresh yields the updated task
    -- (new checkbox + new tag) → the query re-groups by the new tag set.
    index.tasks_in = function()
      local lines = vim.fn.readfile(src)
      local items = {}
      for ln, line in ipairs(lines) do
        local t = tp.parse(line)
        if t then items[#items + 1] = { t = t, ln = ln } end
      end
      local i = 0
      return function()
        i = i + 1
        if items[i] then return items[i].t, src, items[i].ln end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    -- Let the first render's draw → save.attach set obsidian_tasks_dashboard.
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

T["dup-group rows sync LIVE: edit one instance toggles status + adds tag for ALL, re-groups"] = function()
  local child = spawn()

  -- Two instances of the one task: one under #alpha, one under #beta.
  eq(count_rows(child, "dup task"), 2, "task must render under BOTH tag groups: " .. vim.inspect(buflines(child)))
  eq(count_rows(child, "[ ]"), 2, "both instances start unchecked: " .. vim.inspect(buflines(child)))

  -- ── Edit ONE instance: toggle the checkbox, then add a third tag #gamma ──────
  -- (1) status: replace the box's space with 'x' on the first instance.
  local row = find_row(child, "dup task")
  eq(row >= 0, true, "an instance row must exist")
  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._b, " .. row .. ", " .. row + 1 .. ", false)[1]")
  local box_byte = line:find("%[ %]") -- 1-indexed col of '['; the space is +1
  eq(box_byte ~= nil, true, "rendered row must have an empty checkbox: [" .. (line or "nil") .. "]")
  child.api.nvim_win_set_cursor(0, { row + 1, box_byte }) -- on the space inside [ ]
  child.type_keys("r", "x")
  vim.loop.sleep(300)

  -- (2) tag: insert " #gamma" right before the ' [[' wikilink suffix (or EOL).
  local row2 = find_row(child, "dup task")
  local line2 = child.lua_get("vim.api.nvim_buf_get_lines(_G._b, " .. row2 .. ", " .. row2 + 1 .. ", false)[1]")
  local suffix_byte = line2:find(" %[%[") -- 1-indexed col of the wikilink suffix
  local insert_col = suffix_byte and (suffix_byte - 1) or #line2 -- 0-indexed insert point
  child.api.nvim_win_set_cursor(0, { row2 + 1, insert_col })
  child.type_keys("i", " #gamma", "<Esc>")
  vim.loop.sleep(400)

  -- ── Assert WITHOUT :w ───────────────────────────────────────────────────────
  -- Source committed both edits.
  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("%[x%]") ~= nil, true, "source checkbox toggled to [x]: [" .. (disk[1] or "nil") .. "]")
  eq(disk[1]:find("#gamma") ~= nil, true, "source gained #gamma: [" .. (disk[1] or "nil") .. "]")

  local after = buflines(child)
  -- Both rendered instances reflect the new status: no '[ ]' instance remains,
  -- every dup-task row now shows '[x]'.
  eq(count_rows(child, "[ ]"), 0, "no instance may stay unchecked after the live sync: " .. vim.inspect(after))

  -- The new tag re-grouped the task: it now renders under THREE tag groups
  -- (#alpha, #beta, #gamma) — three instances, all checked.
  eq(count_rows(child, "dup task"), 3, "new tag must re-group into a third instance: " .. vim.inspect(after))
  eq(count_rows(child, "[x]"), 3, "all three instances reflect the toggled status: " .. vim.inspect(after))

  local src = child.lua_get("_G._src")
  local note = child.lua_get("_G._note")
  child.stop()
  pcall(vim.fn.delete, src)
  pcall(vim.fn.delete, note)
end

-- ── single instance → new tag must CREATE a new group LIVE ───────────────────
-- The reported bug: a task that starts in ONE group (single instance, so there
-- is no pre-existing duplicate to key on) gains a tag for a group that does not
-- exist yet.  The new group + instance must appear immediately, not only on :w.
-- This is the case a duplicate-only gate misses; the gate must trigger on the
-- presence of `group by`, not on a pre-existing duplicate.

local function spawn_single()
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    require("obsidian-tasks").setup({})

    -- ONE source task carrying a SINGLE tag → renders as a SINGLE instance under
    -- the #alpha group.  No pre-existing duplicate exists.
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "- [ ] solo task #alpha" }, src)
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "```tasks", "group by tags", "```" }, note)

    local index = require("obsidian-tasks.index")
    local tp = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function() return {} end
    index.tasks_in = function()
      local lines = vim.fn.readfile(src)
      local items = {}
      for ln, line in ipairs(lines) do
        local t = tp.parse(line)
        if t then items[#items + 1] = { t = t, ln = ln } end
      end
      local i = 0
      return function()
        i = i + 1
        if items[i] then return items[i].t, src, items[i].ln end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
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

T["single instance: adding a tag for a NEW group creates it LIVE (no pre-existing dup)"] = function()
  local child = spawn_single()

  -- Exactly ONE instance to start: only the #alpha group.
  eq(count_rows(child, "solo task"), 1, "task starts as a single instance: " .. vim.inspect(buflines(child)))

  -- Add a second tag #beta on the only instance, just before the ' [[' suffix.
  local row = find_row(child, "solo task")
  eq(row >= 0, true, "the instance row must exist")
  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._b, " .. row .. ", " .. row + 1 .. ", false)[1]")
  local suffix_byte = line:find(" %[%[")
  local insert_col = suffix_byte and (suffix_byte - 1) or #line
  child.api.nvim_win_set_cursor(0, { row + 1, insert_col })
  child.type_keys("i", " #beta", "<Esc>")
  vim.loop.sleep(400)

  -- WITHOUT :w — source committed the tag, and the dashboard re-grouped: the task
  -- now renders under BOTH #alpha and #beta (two instances).
  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("#beta") ~= nil, true, "source gained #beta: [" .. (disk[1] or "nil") .. "]")

  local after = buflines(child)
  eq(count_rows(child, "solo task"), 2, "new tag must create a second group LIVE: " .. vim.inspect(after))

  local src = child.lua_get("_G._src")
  local note = child.lua_get("_G._note")
  child.stop()
  pcall(vim.fn.delete, src)
  pcall(vim.fn.delete, note)
end

return T
