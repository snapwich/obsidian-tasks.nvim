-- tests/unit/test_query_filter_tags.lua
-- Parity with .deps/obsidian-tasks/tests/Query/Filter/TagsField.test.ts

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local parse_task = require("obsidian-tasks.task.parse")
local qp = require("obsidian-tasks.query.parse")
local filter_mod = require("obsidian-tasks.query.filter")

local function pt(line)
  return assert(parse_task.parse(line), "expected task line: " .. line)
end

local function matches(filter_line, task)
  local ast = qp.parse(filter_line)
  local pred = filter_mod.compile_all(ast.filters)
  return pred(task, "/vault/note.md")
end

-- ── has tag / no tag ──────────────────────────────────────────────────────

T["has tag: true when task has any tag"] = function()
  eq(matches("has tag", pt("- [ ] Task #work")), true)
end

T["has tag: false when task has none"] = function()
  eq(matches("has tag", pt("- [ ] Task")), false)
end

T["no tag: inverse of has tag"] = function()
  eq(matches("no tag", pt("- [ ] Task")), true)
  eq(matches("no tag", pt("- [ ] Task #foo")), false)
end

-- ── tag includes <value> ─────────────────────────────────────────────────

T["tag includes #work: matches exact tag"] = function()
  eq(matches("tag includes #work", pt("- [ ] Task #work")), true)
end

T["tag includes #work: false when tag is absent"] = function()
  eq(matches("tag includes #work", pt("- [ ] Task #personal")), false)
end

T["tag includes is case-insensitive"] = function()
  -- Upstream: tag matching is case-insensitive.
  eq(matches("tag includes #WORK", pt("- [ ] Task #work")), true)
  eq(matches("tag includes #work", pt("- [ ] Task #Work")), true)
end

-- ── nested tags (#parent/child) ──────────────────────────────────────────

T["tag includes #parent: matches nested tag (#parent/child)"] = function()
  -- Upstream parity: `tag includes #parent` matches tasks with #parent OR
  -- any nested #parent/child tag.
  eq(matches("tag includes #project", pt("- [ ] Task #project/web")), true)
end

T["tag includes #project/web: matches exact nested tag"] = function()
  eq(matches("tag includes #project/web", pt("- [ ] Task #project/web")), true)
end

T["tag includes #project/web: false when task only has #project"] = function()
  eq(matches("tag includes #project/web", pt("- [ ] Task #project")), false)
end

T["tag includes substring match: #wor matches #work"] = function()
  -- Substring match is upstream behavior.
  eq(matches("tag includes #wor", pt("- [ ] Task #work")), true)
end

-- ── tag does not include ──────────────────────────────────────────────────

T["tag does not include #work: true when tag absent"] = function()
  eq(matches("tag does not include #work", pt("- [ ] Task #personal")), true)
end

T["tag does not include #work: false when tag present"] = function()
  eq(matches("tag does not include #work", pt("- [ ] Task #work")), false)
end

T["tag does not include #work: false when nested #work/x present"] = function()
  -- Parity with the substring/prefix semantics — nested tags count.
  eq(matches("tag does not include #work", pt("- [ ] Task #work/web")), false)
end

-- ── singular vs plural keyword equivalence ────────────────────────────────

T["tags include #work: plural noun, plural verb"] = function()
  eq(matches("tags include #work", pt("- [ ] Task #work")), true)
end

T["tags includes #work: plural noun, singular verb"] = function()
  eq(matches("tags includes #work", pt("- [ ] Task #work")), true)
end

T["tags do not include #work: plural noun, plural verb (negative)"] = function()
  eq(matches("tags do not include #work", pt("- [ ] Task #personal")), true)
end

return T
