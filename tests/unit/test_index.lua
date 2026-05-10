-- tests/unit/test_index.lua
-- Unit tests for index/init.lua, index/scan.lua, and index/ignore.lua.
--
-- Strategy:
--   * ignore.lua  — stubs obsidian adapter's parse_frontmatter
--   * scan.lua    — stubs obsidian adapter's search_async; uses real parse
--   * index/init  — exercises refresh_file (sync), tasks_in, invalidate,
--                   reverse_index via real filesystem (fixture vault)

local T = MiniTest.new_set()

-- ── helpers ────────────────────────────────────────────────────────────────

local VAULT = vim.fn.fnamemodify("tests/fixtures/vault", ":p")

--- Inject a stub into package.loaded and return cleanup fn.
local function stub_module(name, tbl)
  local prev = package.loaded[name]
  package.loaded[name] = tbl
  return function()
    package.loaded[name] = prev
  end
end

--- Force a fresh require (clear module cache).
local function fresh(mod)
  package.loaded[mod] = nil
  return require(mod)
end

--- Set a minimal _G.Obsidian stub (needed for adapter guard).
local function set_obsidian_stub()
  _G.Obsidian = { workspace = { root = VAULT, name = "test" }, workspaces = {} }
end

--- Absolute path to a fixture file.
local function fixture(name)
  return VAULT .. name
end

-- Reset obsidian-tasks opts to bare minimum between tests.
local function reset_opts(overrides)
  local ot = require("obsidian-tasks")
  ot.opts = vim.tbl_deep_extend("force", {
    global_filter = nil,
    max_file_bytes = 1048576,
  }, overrides or {})
end

-- ── index/ignore.lua ──────────────────────────────────────────────────────

local ignore_tests = MiniTest.new_set()

ignore_tests["not ignored: frontmatter lacks tasks-plugin key"] = function()
  set_obsidian_stub()
  reset_opts()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { title = "Normal" }, {}
    end,
  })
  local ignore = fresh("obsidian-tasks.index.ignore")
  local result = ignore.is_ignored("/some/note.md")
  cleanup()
  MiniTest.expect.equality(result, false)
end

ignore_tests["ignored: tasks-plugin.ignore = true (nested table)"] = function()
  set_obsidian_stub()
  reset_opts()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { ["tasks-plugin"] = { ignore = true } }, {}
    end,
  })
  local ignore = fresh("obsidian-tasks.index.ignore")
  local result = ignore.is_ignored("/vault/ignored.md")
  cleanup()
  MiniTest.expect.equality(result, true)
end

ignore_tests["ignored: flat tasks-plugin.ignore key = true"] = function()
  set_obsidian_stub()
  reset_opts()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { ["tasks-plugin.ignore"] = true }, {}
    end,
  })
  local ignore = fresh("obsidian-tasks.index.ignore")
  local result = ignore.is_ignored("/vault/ignored2.md")
  cleanup()
  MiniTest.expect.equality(result, true)
end

ignore_tests["not ignored: tasks-plugin.ignore = false"] = function()
  set_obsidian_stub()
  reset_opts()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { ["tasks-plugin"] = { ignore = false } }, {}
    end,
  })
  local ignore = fresh("obsidian-tasks.index.ignore")
  local result = ignore.is_ignored("/vault/not_ignored.md")
  cleanup()
  MiniTest.expect.equality(result, false)
end

ignore_tests["not ignored: frontmatter read error returns false (non-fatal)"] = function()
  set_obsidian_stub()
  reset_opts()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return nil, { "cannot open file" }
    end,
  })
  local ignore = fresh("obsidian-tasks.index.ignore")
  local result = ignore.is_ignored("/vault/missing.md")
  cleanup()
  MiniTest.expect.equality(result, false)
end

T["ignore"] = ignore_tests

-- ── index/scan.lua ────────────────────────────────────────────────────────

local scan_tests = MiniTest.new_set()

