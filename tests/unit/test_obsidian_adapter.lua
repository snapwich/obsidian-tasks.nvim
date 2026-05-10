-- tests/unit/test_obsidian_adapter.lua
-- Unit tests for util/obsidian.lua adapter.
-- Uses stub _G.Obsidian global and package.loaded stubs for obsidian.* modules.
-- No real obsidian.nvim is required at test time.

local T = MiniTest.new_set()

-- ── helpers ────────────────────────────────────────────────────────────────────

--- Force a fresh require of the adapter (clear cache so each test starts clean).
local function fresh_adapter()
  package.loaded["obsidian-tasks.util.obsidian"] = nil
  return require("obsidian-tasks.util.obsidian")
end

--- Set a minimal stub _G.Obsidian to satisfy the module guard.
local function set_obsidian_stub(overrides)
  _G.Obsidian = vim.tbl_deep_extend("force", {
    workspace = { root = "/vault", name = "default" },
    workspaces = { { root = "/vault", name = "default" } },
  }, overrides or {})
end

--- Inject a stub module into package.loaded and return a cleanup function.
local function stub_module(name, tbl)
  local prev = package.loaded[name]
  package.loaded[name] = tbl
  return function()
    package.loaded[name] = prev
  end
end

--- Run fn and return true if it raised an error matching pattern.
local function raises(fn, pattern)
  local ok, err = pcall(fn)
  if ok then
    return false, "expected error but none was raised"
  end
  if pattern and not tostring(err):find(pattern, 1, true) then
    return false, ("error %q does not match %q"):format(tostring(err), pattern)
  end
  return true
end

-- ── module guard ───────────────────────────────────────────────────────────────

