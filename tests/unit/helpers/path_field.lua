-- tests/unit/helpers/path_field.lua
-- Shared template for per-field path filter parity tests.
--
-- The path family (path / filename / folder / root / backlink / description /
-- heading) all share the same `<field> includes <value>` and `<field> does
-- not include <value>` syntax.  Each derives a different STRING from the
-- task+path; the operator behavior is identical.  This helper builds the
-- common test set; field-specific value-extraction tests live in each
-- per-field test file.

local M = {}

local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(filter_line, task, path)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, path or "/vault/note.md")
end

--- Build a MiniTest set for a path-family field.
--- @param field        string   field name (e.g. "filename")
--- @param sample_path  string   absolute path that should match `includes <hit>`
--- @param hit          string   substring expected to match `<field> includes <hit>`
--- @param miss         string   substring expected to NOT match
--- @return table
function M.make_tests(field, sample_path, hit, miss)
  local T = MiniTest.new_set()
  local task = pt("- [ ] Task")

  T[string.format("%s includes %s: true when present", field, hit)] = function()
    eq(matches(string.format("%s includes %s", field, hit), task, sample_path), true)
  end

  T[string.format("%s includes %s: false when absent", field, miss)] = function()
    eq(matches(string.format("%s includes %s", field, miss), task, sample_path), false)
  end

  T[string.format("%s does not include %s: true when absent", field, miss)] = function()
    eq(matches(string.format("%s does not include %s", field, miss), task, sample_path), true)
  end

  T[string.format("%s does not include %s: false when present", field, hit)] = function()
    eq(matches(string.format("%s does not include %s", field, hit), task, sample_path), false)
  end

  -- Plural form (where both noun and verb pluralize)
  T[string.format("%ss include %s: plural form works", field, hit)] = function()
    eq(matches(string.format("%ss include %s", field, hit), task, sample_path), true)
  end

  return T
end

return M
