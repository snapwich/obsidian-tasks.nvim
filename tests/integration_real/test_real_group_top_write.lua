-- tests/integration_real/test_real_group_top_write.lua
-- Real-input coverage for the group-top write path (plan D3–D9, ADR 0005).
--
-- A task typed or pasted in a group-top slot has no anchor, so it goes to the
-- daily note (or, for a filename group, to that file), at the place that keeps
-- it in the group where the user typed it:
--
--   heading         → the daily note, in that heading's section (created when
--                     missing, at the level of the real heading line);
--   (No heading)    → the daily note, before its first heading;
--   tags / priority / status → the daily note, end of file + group attribute;
--   filename        → the end of that file;
--   folder / path / root → the below-fence fallback + a warning;
--   ungrouped / zero-result dashboard → the daily note, end of file.
--
-- Every scenario ends with assert_in_group: after the rerender, the new task
-- shows under the group header where the user typed it (the core invariant).
--
-- The vault is a real temp folder with a `.obsidian/` marker and the REAL index
-- (one ripgrep walk at spawn), so a daily note that the write creates is only
-- visible when the write path indexes it explicitly.  The daily-note resolver
-- is a custom function that gives <vault>/daily/2026-10-11.md.
--
-- See CLAUDE.md: these tests drive a child Neovim with type_keys + sleep; they
-- never edit the dashboard with nvim_buf_set_lines.

local T = MiniTest.new_set()

--- Equality with the context message in the failure report.
local function eq(actual, expected, msg)
  local ok, err = pcall(MiniTest.expect.equality, actual, expected)
  if not ok then
    error((msg and (tostring(msg) .. "\n") or "") .. tostring(err), 2)
  end
end

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

local DAILY_REL = "daily/2026-10-11.md"

local WORK = {
  "## refactoring",
  "- [ ] Refactor A #task",
  "- [ ] Refactor A2 #task",
  "## technical debt",
  "- [ ] Debt B #task",
  "- [ ] Debt C #task",
}