--- Build fake search matches from a list of { path, line, line_number }.
local function make_matches(rows)
  local out = {}
  for _, r in ipairs(rows) do
    out[#out + 1] = { path = { text = r[1] }, lines = { text = r[2] }, line_number = r[3] }
  end
  return out
end

scan_tests["walk: calls on_exit with ripgrep exit code"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    search_async = function(_, _, on_match, on_exit)
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local scan = fresh("obsidian-tasks.index.scan")
  local got_code
  scan.walk({ root = VAULT }, function() end, function(code)
    got_code = code
  end)
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(got_code, 0)
end

scan_tests["walk: yields parsed tasks for valid task lines"] = function()
  set_obsidian_stub()
  reset_opts()

  local rows = make_matches({
    { "/vault/note.md", "- [ ] Task one #task", 1 },
    { "/vault/note.md", "- [x] Task two #task ✅ 2024-01-01", 2 },
    { "/vault/note.md", "Not a task line", 3 },
  })

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    search_async = function(_, _, on_match, on_exit)
      for _, m in ipairs(rows) do
        on_match(m)
      end
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  -- Make vim.uv.fs_stat always succeed with a small size
  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(_)
    return { size = 100, mtime = { sec = 1000 } }
  end

  local scan = fresh("obsidian-tasks.index.scan")
  local tasks = {}
  scan.walk({ root = VAULT }, function(task, path, _line_num)
    tasks[#tasks + 1] = { task = task, path = path }
  end, function() end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()
  cleanup_ign()

  -- "Not a task line" should not produce a task
  MiniTest.expect.equality(#tasks, 2)
  MiniTest.expect.equality(tasks[1].task.description, "Task one #task")
  MiniTest.expect.equality(tasks[2].task.description, "Task two #task")
end

scan_tests["walk: global_filter excludes tasks without filter string"] = function()
  set_obsidian_stub()
  reset_opts({ global_filter = "#task" })

  local rows = make_matches({
    { "/vault/note.md", "- [ ] Has tag #task", 1 },
    { "/vault/note.md", "- [ ] No tag here", 2 },
    { "/vault/note.md", "- [ ] Also has #task here", 3 },
  })

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    search_async = function(_, _, on_match, on_exit)
      for _, m in ipairs(rows) do
        on_match(m)
      end
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(_)
    return { size = 100, mtime = { sec = 1000 } }
  end

  local scan = fresh("obsidian-tasks.index.scan")
  local tasks = {}
  scan.walk({ root = VAULT }, function(task, _, _)
    tasks[#tasks + 1] = task
  end, function() end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()
  cleanup_ign()

  -- Only tasks containing "#task" in description should survive
  MiniTest.expect.equality(#tasks, 2)
  MiniTest.expect.equality(tasks[1].description, "Has tag #task")
  MiniTest.expect.equality(tasks[2].description, "Also has #task here")
end

scan_tests["walk: ignored files are skipped"] = function()
  set_obsidian_stub()
  reset_opts()

  local rows = make_matches({
    { "/vault/normal.md", "- [ ] Normal task", 1 },
    { "/vault/ignored.md", "- [ ] Ignored task", 2 },
  })

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    search_async = function(_, _, on_match, on_exit)
      for _, m in ipairs(rows) do
        on_match(m)
      end
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(path)
      return path == "/vault/ignored.md"
    end,
  })

  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(_)
    return { size = 100, mtime = { sec = 1000 } }
  end

  local scan = fresh("obsidian-tasks.index.scan")
  local tasks = {}
  scan.walk({ root = VAULT }, function(task, _, _)
    tasks[#tasks + 1] = task
  end, function() end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(#tasks, 1)
  MiniTest.expect.equality(tasks[1].description, "Normal task")
end

scan_tests["walk: files exceeding max_file_bytes are skipped"] = function()
  set_obsidian_stub()
  reset_opts({ max_file_bytes = 100 })

  local rows = make_matches({
    { "/vault/small.md", "- [ ] Small task", 1 },
    { "/vault/large.md", "- [ ] Large task", 2 },
  })

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    search_async = function(_, _, on_match, on_exit)
      for _, m in ipairs(rows) do
        on_match(m)
      end
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(path)
    if path == "/vault/large.md" then
      return { size = 200, mtime = { sec = 1000 } }
    end
    return { size = 50, mtime = { sec = 1000 } }
  end

  local scan = fresh("obsidian-tasks.index.scan")
  local tasks = {}
  scan.walk({ root = VAULT }, function(task, _, _)
    tasks[#tasks + 1] = task
  end, function() end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(#tasks, 1)
  MiniTest.expect.equality(tasks[1].description, "Small task")
end

T["scan"] = scan_tests

-- ── index/init.lua ────────────────────────────────────────────────────────

local init_tests = MiniTest.new_set()

init_tests["refresh_file: parses tasks from real fixture file (tasks_a.md)"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = fixture("tasks_a.md")
  index.refresh_file(path)

  cleanup_ign()

  local raw = index._raw()
  local entry = raw[path]
  MiniTest.expect.equality(type(entry), "table")
  -- tasks_a.md has 5 task lines (- [ ] or - [x])
  MiniTest.expect.equality(#entry.tasks >= 4, true)
end

init_tests["refresh_file: mtime no-op — second call does not re-allocate"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = fixture("tasks_a.md")

  -- First parse
  index.refresh_file(path)
  local raw = index._raw()
  local entry_after_first = raw[path]
  local tasks_ref_first = entry_after_first.tasks

  -- Second call — mtime unchanged → should be a no-op
  index.refresh_file(path)
  local entry_after_second = raw[path]

  cleanup_ign()

  -- The tasks table reference should be the SAME object (no re-allocation)
  MiniTest.expect.equality(entry_after_second.tasks == tasks_ref_first, true)
end

init_tests["refresh_file: ignored file is dropped from index"] = function()
  set_obsidian_stub()
  reset_opts()

  local call_count = 0
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      call_count = call_count + 1
      return true
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = fixture("tasks_a.md")
  index.refresh_file(path)

  cleanup_ign()

  local raw = index._raw()
  MiniTest.expect.equality(raw[path], nil)
end

init_tests["invalidate: removes entry from index"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = fixture("tasks_a.md")
  index.refresh_file(path)

  local raw = index._raw()
  MiniTest.expect.equality(raw[path] ~= nil, true)

  index.invalidate(path)

  cleanup_ign()

  MiniTest.expect.equality(raw[path], nil)
end

init_tests["tasks_in: returns all tasks when no filter"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path_a = fixture("tasks_a.md")
  local path_b = fixture("tasks_b.md")
  index.refresh_file(path_a)
  index.refresh_file(path_b)

  cleanup_ign()

  local count = 0
  local iter = index.tasks_in(nil)
  while iter() do
    count = count + 1
  end
  -- Both fixture files have task lines
  MiniTest.expect.equality(count >= 2, true)
end

init_tests["tasks_in: path_filter limits results"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path_a = fixture("tasks_a.md")
  local path_b = fixture("tasks_b.md")
  index.refresh_file(path_a)
  index.refresh_file(path_b)

  cleanup_ign()

  local count_a = 0
  local iter = index.tasks_in(function(p)
    return p == path_a
  end)
  while true do
    local task, _ = iter()
    if not task then
      break
    end
    count_a = count_a + 1
  end

  -- tasks_a.md should have tasks, tasks_b.md should be excluded
  local raw = index._raw()
  local expected_a = #raw[path_a].tasks
  MiniTest.expect.equality(count_a, expected_a)
end

init_tests["reverse_index: unknown path returns empty list"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()
  local result = index.reverse_index("/any/path.md")
  MiniTest.expect.equality(type(result), "table")
  MiniTest.expect.equality(#result, 0)
end

init_tests["set_render_paths: records bufnr in reverse index for each path"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local bufnr = 42
  local paths = { ["/vault/a.md"] = true, ["/vault/b.md"] = true }
  index.set_render_paths(bufnr, paths)

  local result_a = index.reverse_index("/vault/a.md")
  local result_b = index.reverse_index("/vault/b.md")

  -- Both paths should include bufnr=42
  local function contains(t, v)
    for _, x in ipairs(t) do
      if x == v then
        return true
      end
    end
    return false
  end
  MiniTest.expect.equality(contains(result_a, bufnr), true)
  MiniTest.expect.equality(contains(result_b, bufnr), true)
  -- Unknown path is still empty
  MiniTest.expect.equality(#index.reverse_index("/vault/c.md"), 0)
end

init_tests["set_render_paths: re-render replaces old path associations"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local bufnr = 99

  -- First render: bufnr includes tasks from a.md and b.md
  index.set_render_paths(bufnr, { ["/vault/a.md"] = true, ["/vault/b.md"] = true })

  -- Second render: bufnr now only includes tasks from c.md
  index.set_render_paths(bufnr, { ["/vault/c.md"] = true })

  -- Old paths must no longer reference bufnr
  local function contains(t, v)
    for _, x in ipairs(t) do
      if x == v then
        return true
      end
    end
    return false
  end
  MiniTest.expect.equality(contains(index.reverse_index("/vault/a.md"), bufnr), false)
  MiniTest.expect.equality(contains(index.reverse_index("/vault/b.md"), bufnr), false)
  -- New path must reference bufnr
  MiniTest.expect.equality(contains(index.reverse_index("/vault/c.md"), bufnr), true)
end

init_tests["set_render_paths: multiple bufnrs can share a path"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = "/vault/shared.md"
  index.set_render_paths(10, { [path] = true })
  index.set_render_paths(20, { [path] = true })

  local result = index.reverse_index(path)
  MiniTest.expect.equality(#result, 2)
  -- Both bufnrs must appear
  local found_10, found_20 = false, false
  for _, b in ipairs(result) do
    if b == 10 then
      found_10 = true
    end
    if b == 20 then
      found_20 = true
    end
  end
  MiniTest.expect.equality(found_10, true)
  MiniTest.expect.equality(found_20, true)
end

init_tests["clear_render_paths: removes bufnr from all paths"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local bufnr = 77
  index.set_render_paths(bufnr, { ["/vault/x.md"] = true, ["/vault/y.md"] = true })

  -- Sanity: bufnr is recorded
  local function contains(t, v)
    for _, x in ipairs(t) do
      if x == v then
        return true
      end
    end
    return false
  end
  MiniTest.expect.equality(contains(index.reverse_index("/vault/x.md"), bufnr), true)

  -- Clear and verify
  index.clear_render_paths(bufnr)
  MiniTest.expect.equality(#index.reverse_index("/vault/x.md"), 0)
  MiniTest.expect.equality(#index.reverse_index("/vault/y.md"), 0)
end

init_tests["clear_render_paths: other bufnrs for same path are unaffected"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = "/vault/shared.md"
  index.set_render_paths(11, { [path] = true })
  index.set_render_paths(22, { [path] = true })

  -- Clear only bufnr=11
  index.clear_render_paths(11)

  local result = index.reverse_index(path)
  -- bufnr=22 must still be there
  local found_22 = false
  for _, b in ipairs(result) do
    if b == 22 then
      found_22 = true
    end
    -- bufnr=11 must NOT be there
    MiniTest.expect.equality(b ~= 11, true)
  end
  MiniTest.expect.equality(found_22, true)
end

T["index"] = init_tests

-- ── integration: 3 fixture files, global_filter='#task' ───────────────────
-- Acceptance criterion: scan 3 fixture files (one ignored via frontmatter),
-- global_filter='#task' set → correct expected task count.

local integration_tests = MiniTest.new_set()

integration_tests["fixture scan: 3 files, one ignored, global_filter=#task → correct count"] = function()
  set_obsidian_stub()
  reset_opts({ global_filter = "#task" })

  -- Use real parse_frontmatter via the adapter but stub the obsidian module
  -- so frontmatter.parse works for our fixture files.
  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(path)
      -- Read the file and hand-parse the frontmatter block for our fixtures.
      local f = io.open(path, "r")
      if not f then
        return nil, { "cannot open " .. path }
      end
      local lines = {}
      for line in f:lines() do
        lines[#lines + 1] = line
      end
      f:close()

      -- Simple YAML frontmatter scanner for test fixtures.
      if lines[1] ~= "---" then
        return {}, {}
      end
      local fm = {}
      local in_tasks_plugin = false
      for i = 2, #lines do
        local line = lines[i]
        if line == "---" then
          break
        end
        -- Detect `tasks-plugin:` section
        if line:match("^tasks%-plugin:") then
          in_tasks_plugin = true
          fm["tasks-plugin"] = fm["tasks-plugin"] or {}
        elseif in_tasks_plugin and line:match("^%s+ignore:%s+true") then
          fm["tasks-plugin"].ignore = true
        elseif not line:match("^%s") then
          in_tasks_plugin = false
        end
      end
      return fm, {}
    end,

    search_async = function(ws, _, on_match, on_exit)
      -- Synchronous simulation: walk the fixture vault ourselves.
      local root = ws.root
      local files = vim.fn.globpath(root, "*.md", false, true)
      for _, fpath in ipairs(files) do
        local f = io.open(fpath, "r")
        if f then
          local lineno = 0
          for line in f:lines() do
            lineno = lineno + 1
            -- ripgrep pattern: task line with checkbox
            if line:match("^%s*[-*+] %[.%] ") then
              on_match({
                path = { text = fpath },
                lines = { text = line },
                line_number = lineno,
              })
            end
          end
          f:close()
        end
      end
      on_exit(0)
    end,
  })

  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(path)
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local content = f:read("*a")
    f:close()
    return { size = #content, mtime = { sec = os.time() } }
  end

  -- Clear module cache to pick up stubs
  package.loaded["obsidian-tasks.index.ignore"] = nil
  package.loaded["obsidian-tasks.index.scan"] = nil
  local scan = fresh("obsidian-tasks.index.scan")

  local tasks = {}
  local done = false
  scan.walk({ root = VAULT }, function(task, abs_path, _)
    tasks[#tasks + 1] = { task = task, path = abs_path }
  end, function(_)
    done = true
  end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()

  MiniTest.expect.equality(done, true)

  -- ignored_note.md has `tasks-plugin.ignore: true` → its tasks must NOT appear
  local ignored_path = fixture("ignored_note.md")
  for _, item in ipairs(tasks) do
    MiniTest.expect.equality(item.path ~= ignored_path, true)
  end

  -- With global_filter='#task':
  --   tasks_a.md: "Buy milk #task", "Write report #task", "Call dentist #task", "Another task #task" = 4
  --   tasks_b.md: "Fix bug #task", "Write tests #task", "Deploy app #task" = 3
  --   "Non-tagged item" and "Item without tag" are excluded → not counted
  MiniTest.expect.equality(#tasks, 7)
end

integration_tests["fixture scan: no global_filter → includes all non-ignored tasks"] = function()
  set_obsidian_stub()
  reset_opts({ global_filter = nil })

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(path)
      local f = io.open(path, "r")
      if not f then
        return nil, { "cannot open " .. path }
      end
      local lines = {}
      for line in f:lines() do
        lines[#lines + 1] = line
      end
      f:close()
      if lines[1] ~= "---" then
        return {}, {}
      end
      local fm = {}
      local in_tasks_plugin = false
      for i = 2, #lines do
        local line = lines[i]
        if line == "---" then
          break
        end
        if line:match("^tasks%-plugin:") then
          in_tasks_plugin = true
          fm["tasks-plugin"] = fm["tasks-plugin"] or {}
        elseif in_tasks_plugin and line:match("^%s+ignore:%s+true") then
          fm["tasks-plugin"].ignore = true
        elseif not line:match("^%s") then
          in_tasks_plugin = false
        end
      end
      return fm, {}
    end,

    search_async = function(ws, _, on_match, on_exit)
      local root = ws.root
      local files = vim.fn.globpath(root, "*.md", false, true)
      for _, fpath in ipairs(files) do
        local f = io.open(fpath, "r")
        if f then
          local lineno = 0
          for line in f:lines() do
            lineno = lineno + 1
            if line:match("^%s*[-*+] %[.%] ") or line:match("^%s*[-*+] %[x%] ") then
              on_match({
                path = { text = fpath },
                lines = { text = line },
                line_number = lineno,
              })
            end
          end
          f:close()
        end
      end
      on_exit(0)
    end,
  })

  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(path)
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local content = f:read("*a")
    f:close()
    return { size = #content, mtime = { sec = os.time() } }
  end

  package.loaded["obsidian-tasks.index.ignore"] = nil
  package.loaded["obsidian-tasks.index.scan"] = nil
  local scan = fresh("obsidian-tasks.index.scan")

  local tasks = {}
  scan.walk({ root = VAULT }, function(task, abs_path, _)
    tasks[#tasks + 1] = { task = task, path = abs_path }
  end, function() end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()

  -- ignored_note.md must NOT appear
  local ignored_path = fixture("ignored_note.md")
  for _, item in ipairs(tasks) do
    MiniTest.expect.equality(item.path ~= ignored_path, true)
  end

  -- Without global_filter, all task lines from tasks_a + tasks_b are included:
  --   tasks_a.md: 5 task lines (4 todo + 1 done checked via [x])
  --   tasks_b.md: 4 task lines (all [ ] )
  -- But our search_async stub only matches [ ] and [x] patterns.
  -- tasks_a: [ ] Buy milk, [x] Write report, [ ] Call dentist, [ ] Non-tagged item, [ ] Another task = 5
  -- tasks_b: [ ] Fix bug, [ ] Write tests, [ ] Deploy app, [ ] Item without tag = 4
  MiniTest.expect.equality(#tasks, 9)
end

T["integration"] = integration_tests

-- ── index refresh_all (async, stubbed) ───────────────────────────────────

local refresh_all_tests = MiniTest.new_set()

refresh_all_tests["refresh_all: populates index after walk completes"] = function()
  set_obsidian_stub()
  reset_opts()

  local fake_tasks = {
    { path = "/vault/a.md", line = "- [ ] Task alpha" },
    { path = "/vault/a.md", line = "- [ ] Task beta" },
    { path = "/vault/b.md", line = "- [ ] Task gamma" },
  }

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    search_async = function(_, _, on_match, on_exit)
      for _, row in ipairs(fake_tasks) do
        on_match({ path = { text = row.path }, lines = { text = row.line }, line_number = 1 })
      end
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(_)
    return { size = 100, mtime = { sec = 9999 } }
  end

  package.loaded["obsidian-tasks.index.scan"] = nil
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local done_called = false
  index.refresh_all({ root = "/vault" }, function()
    done_called = true
  end)

  vim.uv.fs_stat = orig_stat
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(done_called, true)

  local raw = index._raw()
  MiniTest.expect.equality(type(raw["/vault/a.md"]), "table")
  MiniTest.expect.equality(#raw["/vault/a.md"].tasks, 2)
  MiniTest.expect.equality(type(raw["/vault/b.md"]), "table")
  MiniTest.expect.equality(#raw["/vault/b.md"].tasks, 1)
end

T["refresh_all"] = refresh_all_tests

return T
