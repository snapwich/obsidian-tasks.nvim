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

--- Index keys are canonical (vim.fs.normalize — forward slashes).  Paths used
--- for raw `_index` lookups must pass through here or they miss on Windows,
--- where fnamemodify/tempname return backslash paths.
local function norm(path)
  return vim.fs.normalize(path)
end

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

--- Absolute path to a fixture file (canonical form — usable as an index key).
local function fixture(name)
  return norm(VAULT .. name)
end

--- True if any task item's description contains `substr`.
--- @param items table[]  list of { task, path } items
--- @param substr string
--- @return boolean
local function has_desc(items, substr)
  for _, it in ipairs(items) do
    local desc = (it.task and it.task.description) or ""
    if desc:find(substr, 1, true) then
      return true
    end
  end
  return false
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
-- rg is DISCOVERY-ONLY now: the adapter's `discover_files_async` yields paths,
-- and scan full-reads each path with the unified node parser.  These tests stub
-- discovery to yield temp-file paths whose real on-disk content is parsed.

local scan_tests = MiniTest.new_set()

--- Write `content` to a fresh temp .md file and return its path.
local function write_tmp(content)
  local path = norm(vim.fn.tempname() .. ".md")
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
  return path
end

-- Real frontmatter slicer, used so the single-read scan path can derive the
-- ignore decision from the same lines it parses for nodes.
local real_parse_frontmatter_lines = require("obsidian-tasks.util.obsidian").parse_frontmatter_lines

--- Stub discover_files_async to yield each path in `paths`, then on_exit(code).
--- Provides the real `parse_frontmatter_lines` so scan's single-read ignore
--- check (ignore.is_ignored_fm(parse_frontmatter_lines(lines))) works.
local function stub_discovery(paths, code)
  return stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter_lines = real_parse_frontmatter_lines,
    discover_files_async = function(_, _, on_path, on_exit)
      for _, p in ipairs(paths) do
        on_path(p)
      end
      on_exit(code or 0)
    end,
  })
end