--- Spawn a child Neovim over a temp vault and render `dashboard.md`.
---
--- @param opts table
---   files     { [rel] = lines }  notes to create in the vault
---   query     string[]           body of the ```tasks fence
---   daily     string[]|nil       an existing daily note (nil = missing)
---   resolver  boolean|nil        false → opts.daily_note = false
---   setup     table|nil          extra obsidian-tasks setup opts
---   no_trailing boolean|nil      true → the closing fence is the last line
local function spawn(opts)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
  ]],
    { cwd, deps_dir }
  )

  child.lua(
    [[(function(o)
    local files, query, daily, use_resolver, daily_rel, extra = o.files, o.query, o.daily, o.resolver, o.daily_rel, o.extra
    local vault = vim.fs.normalize(vim.fn.resolve(vim.fn.tempname()) .. "-vault")
    vim.fn.mkdir(vault .. "/.obsidian", "p")
    local function put(rel, lines)
      local p = vault .. "/" .. rel
      vim.fn.mkdir(vim.fs.dirname(p), "p")
      vim.fn.writefile(lines, p)
    end
    for rel, lines in pairs(files) do put(rel, lines) end
    if daily then put(daily_rel, daily) end
    _G._vault = vault
    _G._daily = vault .. "/" .. daily_rel

    local setup_opts = { global_filter = "#task" }
    if use_resolver == false then
      setup_opts.daily_note = false
    else
      setup_opts.daily_note = function() return _G._daily end
    end
    extra = extra or {}
    for k, v in pairs(extra) do
      if k ~= "__no_trailing" then setup_opts[k] = v end
    end
    require("obsidian-tasks").setup(setup_opts)

    _G._msgs = {}
    local orig_notify = vim.notify
    vim.notify = function(msg, level, o)
      _G._msgs[#_G._msgs + 1] = { msg = msg, level = level }
      return orig_notify(msg, level, o)
    end

    -- One real ripgrep walk, then a no-op refresh_all so the render's lazy
    -- walk cannot rerender at a random moment during the gesture.
    local index = require("obsidian-tasks.index")
    local ws = require("obsidian-tasks.util.obsidian").workspace_for_path(vault .. "/dashboard.md")
    local done = false
    index.refresh_all(ws, function() done = true end)
    vim.wait(5000, function() return done end)
    index.refresh_all = function(_, on_done) if on_done then on_done() end end

    local dash = vault .. "/dashboard.md"
    local fence = { "# Dashboard", "", "```tasks" }
    for _, q in ipairs(query) do fence[#fence + 1] = q end
    fence[#fence + 1] = "```"
    if not extra.__no_trailing then
      fence[#fence + 1] = ""
      fence[#fence + 1] = "Trailing prose."
    end
    extra.__no_trailing = nil
    vim.fn.writefile(fence, dash)

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash))
    local b = vim.api.nvim_get_current_buf()
    vim.b[b].obsidian_tasks_dashboard = true
    vim.bo[b].autoindent = false
    render.render_buffer(b, ws)
    vim.cmd("normal! zR")
    _G._b = b

    -- The group header label shown above 0-indexed *row* (nearest header at or
    -- above it), or nil when no header is above it.
    _G._header_above = function(row)
      local ns = require("obsidian-tasks.util.extmark").NS
      local best_row, best = -1, nil
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(b, ns, 0, -1, { details = true })) do
        if m[2] <= row and m[2] >= best_row then
          for _, chunks in ipairs(m[4].virt_lines or {}) do
            for _, c in ipairs(chunks) do
              if c[2] == "ObsidianTasksGroupHeader" then
                best_row, best = m[2], c[1]
              end
            end
          end
        end
      end
      return best
    end
  end)(...)]],
    {
      {
        files = opts.files or {},
        query = opts.query,
        daily = opts.daily,
        resolver = opts.resolver,
        daily_rel = DAILY_REL,
        extra = vim.tbl_extend("force", opts.setup or {}, { __no_trailing = opts.no_trailing or nil }),
      },
    }
  )
  return child
end

-- ── helpers ───────────────────────────────────────────────────────────────────

local function find_row(child, needle)
  return child.lua_get(
    [[(function(needle)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
        if l:find(needle, 1, true) then return i - 1 end
      end
      return -1
    end)(...)]],
    { needle }
  )
end

--- 0-indexed row that shows *needle* under the group header "## <group>"
--- (a task can show in several groups: the global filter "#task" is a tag too).
local function find_row_in_group(child, needle, group)
  return child.lua_get(
    [[(function(needle, header)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
        if l:find(needle, 1, true) and _G._header_above(i - 1) == header then return i - 1 end
      end
      return -1
    end)(...)]],
    { needle, "## " .. group }
  )
end

local function dash_lines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")
end

--- Lines of the vault file *rel*, or nil when it does not exist.
local function file_lines(child, rel)
  return child.lua_get(
    [[(function(rel)
      local p = _G._vault .. "/" .. rel
      if vim.fn.filereadable(p) == 0 then return vim.NIL end
      return vim.fn.readfile(p)
    end)(...)]],
    { rel }
  )
end

local function daily_lines(child)
  return file_lines(child, DAILY_REL)
end

