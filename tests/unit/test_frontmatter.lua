-- tests/unit/test_frontmatter.lua
-- Unit tests for util/frontmatter.lua — the native YAML-lite parser.
-- Scope is intentionally narrow: aliases (string/list) and tasks-plugin.ignore.

local T = MiniTest.new_set()

local fm = require("obsidian-tasks.util.frontmatter")

--- Parse from a multi-line string (split on newlines), returning the table.
local function parse(text)
  local tbl = fm.parse(vim.split(text, "\n", { plain = true }))
  return tbl
end

-- ── empty / scalars ────────────────────────────────────────────────────────

T["empty input → empty table"] = function()
  MiniTest.expect.equality(fm.parse({}), {})
  MiniTest.expect.equality(fm.parse(nil), {})
end

T["scalar string value"] = function()
  local t = parse("title: My Note")
  MiniTest.expect.equality(t.title, "My Note")
end

T["quoted string strips surrounding quotes"] = function()
  local t = parse([[title: "Quoted, with comma"]])
  MiniTest.expect.equality(t.title, "Quoted, with comma")
end

T["bare true / false become booleans"] = function()
  local t = parse("draft: true\npublished: false")
  MiniTest.expect.equality(t.draft, true)
  MiniTest.expect.equality(t.published, false)
end

T["comment and blank lines are ignored"] = function()
  local t = parse("# a comment\n\ntitle: Kept")
  MiniTest.expect.equality(t.title, "Kept")
end

-- ── aliases ────────────────────────────────────────────────────────────────

T["aliases: bare string"] = function()
  local t = parse("aliases: Project Alpha")
  MiniTest.expect.equality(t.aliases, "Project Alpha")
end

T["aliases: inline list"] = function()
  local t = parse("aliases: [Alpha, Beta, Gamma]")
  MiniTest.expect.equality(type(t.aliases), "table")
  MiniTest.expect.equality(t.aliases[1], "Alpha")
  MiniTest.expect.equality(t.aliases[2], "Beta")
  MiniTest.expect.equality(t.aliases[3], "Gamma")
end

T["aliases: block list (indented dashes)"] = function()
  local t = parse("aliases:\n  - First\n  - Second")
  MiniTest.expect.equality(type(t.aliases), "table")
  MiniTest.expect.equality(t.aliases[1], "First")
  MiniTest.expect.equality(t.aliases[2], "Second")
end

T["aliases: block list (non-indented dashes)"] = function()
  local t = parse("aliases:\n- One\n- Two")
  MiniTest.expect.equality(t.aliases[1], "One")
  MiniTest.expect.equality(t.aliases[2], "Two")
end

-- ── tasks-plugin.ignore ──────────────────────────────────────────────────────

T["tasks-plugin.ignore: nested map → true"] = function()
  local t = parse("tasks-plugin:\n  ignore: true")
  MiniTest.expect.equality(type(t["tasks-plugin"]), "table")
  MiniTest.expect.equality(t["tasks-plugin"].ignore, true)
end

T["tasks-plugin.ignore: nested map → false"] = function()
  local t = parse("tasks-plugin:\n  ignore: false")
  MiniTest.expect.equality(t["tasks-plugin"].ignore, false)
end

T["tasks-plugin.ignore: flat dotted key → true"] = function()
  local t = parse("tasks-plugin.ignore: true")
  MiniTest.expect.equality(t["tasks-plugin.ignore"], true)
end

-- ── mixed document ───────────────────────────────────────────────────────────

T["mixed: keys after a block do not bleed into the block"] = function()
  local t = parse("aliases:\n  - A\n  - B\ntitle: After Block")
  MiniTest.expect.equality(t.aliases[1], "A")
  MiniTest.expect.equality(t.aliases[2], "B")
  MiniTest.expect.equality(t.title, "After Block")
end

T["mixed: tasks-plugin nested then sibling top-level key"] = function()
  local t = parse("tasks-plugin:\n  ignore: true\ntags: [x, y]")
  MiniTest.expect.equality(t["tasks-plugin"].ignore, true)
  MiniTest.expect.equality(t.tags[1], "x")
  MiniTest.expect.equality(t.tags[2], "y")
end

return T
