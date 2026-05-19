-- tests/unit/test_alias_resolver.lua
-- Unit tests for render/alias.lua — the frontmatter-alias resolver.
-- The obsidian adapter's parse_frontmatter is stubbed; the real-dependency
-- path is covered by tests/integration_real/test_alias_backlink.lua.

local T = MiniTest.new_set()

--- Inject a stub into package.loaded and return a cleanup fn.
local function stub_module(name, tbl)
  local prev = package.loaded[name]
  package.loaded[name] = tbl
  return function()
    package.loaded[name] = prev
  end
end

--- Fresh require of the resolver with an empty cache.
local function fresh_alias()
  package.loaded["obsidian-tasks.render.alias"] = nil
  return require("obsidian-tasks.render.alias")
end

--- Create a temp markdown file and return its absolute path.
local function temp_md(body)
  local path = vim.fn.tempname() .. ".md"
  local f = assert(io.open(path, "w"))
  f:write(body or "# note\n")
  f:close()
  return path
end

T["for_path: returns aliases[1] from a list"] = function()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { aliases = { "First Alias", "Second Alias" } }, {}
    end,
  })
  local alias = fresh_alias()
  local path = temp_md()
  MiniTest.expect.equality(alias.for_path(path), "First Alias")
  cleanup()
end

T["for_path: returns a bare-string alias"] = function()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { aliases = "Solo Alias" }, {}
    end,
  })
  local alias = fresh_alias()
  MiniTest.expect.equality(alias.for_path(temp_md()), "Solo Alias")
  cleanup()
end

T["for_path: nil when the note has no aliases"] = function()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { tags = { "x" } }, {}
    end,
  })
  local alias = fresh_alias()
  MiniTest.expect.equality(alias.for_path(temp_md()), nil)
  cleanup()
end

T["for_path: nil for empty aliases list"] = function()
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      return { aliases = {} }, {}
    end,
  })
  local alias = fresh_alias()
  MiniTest.expect.equality(alias.for_path(temp_md()), nil)
  cleanup()
end

T["for_path: nil for empty / nil path"] = function()
  local alias = fresh_alias()
  MiniTest.expect.equality(alias.for_path(""), nil)
  MiniTest.expect.equality(alias.for_path(nil), nil)
end

T["for_path: caches per path (parse called once)"] = function()
  local calls = 0
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      calls = calls + 1
      return { aliases = { "Cached" } }, {}
    end,
  })
  local alias = fresh_alias()
  local path = temp_md()
  MiniTest.expect.equality(alias.for_path(path), "Cached")
  MiniTest.expect.equality(alias.for_path(path), "Cached")
  MiniTest.expect.equality(calls, 1)
  cleanup()
end

T["for_path: re-parses when mtime changes"] = function()
  local result = { aliases = { "Old" } }
  local calls = 0
  local cleanup = stub_module("obsidian-tasks.util.obsidian", {
    parse_frontmatter = function(_)
      calls = calls + 1
      return result, {}
    end,
  })
  local alias = fresh_alias()
  local path = temp_md()
  MiniTest.expect.equality(alias.for_path(path), "Old")

  -- Bump the file's mtime so the cache entry is invalidated.
  local stat = vim.uv.fs_stat(path)
  local future = stat.mtime.sec + 100
  vim.uv.fs_utime(path, future, future)

  result = { aliases = { "New" } }
  MiniTest.expect.equality(alias.for_path(path), "New")
  MiniTest.expect.equality(calls, 2)
  cleanup()
end

return T