local function msgs(child, level)
  local out = {}
  for _, m in ipairs(child.lua_get("_G._msgs")) do
    if level == nil or m.level == level then
      out[#out + 1] = m.msg
    end
  end
  return out
end

local function has_msg(child, needle, level)
  for _, m in ipairs(msgs(child, level)) do
    if m:find(needle, 1, true) then
      return true
    end
  end
  return false
end

local INFO, WARN = vim.log.levels.INFO, vim.log.levels.WARN

--- Put the cursor on the row that shows *needle* (under the header "## <group>"
--- when *group* is given) and let CursorMoved fire.
local function on_task(child, needle, group)
  local row = group and find_row_in_group(child, needle, group) or find_row(child, needle)
  eq(row >= 0, true, needle .. " must be rendered: " .. vim.inspect(dash_lines(child)))
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.loop.sleep(50)
  child.type_keys("<Ignore>")
  vim.loop.sleep(50)
  return row
end

--- Put the cursor on the group top of "## <group>": the row that carries that
--- group header (a group header is a virtual line attached to the first task of
--- its group).  Use this when the task order inside the group is not fixed (the
--- sort breaks ties by index order, which is not stable across notes), so the
--- gesture always takes the group-top path and never an anchored insert.
local function on_group_top(child, group)
  local header = "## " .. group
  local row = child.lua_get(
    [[(function(header)
      local ns = require("obsidian-tasks.util.extmark").NS
      for _, m in ipairs(vim.api.nvim_buf_get_extmarks(_G._b, ns, 0, -1, { details = true })) do
        for _, chunks in ipairs(m[4].virt_lines or {}) do
          for _, c in ipairs(chunks) do
            if c[2] == "ObsidianTasksGroupHeader" and c[1] == header then return m[2] end
          end
        end
      end
      return -1
    end)(...)]],
    { header }
  )
  eq(row >= 0, true, header .. " must be rendered: " .. vim.inspect(dash_lines(child)))
  eq(
    child.lua_get("require('obsidian-tasks.render.managed').task_meta_for_row(_G._b, ...) ~= nil", { row }),
    true,
    "the group top of " .. header .. " must be a task row"
  )
  child.api.nvim_win_set_cursor(0, { row + 1, 0 })
  vim.loop.sleep(50)
  child.type_keys("<Ignore>")
  vim.loop.sleep(50)
  return row
end

local function settle()
  vim.loop.sleep(500)
end

--- The core invariant (plan "Core invariant"): after the rerender, the task
--- that shows *task_text* is a managed dashboard row under the group header
--- "## <group_path>" (nil = no header above it: ungrouped).  A task can show in
--- more than one group (tags), so one such row is enough.
local function assert_in_group(child, task_text, group_path)
  local row
  if group_path == nil then
    row = find_row(child, task_text)
  else
    row = find_row_in_group(child, task_text, group_path)
  end
  eq(
    row >= 0,
    true,
    ("%s must show under '## %s': %s"):format(task_text, tostring(group_path), vim.inspect(dash_lines(child)))
  )
  local managed =
    child.lua_get("require('obsidian-tasks.render.managed').task_meta_for_row(_G._b, ...) ~= nil", { row })
  eq(managed, true, task_text .. " must be a managed row (a rendered task), not note content")
  if group_path == nil then
    eq(child.lua_get("_G._header_above(...)", { row }), vim.NIL, task_text .. " must not be under a group header")
  end
end

local function cursor_line(child)
  return child.lua_get("vim.api.nvim_get_current_line()")
end

local function count(list, needle)
  local n = 0
  for _, l in ipairs(list or {}) do
    if l:find(needle, 1, true) then
      n = n + 1
    end
  end
  return n
end

-- ── group keys ────────────────────────────────────────────────────────────────

T["heading: note missing → created with the heading; message + cursor follow"] = function()
  local child = spawn({ files = { ["projects/work.md"] = WORK }, query = { "not done", "group by heading" } })
  on_task(child, "Debt B")
  child.type_keys("O", "New debt", "<Esc>")
  settle()

  eq(daily_lines(child), { "## technical debt", "- [ ] New debt #task" })
  eq(file_lines(child, "projects/work.md"), WORK, "the source note is not written")
  eq(
    has_msg(child, "added to " .. DAILY_REL .. " › ## technical debt (created)", INFO),
    true,
    vim.inspect(msgs(child))
  )
  eq(cursor_line(child):find("New debt", 1, true) ~= nil, true, "cursor follows the new task")
  assert_in_group(child, "New debt", "technical debt")
  child.stop()
end

T["heading: section with items → after the last item of that section"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = WORK },
    query = { "not done", "group by heading" },
    daily = { "# 2026-10-11", "", "## technical debt", "- [ ] Old debt #task", "", "## notes", "text" },
  })
  -- 'Old debt' (daily note) and 'Debt B' (work) tie in the sort, so either can
  -- be the first task of the group: `O` on the group top, not on 'Debt B'.
  on_group_top(child, "technical debt")
  child.type_keys("O", "- [ ] Fresh debt", "<Esc>")
  settle()

  eq(daily_lines(child), {
    "# 2026-10-11",
    "",
    "## technical debt",
    "- [ ] Old debt #task",
    "- [ ] Fresh debt #task",
    "",
    "## notes",
    "text",
  })
  eq(has_msg(child, "added to " .. DAILY_REL .. " › ## technical debt", INFO), true, vim.inspect(msgs(child)))
  eq(has_msg(child, "(created)"), false, "nothing was created")
  assert_in_group(child, "Fresh debt", "technical debt")
  child.stop()