--- Collect (task, path) tuples from a scan.walk over `paths`.
--- The make_on_task hook (global_filter / DateFallback) is passed through.
local function walk_tasks(paths, make_on_task)
  local scan = fresh("obsidian-tasks.index.scan")
  local tasks = {}
  scan.walk({ root = VAULT }, function(task, path, line_num)
    tasks[#tasks + 1] = { task = task, path = path, line_num = line_num }
  end, function() end, make_on_task)
  return tasks
end

scan_tests["walk: calls on_exit with ripgrep exit code"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_obs = stub_discovery({}, 0)
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
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

scan_tests["walk: yields parsed tasks for valid task lines (full-read)"] = function()
  set_obsidian_stub()
  reset_opts()

  local path = write_tmp("- [ ] Task one #task\n- [x] Task two #task ✅ 2024-01-01\nNot a task line\n")

  local cleanup_obs = stub_discovery({ path })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
      return false
    end,
  })

  local tasks = walk_tasks({ path })

  os.remove(path)
  cleanup_obs()
  cleanup_ign()

  -- "Not a task line" should not produce a task.
  MiniTest.expect.equality(#tasks, 2)
  MiniTest.expect.equality(tasks[1].task.description, "Task one #task")
  MiniTest.expect.equality(tasks[2].task.description, "Task two #task")
  MiniTest.expect.equality(tasks[1].line_num, 1)
  MiniTest.expect.equality(tasks[2].line_num, 2)
end

scan_tests["walk: global_filter excludes tasks without filter string"] = function()
  set_obsidian_stub()
  reset_opts({ global_filter = "#task" })

  local path = write_tmp("- [ ] Has tag #task\n- [ ] No tag here\n- [ ] Also has #task here\n")

  local cleanup_obs = stub_discovery({ path })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
      return false
    end,
  })

  -- The global_filter hook lives in index/init.lua; reproduce it here so the
  -- scan test exercises the same on_task vetoing contract.
  local function make_on_task(_)
    return function(task)
      return task.description:find("#task", 1, true) ~= nil
    end
  end

  local tasks = walk_tasks({ path }, make_on_task)

  os.remove(path)
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(#tasks, 2)
  MiniTest.expect.equality(tasks[1].task.description, "Has tag #task")
  MiniTest.expect.equality(tasks[2].task.description, "Also has #task here")
end

scan_tests["walk: ignored files are skipped"] = function()
  set_obsidian_stub()
  reset_opts()

  local normal = write_tmp("- [ ] Normal task\n")
  -- The ignore decision now comes from the single-read frontmatter, so the
  -- ignored file carries a real `tasks-plugin.ignore: true` and the REAL ignore
  -- module (is_ignored_fm) is exercised — no path-based stub.
  local ignored = write_tmp("---\ntasks-plugin:\n  ignore: true\n---\n- [ ] Ignored task\n")

  local cleanup_obs = stub_discovery({ normal, ignored })
  package.loaded["obsidian-tasks.index.ignore"] = nil
  local cleanup_ign = function()
    package.loaded["obsidian-tasks.index.ignore"] = nil
  end

  local tasks = walk_tasks({ normal, ignored })

  os.remove(normal)
  os.remove(ignored)
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(#tasks, 1)
  MiniTest.expect.equality(tasks[1].task.description, "Normal task")
end

scan_tests["walk: files exceeding max_file_bytes are skipped"] = function()
  set_obsidian_stub()
  reset_opts({ max_file_bytes = 20 })

  -- Small file (< 20 bytes) and a large one (> 20 bytes).
  local small = write_tmp("- [ ] S\n")
  local large = write_tmp("- [ ] Large task that exceeds the byte budget for sure\n")

  local cleanup_obs = stub_discovery({ small, large })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
      return false
    end,
  })

  local tasks = walk_tasks({ small, large })

  os.remove(small)
  os.remove(large)
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(#tasks, 1)
  MiniTest.expect.equality(tasks[1].task.description, "S")
end

scan_tests["walk: task.heading tracks the nearest preceding ATX heading"] = function()
  set_obsidian_stub()
  reset_opts()

  local path = write_tmp(table.concat({
    "# Top",
    "",
    "- [ ] Under top",
    "",
    "## Section A",
    "- [ ] Under A one",
    "- [ ] Under A two",
    "",
    "### Section B ###",
    "- [ ] Under B",
    "",
  }, "\n"))

  local cleanup_obs = stub_discovery({ path })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
      return false
    end,
  })

  local tasks = walk_tasks({ path })

  os.remove(path)
  cleanup_obs()
  cleanup_ign()

  -- Heading lines are not yielded as tasks; each task carries its heading.
  MiniTest.expect.equality(#tasks, 4)
  MiniTest.expect.equality(tasks[1].task.heading, "Top")
  MiniTest.expect.equality(tasks[2].task.heading, "Section A")
  MiniTest.expect.equality(tasks[3].task.heading, "Section A")
  MiniTest.expect.equality(tasks[4].task.heading, "Section B") -- closing ### stripped
end

scan_tests["walk: a task above any heading has nil heading"] = function()
  set_obsidian_stub()
  reset_opts()

  local path = write_tmp("- [ ] Orphan task\n# Later heading\n")

  local cleanup_obs = stub_discovery({ path })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
      return false
    end,
  })

  local tasks = walk_tasks({ path })

  os.remove(path)
  cleanup_obs()
  cleanup_ign()

  MiniTest.expect.equality(#tasks, 1)
  MiniTest.expect.equality(tasks[1].task.heading, nil)
end

-- Real-rg discovery: the relaxed DISCOVERY_PATTERN must match a file whose only
-- task line has NO space after `]` (parser/discovery prefix alignment, MINOR-4).
scan_tests["discovery (real rg): finds a file whose only task is `- [ ]nospace`"] = function()
  if vim.fn.executable("rg") == 0 then
    MiniTest.skip("rg not on PATH")
    return
  end
  set_obsidian_stub()
  reset_opts()

  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local nospace = dir .. "/nospace.md"
  local f = assert(io.open(nospace, "w"))
  f:write("- [ ]nospace\n")
  f:close()

  -- Use the REAL adapter + the real DISCOVERY_PATTERN via scan.walk_files.
  package.loaded["obsidian-tasks.util.obsidian"] = nil
  package.loaded["obsidian-tasks.index.ignore"] = nil
  local scan = fresh("obsidian-tasks.index.scan")

  local discovered = {}
  local done = false
  scan.walk_files({ root = dir }, function(abs_path, _nodes)
    discovered[#discovered + 1] = abs_path
  end, function()
    done = true
  end)
  -- discover_files_async schedule-wraps callbacks; drain the loop.
  vim.wait(2000, function()
    return done
  end)

  os.remove(nospace)
  vim.fn.delete(dir, "rf")

  MiniTest.expect.equality(done, true)
  local found = false
  for _, p in ipairs(discovered) do
    if p:find("nospace.md", 1, true) then
      found = true
    end
  end
  MiniTest.expect.equality(found, true)
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

init_tests["refresh_file: tasks carry the nearest preceding heading"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  -- work/sprint.md: tasks under "# Sprint May 2026", then "## Stretch goals".
  local path = fixture("work/sprint.md")
  index.refresh_file(path)

  cleanup_ign()

  local entry = index._raw()[path]
  MiniTest.expect.equality(type(entry), "table")

  local heading_of = {}
  for _, item in ipairs(entry.tasks) do
    heading_of[item.task.description] = item.task.heading
  end

  MiniTest.expect.equality(heading_of["Ship auth refactor #task #work #sprint"], "Sprint May 2026")
  MiniTest.expect.equality(heading_of["Migrate analytics SDK #task #work #sprint"], "Stretch goals")
  MiniTest.expect.equality(heading_of["Onboarding doc refresh #task #work"], "Stretch goals")
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

init_tests["refresh_all_indexed_mtime: picks up an external edit when mtime advances"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = norm(vim.fn.tempname() .. ".md")
  local function write(content)
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  write("- [ ] Original task\n")
  local orig_stat = vim.uv.fs_stat
  vim.uv.fs_stat = function(_)
    return { size = 100, mtime = { sec = 1000 } }
  end
  index.refresh_file(path)
  MiniTest.expect.equality(#index._raw()[path].tasks, 1)

  -- External edit: file gains a task and its mtime advances.
  write("- [ ] Original task\n- [ ] Added externally\n")
  vim.uv.fs_stat = function(_)
    return { size = 200, mtime = { sec = 1001 } }
  end
  index.refresh_all_indexed_mtime()

  vim.uv.fs_stat = orig_stat
  cleanup_ign()
  os.remove(path)

  MiniTest.expect.equality(#index._raw()[path].tasks, 2)
end

init_tests["refresh_all_indexed_mtime: mtime no-op leaves the tasks table intact"] = function()
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
  local tasks_ref = index._raw()[path].tasks

  -- mtime unchanged → should be a no-op, same table reference (no reparse).
  index.refresh_all_indexed_mtime()

  cleanup_ign()

  MiniTest.expect.equality(index._raw()[path].tasks == tasks_ref, true)
end

init_tests["refresh_file: deleted file is dropped from index"] = function()
  set_obsidian_stub()
  reset_opts()

  -- ignore is never consulted for a deleted file — the stat short-circuit
  -- runs first. We assert that by failing if it's called.
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      error("is_ignored must not be called for a missing file")
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  -- Create a real file, index it.
  local path = norm(vim.fn.tempname() .. ".md")
  local f = assert(io.open(path, "w"))
  f:write("- [ ] To be deleted\n")
  f:close()

  -- Restore ignore stub for the initial parse, which DOES consult ignore.
  cleanup_ign()
  local cleanup_ign_ok = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })
  index.refresh_file(path)
  MiniTest.expect.equality(index._raw()[path] ~= nil, true)
  cleanup_ign_ok()

  -- Now delete the file and re-stub ignore to error if called.
  os.remove(path)
  local cleanup_ign_fail = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      error("is_ignored must not be called for a missing file")
    end,
  })

  -- refresh_file on the now-missing path must drop the entry without
  -- consulting ignore (which would log a misleading frontmatter warn).
  index.refresh_file(path)
  cleanup_ign_fail()

  MiniTest.expect.equality(index._raw()[path], nil)
end

init_tests["refresh_all_indexed_mtime: deleted files are dropped"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local kept = norm(vim.fn.tempname() .. ".md")
  local gone = norm(vim.fn.tempname() .. ".md")
  for _, p in ipairs({ kept, gone }) do
    local f = assert(io.open(p, "w"))
    f:write("- [ ] Task in " .. p .. "\n")
    f:close()
    index.refresh_file(p)
  end
  MiniTest.expect.equality(index._raw()[kept] ~= nil, true)
  MiniTest.expect.equality(index._raw()[gone] ~= nil, true)

  os.remove(gone)
  index.refresh_all_indexed_mtime()

  cleanup_ign()
  os.remove(kept)

  MiniTest.expect.equality(index._raw()[gone], nil)
  MiniTest.expect.equality(index._raw()[kept] ~= nil, true)
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

init_tests["refresh_file/invalidate: backslash path resolves to the same entry (Windows)"] = function()
  if vim.fn.has("win32") == 0 then
    MiniTest.skip("Windows-only separator behavior")
    return
  end
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = norm(vim.fn.tempname() .. ".md")
  local f = assert(io.open(path, "w"))
  f:write("- [ ] Only task\n")
  f:close()

  -- Vault scan indexes the canonical (forward-slash) key …
  index.refresh_file(path)

  -- … then BufWritePost passes the raw backslash buffer name.  Before keys
  -- were canonicalized this created a SECOND entry for the same file and
  -- every task in it rendered duplicated on dashboards.
  local backslash = path:gsub("/", "\\")
  index.invalidate(backslash)
  index.refresh_file(backslash)

  cleanup_ign()
  os.remove(path)

  local count = 0
  local iter = index.tasks_in(nil)
  while iter() do
    count = count + 1
  end
  MiniTest.expect.equality(count, 1)

  local entries = 0
  for _ in pairs(index._raw()) do
    entries = entries + 1
  end
  MiniTest.expect.equality(entries, 1)
  MiniTest.expect.equality(index._raw()[path] ~= nil, true)
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

init_tests["nodes_for: returns the per-file node list for an indexed path"] = function()
  set_obsidian_stub()
  reset_opts()

  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored = function(_)
      return false
    end,
  })

  local index = fresh("obsidian-tasks.index")
  index._reset()

  local path = norm(vim.fn.tempname() .. ".md")
  local f = assert(io.open(path, "w"))
  f:write("- [ ] root\n  - [ ] child\n  - desc bullet\n")
  f:close()
  index.refresh_file(path)

  local ns = index.nodes_for(path)
  cleanup_ign()
  os.remove(path)

  MiniTest.expect.equality(type(ns), "table")
  -- Same node list stored on the entry (task / task / bullet).
  MiniTest.expect.equality(#ns, 3)
  MiniTest.expect.equality(ns[1].kind, "task")
  MiniTest.expect.equality(ns[2].kind, "task")
  MiniTest.expect.equality(ns[2].parent_line, 1)
  MiniTest.expect.equality(ns[3].kind, "bullet")
  MiniTest.expect.equality(ns[3].parent_line, 1)
end

init_tests["nodes_for: unknown path returns an empty list"] = function()
  local index = fresh("obsidian-tasks.index")
  index._reset()
  local ns = index.nodes_for("/no/such/path.md")
  MiniTest.expect.equality(type(ns), "table")
  MiniTest.expect.equality(#ns, 0)
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

-- Hand-parse the `tasks-plugin.ignore` frontmatter for a fixture file, the way
-- the real adapter's parse_frontmatter would return it to index/ignore.
local function fixture_frontmatter(path)
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
end

-- Adapter stub: real parse_frontmatter_lines (the single-read ignore path uses
-- it) + discovery that yields every fixture .md path with a checkbox task.  rg
-- is discovery-only, so scan full-reads each yielded path from disk.
-- `parse_frontmatter` is kept for any path that still reads it directly.
local function fixture_adapter_stub()
  return stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = fixture_frontmatter,
    parse_frontmatter_lines = real_parse_frontmatter_lines,
    discover_files_async = function(ws, _, on_path, on_exit)
      local files = vim.fn.globpath(ws.root, "*.md", false, true)
      for _, fpath in ipairs(files) do
        -- Only yield task-bearing files (discovery semantics).
        local f = io.open(fpath, "r")
        if f then
          local has_task = false
          for line in f:lines() do
            if line:match("^%s*[-*+] %[.%] ") then
              has_task = true
              break
            end
          end
          f:close()
          if has_task then
            on_path(fpath)
          end
        end
      end
      on_exit(0)
    end,
  })
end

integration_tests["fixture scan: 3 files, one ignored, global_filter=#task → correct count"] = function()
  set_obsidian_stub()
  reset_opts({ global_filter = "#task" })

  local cleanup_obs = fixture_adapter_stub()

  -- The global_filter hook lives in index/init.lua; reproduce it here.
  local function make_on_task(_)
    return function(task)
      return task.description:find("#task", 1, true) ~= nil
    end
  end

  package.loaded["obsidian-tasks.index.ignore"] = nil
  package.loaded["obsidian-tasks.index.scan"] = nil
  local scan = fresh("obsidian-tasks.index.scan")

  local tasks = {}
  local done = false
  scan.walk({ root = VAULT }, function(task, abs_path, _)
    tasks[#tasks + 1] = { task = task, path = abs_path }
  end, function(_)
    done = true
  end, make_on_task)

  cleanup_obs()

  MiniTest.expect.equality(done, true)

  -- ignored_note.md has `tasks-plugin.ignore: true` → its tasks must NOT appear
  local ignored_path = fixture("ignored_note.md")
  for _, item in ipairs(tasks) do
    MiniTest.expect.equality(norm(item.path) ~= ignored_path, true)
  end

  -- global_filter='#task': every surviving task's description must contain "#task"
  for _, item in ipairs(tasks) do
    MiniTest.expect.equality(item.task.description:find("#task", 1, true) ~= nil, true)
  end

  -- Known #task-tagged tasks from tasks_a/tasks_b must be present
  MiniTest.expect.equality(has_desc(tasks, "Buy milk"), true)
  MiniTest.expect.equality(has_desc(tasks, "Write report"), true)
  MiniTest.expect.equality(has_desc(tasks, "Call dentist"), true)
  MiniTest.expect.equality(has_desc(tasks, "Fix bug"), true)

  -- Non-tagged tasks must be excluded
  MiniTest.expect.equality(has_desc(tasks, "Non-tagged item"), false)
  MiniTest.expect.equality(has_desc(tasks, "Item without tag"), false)
end

integration_tests["fixture scan: no global_filter → includes all non-ignored tasks"] = function()
  set_obsidian_stub()
  reset_opts({ global_filter = nil })

  local cleanup_obs = fixture_adapter_stub()

  package.loaded["obsidian-tasks.index.ignore"] = nil
  package.loaded["obsidian-tasks.index.scan"] = nil
  local scan = fresh("obsidian-tasks.index.scan")

  local tasks = {}
  scan.walk({ root = VAULT }, function(task, abs_path, _)
    tasks[#tasks + 1] = { task = task, path = abs_path }
  end, function() end)

  cleanup_obs()

  -- ignored_note.md must NOT appear
  local ignored_path = fixture("ignored_note.md")
  for _, item in ipairs(tasks) do
    MiniTest.expect.equality(norm(item.path) ~= ignored_path, true)
  end

  -- Without global_filter, both #task-tagged and untagged tasks are included
  MiniTest.expect.equality(has_desc(tasks, "Buy milk"), true)
  MiniTest.expect.equality(has_desc(tasks, "Non-tagged item"), true)
  MiniTest.expect.equality(has_desc(tasks, "Item without tag"), true)
  MiniTest.expect.equality(has_desc(tasks, "Write report"), true) -- the lone [x] in tasks_a
end

T["integration"] = integration_tests

-- ── index refresh_all (async, stubbed discovery + real temp files) ────────

local refresh_all_tests = MiniTest.new_set()

refresh_all_tests["refresh_all: populates index after walk completes"] = function()
  set_obsidian_stub()
  reset_opts()

  -- Real temp files so the full-read parser has something to read.
  local path_a = norm(vim.fn.tempname() .. ".md")
  local path_b = norm(vim.fn.tempname() .. ".md")
  do
    local f = assert(io.open(path_a, "w"))
    f:write("- [ ] Task alpha\n- [ ] Task beta\n")
    f:close()
    f = assert(io.open(path_b, "w"))
    f:write("- [ ] Task gamma\n")
    f:close()
  end

  local cleanup_obs = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter_lines = real_parse_frontmatter_lines,
    discover_files_async = function(_, _, on_path, on_exit)
      on_path(path_a)
      on_path(path_b)
      on_exit(0)
    end,
  })
  local cleanup_ign = stub_module("obsidian-tasks.index.ignore", {
    is_ignored_fm = function(_)
      return false
    end,
  })

  package.loaded["obsidian-tasks.index.scan"] = nil
  local index = fresh("obsidian-tasks.index")
  index._reset()

  local done_called = false
  index.refresh_all({ root = "/vault" }, function()
    done_called = true
  end)

  cleanup_obs()
  cleanup_ign()
  os.remove(path_a)
  os.remove(path_b)

  MiniTest.expect.equality(done_called, true)

  local raw = index._raw()
  MiniTest.expect.equality(type(raw[path_a]), "table")
  MiniTest.expect.equality(#raw[path_a].tasks, 2)
  -- The node list carries the full structure (here: 2 task nodes).
  MiniTest.expect.equality(#raw[path_a].nodes, 2)
  MiniTest.expect.equality(type(raw[path_b]), "table")
  MiniTest.expect.equality(#raw[path_b].tasks, 1)
end

T["refresh_all"] = refresh_all_tests

return T