T["guard: raises when _G.Obsidian is nil"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.current_workspace()
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for workspace_for_path when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.workspace_for_path("/some/path")
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for workspaces() when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.workspaces()
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for find_files_async when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.find_files_async({}, function() end, function() end)
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for search_async when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.search_async({}, "pattern", function() end, function() end)
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for parse_frontmatter when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.parse_frontmatter("/some/file.md")
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for path() when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.path("/some/path")
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

T["guard: raises for set_workspace when unset"] = function()
  _G.Obsidian = nil
  local adapter = fresh_adapter()
  local ok = raises(function()
    adapter.set_workspace("default")
  end, "requires obsidian.nvim to be set up first")
  MiniTest.expect.equality(ok, true)
end

-- ── current_workspace ─────────────────────────────────────────────────────────

T["current_workspace: returns _G.Obsidian.workspace"] = function()
  set_obsidian_stub({ workspace = { root = "/my/vault", name = "my-vault" } })
  local adapter = fresh_adapter()
  local ws = adapter.current_workspace()
  MiniTest.expect.equality(ws.root, "/my/vault")
  MiniTest.expect.equality(ws.name, "my-vault")
end

-- ── workspaces ────────────────────────────────────────────────────────────────

T["workspaces: returns _G.Obsidian.workspaces array"] = function()
  set_obsidian_stub({
    workspaces = { { name = "ws1" }, { name = "ws2" } },
  })
  local adapter = fresh_adapter()
  local wss = adapter.workspaces()
  MiniTest.expect.equality(#wss, 2)
  MiniTest.expect.equality(wss[1].name, "ws1")
  MiniTest.expect.equality(wss[2].name, "ws2")
end

-- ── workspace_for_path ────────────────────────────────────────────────────────

T["workspace_for_path: calls obsidian.api.find_workspace with correct arg"] = function()
  set_obsidian_stub()
  local called_with
  local cleanup = stub_module("obsidian.api", {
    find_workspace = function(p)
      called_with = p
      return { root = p, name = "found" }
    end,
  })
  local adapter = fresh_adapter()
  local result = adapter.workspace_for_path("/some/abs/path")
  cleanup()
  MiniTest.expect.equality(called_with, "/some/abs/path")
  MiniTest.expect.equality(result.name, "found")
end

T["workspace_for_path: returns nil when api returns nil"] = function()
  set_obsidian_stub()
  local cleanup = stub_module("obsidian.api", {
    find_workspace = function(_)
      return nil
    end,
  })
  local adapter = fresh_adapter()
  local result = adapter.workspace_for_path("/no/match")
  cleanup()
  MiniTest.expect.equality(result, nil)
end

-- ── set_workspace ─────────────────────────────────────────────────────────────

T["set_workspace: calls obsidian.Workspace.set with arg"] = function()
  set_obsidian_stub()
  local called_with
  local cleanup = stub_module("obsidian", {
    Workspace = {
      set = function(arg)
        called_with = arg
      end,
    },
  })
  local adapter = fresh_adapter()
  adapter.set_workspace("my-ws")
  cleanup()
  MiniTest.expect.equality(called_with, "my-ws")
end

T["set_workspace: passes workspace object through"] = function()
  set_obsidian_stub()
  local called_with
  local cleanup = stub_module("obsidian", {
    Workspace = {
      set = function(arg)
        called_with = arg
      end,
    },
  })
  local ws_obj = { root = "/v", name = "w" }
  local adapter = fresh_adapter()
  adapter.set_workspace(ws_obj)
  cleanup()
  MiniTest.expect.equality(called_with, ws_obj)
end

-- ── find_files_async ──────────────────────────────────────────────────────────

T["find_files_async: calls search.find_async with workspace.root"] = function()
  set_obsidian_stub()
  local captured = {}
  local cleanup = stub_module("obsidian.search", {
    find_async = function(root, query, opts, on_match, on_exit)
      captured.root = root
      captured.query = query
      -- simulate two hits: one .md and one non-md
      on_match("/vault/note.md")
      on_match("/vault/image.png")
      on_exit(0)
    end,
  })
  local adapter = fresh_adapter()
  local matches = {}
  local exit_code
  adapter.find_files_async({ root = "/vault" }, function(p)
    matches[#matches + 1] = p
  end, function(code)
    exit_code = code
  end)
  cleanup()
  MiniTest.expect.equality(captured.root, "/vault")
  MiniTest.expect.equality(captured.query, "")
  -- only .md file should be forwarded
  MiniTest.expect.equality(#matches, 1)
  MiniTest.expect.equality(matches[1], "/vault/note.md")
  MiniTest.expect.equality(exit_code, 0)
end

T["find_files_async: filters out non-md files"] = function()
  set_obsidian_stub()
  local cleanup = stub_module("obsidian.search", {
    find_async = function(_, _, _, on_match, on_exit)
      on_match("/vault/a.md")
      on_match("/vault/b.txt")
      on_match("/vault/c.lua")
      on_match("/vault/d.MD") -- uppercase extension should NOT match *.md
      on_match("/vault/e.md")
      on_exit(0)
    end,
  })
  local adapter = fresh_adapter()
  local matches = {}
  adapter.find_files_async({ root = "/vault" }, function(p)
    matches[#matches + 1] = p
  end, function() end)
  cleanup()
  MiniTest.expect.equality(#matches, 2)
  MiniTest.expect.equality(matches[1], "/vault/a.md")
  MiniTest.expect.equality(matches[2], "/vault/e.md")
end

-- ── search_async ──────────────────────────────────────────────────────────────

T["search_async: calls search.search_async with correct args"] = function()
  set_obsidian_stub()
  local captured = {}
  local fake_match = { path = { text = "/vault/note.md" }, line_number = 3 }
  local cleanup = stub_module("obsidian.search", {
    search_async = function(root, pattern, opts, on_match, on_exit)
      captured.root = root
      captured.pattern = pattern
      on_match(fake_match)
      on_exit(0)
    end,
  })
  local adapter = fresh_adapter()
  local got_match
  local exit_code
  adapter.search_async({ root = "/vault" }, "TODO", function(m)
    got_match = m
  end, function(code)
    exit_code = code
  end)
  cleanup()
  MiniTest.expect.equality(captured.root, "/vault")
  MiniTest.expect.equality(captured.pattern, "TODO")
  MiniTest.expect.equality(got_match, fake_match)
  MiniTest.expect.equality(exit_code, 0)
end

-- ── parse_frontmatter ─────────────────────────────────────────────────────────

T["parse_frontmatter: calls frontmatter.parse with lines and path"] = function()
  set_obsidian_stub()
  -- Write a real temp file so io.open works
  local tmpfile = os.tmpname() .. ".md"
  local f = io.open(tmpfile, "w")
  f:write("---\ntitle: Test\n---\n# Content\n")
  f:close()

  local captured = {}
  local cleanup = stub_module("obsidian.frontmatter", {
    parse = function(lines, path)
      captured.lines = lines
      captured.path = path
      return { title = "Test" }, {}
    end,
  })
  local adapter = fresh_adapter()
  local meta, errs = adapter.parse_frontmatter(tmpfile)
  cleanup()
  os.remove(tmpfile)

  MiniTest.expect.equality(type(captured.lines), "table")
  MiniTest.expect.equality(captured.path, tmpfile)
  MiniTest.expect.equality(meta.title, "Test")
  MiniTest.expect.equality(#errs, 0)
end

T["parse_frontmatter: returns nil + error table when file unreadable"] = function()
  set_obsidian_stub()
  local cleanup = stub_module("obsidian.frontmatter", {
    parse = function(_, _)
      return {}, {}
    end,
  })
  local adapter = fresh_adapter()
  local meta, errs = adapter.parse_frontmatter("/nonexistent/file/that/does/not/exist.md")
  cleanup()
  MiniTest.expect.equality(meta, nil)
  MiniTest.expect.equality(type(errs), "table")
  MiniTest.expect.equality(#errs >= 1, true)
end

-- ── path shorthand ────────────────────────────────────────────────────────────

T["path: calls obsidian.path.Path.new with argument"] = function()
  set_obsidian_stub()
  local called_with
  local fake_path_obj = { __type = "Path", str = "/my/path" }
  local cleanup = stub_module("obsidian.path", {
    Path = {
      new = function(p)
        called_with = p
        return fake_path_obj
      end,
    },
  })
  local adapter = fresh_adapter()
  local result = adapter.path("/my/path")
  cleanup()
  MiniTest.expect.equality(called_with, "/my/path")
  MiniTest.expect.equality(result, fake_path_obj)
end

return T