end

T["heading: heading missing → appended at the level of the real heading line"] = function()
  local work = vim.deepcopy(WORK)
  work[4] = "### technical debt"
  local child = spawn({
    files = { ["projects/work.md"] = work },
    query = { "not done", "group by heading" },
    daily = { "# 2026-10-11", "intro" },
  })
  on_task(child, "Debt B")
  child.type_keys("O", "Deep debt", "<Esc>")
  settle()

  eq(daily_lines(child), { "# 2026-10-11", "intro", "", "### technical debt", "- [ ] Deep debt #task" })
  eq(has_msg(child, "› ### technical debt (created)", INFO), true, vim.inspect(msgs(child)))
  assert_in_group(child, "Deep debt", "technical debt")
  child.stop()
end

T["(No heading): before the first heading of the daily note"] = function()
  local child = spawn({
    files = { ["inbox.md"] = { "- [ ] Loose A #task" }, ["projects/work.md"] = WORK },
    query = { "not done", "group by heading" },
    daily = { "---", "id: 2026-10-11", "---", "## technical debt", "- [ ] Old #task" },
  })
  on_task(child, "Loose A")
  child.type_keys("O", "Loose new", "<Esc>")
  settle()

  eq(daily_lines(child), {
    "---",
    "id: 2026-10-11",
    "---",
    "- [ ] Loose new #task",
    "",
    "## technical debt",
    "- [ ] Old #task",
  })
  assert_in_group(child, "Loose new", "(No heading)")
  child.stop()
end

T["(No heading): a ```tasks block in the daily note stays intact (review probe)"] = function()
  -- A `# ...` comment line in a query block is not a heading (upstream, and
  -- the index).  Placement must agree: the task goes before the first REAL
  -- heading, outside the fence, and the query block keeps its lines.
  local daily = { "```tasks", "# due this week", "not done", "```", "", "## log", "text" }
  local child = spawn({
    files = { ["inbox.md"] = { "- [ ] Loose A #task" }, ["projects/work.md"] = WORK },
    query = { "not done", "group by heading" },
    daily = daily,
  })
  on_group_top(child, "(No heading)")
  child.type_keys("O", "Loose new", "<Esc>")
  settle()

  eq(daily_lines(child), {
    "```tasks",
    "# due this week",
    "not done",
    "```",
    "",
    "- [ ] Loose new #task",
    "",
    "## log",
    "text",
  })
  eq(has_msg(child, "added to " .. DAILY_REL .. " › (No heading)", INFO), true, vim.inspect(msgs(child)))
  assert_in_group(child, "Loose new", "(No heading)")
  child.stop()
end

T["tags: daily note end of file + the tag"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = { "- [ ] Alpha #home #task", "- [ ] Bravo #work #task" } },
    query = { "not done", "group by tags" },
    daily = { "# 2026-10-11" },
  })
  on_task(child, "Bravo", "#work")
  child.type_keys("O", "Charlie", "<Esc>")
  settle()

  eq(daily_lines(child), { "# 2026-10-11", "", "- [ ] Charlie #work #task" })
  assert_in_group(child, "Charlie", "#work")
  child.stop()
