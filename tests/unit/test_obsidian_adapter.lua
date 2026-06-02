-- tests/unit/test_obsidian_adapter.lua
-- Unit tests for util/obsidian.lua — the native vault adapter.
--
-- The adapter no longer depends on obsidian.nvim: vaults are detected by the
-- `.obsidian/` marker, content search shells out to ripgrep, and frontmatter is
-- parsed natively. These tests exercise that native behavior with NO `Obsidian`
-- global and no obsidian.* modules in play. (Real-rg streaming search is covered
-- in tests/integration/test_search_native.lua.)

local T = MiniTest.new_set()

--- Force a fresh require of the adapter.
local function fresh_adapter()
  package.loaded["obsidian-tasks.util.obsidian"] = nil
  return require("obsidian-tasks.util.obsidian")
end

--- Create a temp dir containing a `.obsidian/` marker and a `sub/` subdir.
local function make_tmp_vault()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.obsidian", "p")
  vim.fn.mkdir(root .. "/sub", "p")
  return root
end

local function rm(path)
  vim.fn.delete(path, "rf")
end

-- ── workspace_for_path: native .obsidian/ detection ──────────────────────────

T["workspace_for_path: synthesizes { root, name } from .obsidian/ ancestor"] = function()
  local root = make_tmp_vault()
  local adapter = fresh_adapter()
  local ws = adapter.workspace_for_path(root .. "/sub/note.md")
  rm(root)
  MiniTest.expect.equality(type(ws), "table")
  -- ws.root is vim.fs-normalized (forward slashes); compare against the
  -- normalized temp root so the assertion holds on Windows too.
  MiniTest.expect.equality(tostring(ws.root), vim.fs.normalize(root))
  MiniTest.expect.equality(ws.name, vim.fn.fnamemodify(root, ":t"))
end

T["workspace_for_path: nil when no .obsidian/ marker above the path"] = function()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/sub", "p") -- no .obsidian/
  local adapter = fresh_adapter()
  local ws = adapter.workspace_for_path(root .. "/sub/note.md")
  rm(root)
  MiniTest.expect.equality(ws, nil)
end

T["workspace_for_path: nil / empty path returns nil"] = function()
  local adapter = fresh_adapter()
  MiniTest.expect.equality(adapter.workspace_for_path(nil), nil)
  MiniTest.expect.equality(adapter.workspace_for_path(""), nil)
end

T["workspace_for_path: works with no Obsidian global set"] = function()
  _G.Obsidian = nil
  local root = make_tmp_vault()
  local adapter = fresh_adapter()
  local ws = adapter.workspace_for_path(root .. "/sub/note.md")
  rm(root)
  MiniTest.expect.equality(type(ws), "table")
  MiniTest.expect.equality(tostring(ws.root), vim.fs.normalize(root))
end

-- ── search_async: missing ripgrep guard ──────────────────────────────────────

T["search_async: missing rg → on_exit(127), no matches emitted"] = function()
  local adapter = fresh_adapter()
  -- Shadow vim.fn.executable so "rg" reports missing.
  vim.fn.executable = function(name)
    if name == "rg" then
      return 0
    end
    return 1
  end

  local matched, code
  adapter.search_async({ root = "/vault" }, "x", function()
    matched = true
  end, function(c)
    code = c
  end)

  vim.fn.executable = nil -- remove shadow; __index resumes the builtin

  MiniTest.expect.equality(matched, nil)
  MiniTest.expect.equality(code, 127)
end

-- ── parse_frontmatter ─────────────────────────────────────────────────────────

local function write_tmp(contents)
  local path = vim.fn.tempname() .. ".md"
  local f = assert(io.open(path, "w"))
  f:write(contents)
  f:close()
  return path
end

T["parse_frontmatter: parses aliases list and tasks-plugin.ignore"] = function()
  local path = write_tmp("---\naliases: [Alpha, Beta]\ntasks-plugin:\n  ignore: true\n---\n# Body\n")
  local adapter = fresh_adapter()
  local fm, errs = adapter.parse_frontmatter(path)
  os.remove(path)
  MiniTest.expect.equality(type(fm), "table")
  MiniTest.expect.equality(fm.aliases[1], "Alpha")
  MiniTest.expect.equality(fm.aliases[2], "Beta")
  MiniTest.expect.equality(fm["tasks-plugin"].ignore, true)
  MiniTest.expect.equality(#errs, 0)
end

T["parse_frontmatter: file without frontmatter → empty table"] = function()
  local path = write_tmp("# Just a heading\n- [ ] task\n")
  local adapter = fresh_adapter()
  local fm, errs = adapter.parse_frontmatter(path)
  os.remove(path)
  MiniTest.expect.equality(fm, {})
  MiniTest.expect.equality(#errs, 0)
end

T["parse_frontmatter: unreadable file → nil + error"] = function()
  local adapter = fresh_adapter()
  local fm, errs = adapter.parse_frontmatter("/nonexistent/does/not/exist.md")
  MiniTest.expect.equality(fm, nil)
  MiniTest.expect.equality(type(errs), "table")
  MiniTest.expect.equality(#errs >= 1, true)
end

-- ── workspace_path_filter ─────────────────────────────────────────────────────

T["workspace_path_filter: matches paths under root"] = function()
  local adapter = fresh_adapter()
  local pred = adapter.workspace_path_filter("/vault")
  MiniTest.expect.equality(pred("/vault/note.md"), true)
  MiniTest.expect.equality(pred("/vault/sub/note.md"), true)
end

T["workspace_path_filter: trailing-slash boundary excludes sibling dirs"] = function()
  local adapter = fresh_adapter()
  local pred = adapter.workspace_path_filter("/vault")
  -- "/vault-other" must NOT be considered inside "/vault".
  MiniTest.expect.equality(pred("/vault-other/note.md"), false)
end

-- The OS-native path separator: `\` on Windows, `/` on POSIX.
local NATIVE_SEP = package.config:sub(1, 1)

T["workspace_path_filter: matches rg's mixed-separator path (Windows regression)"] = function()
  local adapter = fresh_adapter()
  -- On Windows, rg echoes the forward-slash root prefix verbatim but joins the
  -- descendants it discovers with the OS-native backslash, so index keys look
  -- like `C:/vault\sub\note.md`.  The filter must still match.  On POSIX the
  -- native sep is `/`, so this degenerates to the existing forward-slash case.
  local root = "C:/vault"
  local pred = adapter.workspace_path_filter(root)
  local mixed = root .. NATIVE_SEP .. "sub" .. NATIVE_SEP .. "note.md"
  MiniTest.expect.equality(pred(mixed), true)
end

-- ── normalize ─────────────────────────────────────────────────────────────────

T["normalize: result carries no OS-native backslash separator"] = function()
  local adapter = fresh_adapter()
  local mixed = "C:/vault" .. NATIVE_SEP .. "sub" .. NATIVE_SEP .. "note.md"
  local out = adapter.normalize(mixed)
  -- After normalization no backslash separator survives on any platform.
  MiniTest.expect.equality(out:find("\\", 1, true), nil)
  MiniTest.expect.equality(out, "C:/vault/sub/note.md")
end

T["normalize: nil / empty passthrough"] = function()
  local adapter = fresh_adapter()
  MiniTest.expect.equality(adapter.normalize(nil), nil)
  MiniTest.expect.equality(adapter.normalize(""), "")
end

return T