end

T["priority: daily note end of file + the priority"] = function()
  local child = spawn({
    -- The global filter goes before the fields: the description ends at the
    -- first field, and the index needs the filter in the description.
    files = { ["projects/work.md"] = { "- [ ] Urgent #task ⏫", "- [ ] Later #task 🔽" } },
    query = { "not done", "group by priority" },
  })
  on_task(child, "Urgent")
  child.type_keys("O", "Also urgent", "<Esc>")
  settle()

  eq(daily_lines(child), { "- [ ] Also urgent #task ⏫" })
  assert_in_group(child, "Also urgent", "Priority 2: High")
  child.stop()
end

T["status: daily note end of file + the status symbol"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = { "- [ ] Todo one #task", "- [/] Doing one #task" } },
    query = { "not done", "group by status" },
  })
  on_task(child, "Doing one")
  child.type_keys("O", "Doing two", "<Esc>")
  settle()

  eq(daily_lines(child), { "- [/] Doing two #task" })
  assert_in_group(child, "Doing two", "In Progress")
  child.stop()
end

T["filename: appended to the end of that file, no daily note"] = function()
  local child = spawn({
    files = {
      ["a/alpha.md"] = { "- [ ] Alpha one #task" },
      ["b/work.md"] = { "# Work", "- [ ] Work one #task", "", "closing prose" },
    },
    query = { "not done", "group by filename" },
  })
  on_task(child, "Work one")
  child.type_keys("O", "Work zero", "<Esc>")
  settle()

  eq(
    file_lines(child, "b/work.md"),
    { "# Work", "- [ ] Work one #task", "", "closing prose", "", "- [ ] Work zero #task" }
  )
  eq(daily_lines(child), vim.NIL, "no daily note for a filename group")
  eq(has_msg(child, "added to b/work.md", INFO), true, vim.inspect(msgs(child)))
  assert_in_group(child, "Work zero", "work")
  child.stop()
end

T["folder: below-fence fallback + warning, nothing written"] = function()
  local child = spawn({
    files = { ["a/alpha.md"] = { "- [ ] Alpha one #task" }, ["b/beta.md"] = { "- [ ] Beta one #task" } },
    query = { "not done", "group by folder" },
  })
  on_task(child, "Beta one")
  child.type_keys("O", "Beta zero", "<Esc>")
  settle()

  eq(daily_lines(child), vim.NIL, "no daily note for a folder group")
  eq(file_lines(child, "b/beta.md"), { "- [ ] Beta one #task" })
  eq(has_msg(child, "group by folder", WARN), true, vim.inspect(msgs(child)))
  local fallback = child.lua_get([[(function()
    local save = require("obsidian-tasks.render.save")
    local skip = {}
    for _, r in ipairs(save.compute_managed_ranges(_G._b)) do
      for row = r[1], r[2] do skip[row] = true end
    end
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
      if not skip[i - 1] and l == "Beta zero" then return true end
    end
    return false
  end)()]])
  eq(fallback, true, "typed line kept as note content: " .. vim.inspect(dash_lines(child)))
  child.stop()
end

T["heading + tags: daily heading section + the tag"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = { "## technical debt", "- [ ] Debt B #work #task" } },
    query = { "not done", "group by heading", "group by tags" },
  })
  on_task(child, "Debt B", "technical debt / #work")
  child.type_keys("O", "Debt A", "<Esc>")
  settle()

  eq(daily_lines(child), { "## technical debt", "- [ ] Debt A #work #task" })
  assert_in_group(child, "Debt A", "technical debt / #work")
  child.stop()
end

T["ungrouped: O on the first task → daily note end of file"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = { "- [ ] First #task", "- [ ] Second #task" } },
    query = { "not done" },
  })
  on_task(child, "First")
  child.type_keys("O", "Zeroth", "<Esc>")
  settle()

  eq(daily_lines(child), { "- [ ] Zeroth #task" })
  eq(file_lines(child, "projects/work.md"), { "- [ ] First #task", "- [ ] Second #task" })
  assert_in_group(child, "Zeroth", nil)
  child.stop()
end

T["zero-result: o on the closing fence → daily note end of file"] = function()
  -- The fence ends the file, so the zero-result block keeps its EOF sentinel
  -- region (see test_real_zero_result_insert.lua).
  local child = spawn({
    files = { ["projects/work.md"] = { "- [ ] Other #task" } },
    query = { "not done", "tags include #inbox" },
    no_trailing = true,
  })
  -- 0 '# Dashboard', 1 '', 2 '```tasks', 3 'not done', 4 'tags include #inbox', 5 '```'.
  child.api.nvim_win_set_cursor(0, { 6, 0 })
  vim.loop.sleep(50)
  child.type_keys("o", "- [ ] Capture #inbox", "<Esc>")
  settle()

  eq(daily_lines(child), { "- [ ] Capture #inbox #task" })
  assert_in_group(child, "Capture", nil)
  child.stop()
end

-- ── tree mode ─────────────────────────────────────────────────────────────────

local TREE_WORK = {
  "## refactoring",
  "- [ ] Refactor A #task",
  "  - refactor detail one",
  "  - refactor detail two",
  "## technical debt",
  "- [ ] Debt B #task",
  "  - [ ] Debt B child #task",
}

local function fold_ranges(child)
  return child.lua_get([[(function()
    local out = {}
    vim.api.nvim_win_call(0, function()
      local n = vim.api.nvim_buf_line_count(0)
      local l = 1
      while l <= n do
        local s = vim.fn.foldclosed(l)
        if s ~= -1 then
          local e = vim.fn.foldclosedend(l)
          out[#out + 1] = { vim.api.nvim_buf_get_lines(0, s - 1, s, false)[1], e - s }
          l = e + 1
        else
          l = l + 1
        end
      end
    end)
    return out
  end)()]])
end

T["tree: an indented line at the group top is written at depth 0; closed folds stay"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = TREE_WORK },
    query = { "not done", "group by heading", "show tree" },
  })
  -- Close the refactoring subtree fold (first child row of Refactor A).
  local child_row = find_row(child, "refactor detail one")
  child.api.nvim_win_set_cursor(0, { child_row + 1, 0 })
  child.type_keys("zc")
  vim.loop.sleep(50)
  local folds_before = fold_ranges(child)
  eq(#folds_before, 1, "one closed subtree fold: " .. vim.inspect(folds_before))

  on_task(child, "Debt B #task")
  child.type_keys("O", "    - [ ] Indented new", "<Esc>")
  settle()

  eq(daily_lines(child), { "## technical debt", "- [ ] Indented new #task" })
  eq(fold_ranges(child), folds_before, "closed subtree folds are unchanged")
  assert_in_group(child, "Indented new", "technical debt")
  child.stop()
end

T["tree: a pasted subtree keeps its shape; attributes on the root only"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = { "- [ ] Alpha #home #task", "- [ ] Bravo #work #task" } },
    query = { "not done", "group by tags", "show tree" },
  })
  on_task(child, "Bravo", "#work")
  child.lua([[vim.fn.setreg("x", { "- [ ] Pasted root", "  - [ ] Pasted child" }, "l")]])
  child.type_keys('"xP')
  settle()

  eq(daily_lines(child), { "- [ ] Pasted root #work #task", "  - [ ] Pasted child #task" })
  assert_in_group(child, "Pasted root", "#work")
  assert_in_group(child, "Pasted child", "#work")
  child.stop()
end

T["tree: a root description bullet is written as typed + warning"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = TREE_WORK },
    query = { "not done", "group by heading", "show tree" },
  })
  on_task(child, "Debt B #task")
  child.type_keys("O", "- just a note", "<Esc>")
  settle()

  eq(daily_lines(child), { "## technical debt", "- just a note" })
  eq(has_msg(child, "does not show in the dashboard", WARN), true, vim.inspect(msgs(child)))
  child.stop()
end

-- ── write conditions ──────────────────────────────────────────────────────────

T["daily note open with unsaved changes → refused, line reverted, warning"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = WORK },
    query = { "not done", "group by heading" },
    daily = { "# 2026-10-11" },
  })
  child.lua([[
    local b = vim.fn.bufadd(_G._daily)
    vim.fn.bufload(b)
    vim.bo[b].buflisted = true
    vim.api.nvim_buf_set_lines(b, -1, -1, false, { "unsaved" })
  ]])
  on_task(child, "Debt B")
  child.type_keys("O", "Refused debt", "<Esc>")
  settle()

  eq(daily_lines(child), { "# 2026-10-11" }, "disk untouched")
  eq(count(dash_lines(child), "Refused debt"), 0, "the typed line is reverted")
  eq(has_msg(child, "has unsaved changes — save it and retry", WARN), true, vim.inspect(msgs(child)))
  assert_in_group(child, "Debt B", "technical debt")
  child.stop()
end

T["daily note open and clean → its buffer is synced"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = WORK },
    query = { "not done", "group by heading" },
    daily = { "# 2026-10-11" },
  })
  child.lua([[
    local b = vim.fn.bufadd(_G._daily)
    vim.fn.bufload(b)
    _G._daily_b = b
  ]])
  on_task(child, "Debt B")
  child.type_keys("O", "Synced debt", "<Esc>")
  settle()

  local expect = { "# 2026-10-11", "", "## technical debt", "- [ ] Synced debt #task" }
  eq(daily_lines(child), expect)
  eq(child.lua_get("vim.api.nvim_buf_get_lines(_G._daily_b, 0, -1, false)"), expect)
  assert_in_group(child, "Synced debt", "technical debt")
  child.stop()
end

T["no resolver (daily_note = false) → below-fence fallback"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = WORK },
    query = { "not done", "group by heading" },
    resolver = false,
  })
  on_task(child, "Debt B")
  child.type_keys("O", "Homeless debt", "<Esc>")
  settle()

  eq(daily_lines(child), vim.NIL)
  eq(file_lines(child, "projects/work.md"), WORK)
  eq(has_msg(child, "no task to anchor to", WARN), true, vim.inspect(msgs(child)))
  child.stop()
end

T["a query filter hides the task → written anyway + warning"] = function()
  local child = spawn({
    files = { ["projects/work.md"] = WORK },
    query = { "not done", "path includes projects", "group by heading" },
  })
  on_task(child, "Debt B")
  child.type_keys("O", "Hidden debt", "<Esc>")
  settle()

  eq(daily_lines(child), { "## technical debt", "- [ ] Hidden debt #task" })
  eq(
    has_msg(
      child,
      "added to " .. DAILY_REL .. " › ## technical debt (created), but this query hides it (path filter)",
      WARN
    ),
    true,
    vim.inspect(msgs(child))
  )
  eq(count(dash_lines(child), "Hidden debt"), 0, "hidden by the query")
  child.stop()
end

-- ── undo / redo ───────────────────────────────────────────────────────────────

T["undo removes the heading and the task; the note stays; redo puts them back"] = function()
  local child = spawn({ files = { ["projects/work.md"] = WORK }, query = { "not done", "group by heading" } })
  on_task(child, "Debt B")
  child.type_keys("O", "Undo debt", "<Esc>")
  settle()
  eq(daily_lines(child), { "## technical debt", "- [ ] Undo debt #task" })

  child.type_keys("u")
  settle()
  eq(daily_lines(child), {}, "undo removes only the written lines; the created note stays")
  eq(count(dash_lines(child), "Undo debt"), 0)

  child.type_keys("<C-r>")
  settle()
  eq(daily_lines(child), { "## technical debt", "- [ ] Undo debt #task" })
  assert_in_group(child, "Undo debt", "technical debt")
  child.stop()
end

return T
