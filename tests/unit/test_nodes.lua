-- tests/unit/test_nodes.lua
-- Unit tests for index/nodes.lua — the unified per-file node parser that
-- replaces the two former task-only parsers.
--
-- Covers: task / bullet / blank classification, numeric depth (indent level),
-- parent_line linkage via the indent stack, the no-skip clamp, running-heading
-- attachment to task nodes, and parse_file's file-size guard + flat task view.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local nodes = require("obsidian-tasks.index.nodes")

--- Parse inline lines (split on "\n") into a node list.
local function parse(text)
  return nodes.parse_lines(vim.split(text, "\n", { plain = true }))
end

--- Index a node list by line_num for assertions.
local function by_line(ns)
  local map = {}
  for _, n in ipairs(ns) do
    map[n.line_num] = n
  end
  return map
end

-- ── classification ─────────────────────────────────────────────────────────

T["classifies tasks, bullets, blanks; omits prose"] = function()
  local ns = parse(table.concat({
    "- [ ] A task", -- 1 task
    "- a bullet", -- 2 bullet
    "", -- 3 blank
    "just prose", -- 4 omitted
    "* star bullet", -- 5 bullet
    "+ plus bullet", -- 6 bullet
    "- [x] done task", -- 7 task
  }, "\n"))

  local m = by_line(ns)
  eq(m[1].kind, "task")
  eq(m[1].task.description, "A task")
  eq(m[2].kind, "bullet")
  eq(m[2].text, "a bullet")
  eq(m[3].kind, "blank")
  eq(m[4], nil) -- prose omitted
  eq(m[5].kind, "bullet")
  eq(m[6].kind, "bullet")
  eq(m[7].kind, "task")
  eq(m[7].task.status_symbol, "x")
end

T["a bare marker on its own line is a bullet with empty text"] = function()
  local ns = parse("-\n  *  ")
  eq(#ns, 2)
  eq(ns[1].kind, "bullet")
  eq(ns[1].text, "")
  eq(ns[2].kind, "bullet")
  eq(ns[2].text, "")
end

-- ── bullet round-trip metadata (Phase 5a): marker + raw indent ──────────────

T["bullet: captures the literal marker (-/*/+) and trimmed body"] = function()
  local ns = parse(table.concat({
    "- dash bullet",
    "* star bullet",
    "+ plus bullet",
  }, "\n"))
  local m = by_line(ns)
  eq(m[1].marker, "-")
  eq(m[1].text, "dash bullet")
  eq(m[2].marker, "*")
  eq(m[2].text, "star bullet")
  eq(m[3].marker, "+")
  eq(m[3].text, "plus bullet")
end

T["bullet: captures the raw leading-whitespace indent (spaces and tabs)"] = function()
  -- A root task anchors the subtree; the bullets nest under it with space and
  -- tab indents whose RAW string must be preserved verbatim for round-trip.
  local ns = parse(table.concat({
    "- [ ] root",
    "    * four-space star", -- 4 literal spaces
    "\t+ tab plus", -- 1 literal tab
    "  - two-space dash", -- 2 literal spaces
  }, "\n"))
  local m = by_line(ns)
  eq(m[2].kind, "bullet")
  eq(m[2].indent, "    ")
  eq(m[2].marker, "*")
  eq(m[3].indent, "\t")
  eq(m[3].marker, "+")
  eq(m[4].indent, "  ")
  eq(m[4].marker, "-")
end

T["bullet: indent + marker + ' ' + text reconstructs the source line exactly"] = function()
  for _, line in ipairs({
    "- a dash bullet",
    "    * a four-space star bullet",
    "\t+ a tab plus bullet",
  }) do
    local n = parse(line)[1]
    eq(n.kind, "bullet")
    eq(n.indent .. n.marker .. " " .. n.text, line)
  end
end

-- ── depth (numeric indent level) ────────────────────────────────────────────

T["depth: top-level is 0, nested increments by indent"] = function()
  local ns = parse(table.concat({
    "- [ ] root", -- 1 depth 0
    "  - [ ] child", -- 2 depth 1
    "    - grandchild bullet", -- 3 depth 2
    "  - [ ] second child", -- 4 depth 1
    "- [ ] second root", -- 5 depth 0
  }, "\n"))
  local m = by_line(ns)
  eq(m[1].depth, 0)
  eq(m[2].depth, 1)
  eq(m[3].depth, 2)
  eq(m[4].depth, 1)
  eq(m[5].depth, 0)
end

T["depth: tabs expand to indent levels"] = function()
  local ns = parse("- [ ] root\n\t- [ ] tabbed child")
  local m = by_line(ns)
  eq(m[1].depth, 0)
  eq(m[2].depth, 1)
end

-- ── parent_line linkage ─────────────────────────────────────────────────────

T["parent_line: child points at nearest shallower node above"] = function()
  local ns = parse(table.concat({
    "- [ ] root", -- 1
    "  - [ ] child", -- 2 → parent 1
    "    - grandchild", -- 3 → parent 2
    "  - [ ] child2", -- 4 → parent 1
    "- [ ] root2", -- 5 → parent nil
  }, "\n"))
  local m = by_line(ns)
  eq(m[1].parent_line, nil)
  eq(m[2].parent_line, 1)
  eq(m[3].parent_line, 2)
  eq(m[4].parent_line, 1)
  eq(m[5].parent_line, nil)
end

T["parent_line: same-indent siblings share a parent"] = function()
  local ns = parse(table.concat({
    "- [ ] root", -- 1
    "  - [ ] a", -- 2 → parent 1
    "  - [ ] b", -- 3 → parent 1
    "  - desc", -- 4 → parent 1
  }, "\n"))
  local m = by_line(ns)
  eq(m[2].parent_line, 1)
  eq(m[3].parent_line, 1)
  eq(m[4].parent_line, 1)
end

T["parent_line: dedenting resolves to the right ancestor (no-skip clamp)"] = function()
  -- A deeply-indented line that jumps several columns is still only ONE level
  -- deeper than its resolved parent; a following dedent must re-find the
  -- correct ancestor rather than skip levels.
  local ns = parse(table.concat({
    "- [ ] root", -- 1 depth 0
    "      - [ ] deep child", -- 2 depth 1 (parent 1; big indent gap clamped)
    "  - [ ] mid", -- 3 depth 1 (parent 1)
    "- [ ] root2", -- 4 depth 0
  }, "\n"))
  local m = by_line(ns)
  eq(m[2].depth, 1)
  eq(m[2].parent_line, 1)
  eq(m[3].depth, 1)
  eq(m[3].parent_line, 1)
  eq(m[4].depth, 0)
  eq(m[4].parent_line, nil)
end

T["blanks interspersed in a subtree do not break parent linkage"] = function()
  local ns = parse(table.concat({
    "- [ ] root", -- 1
    "  - [ ] child", -- 2 → parent 1
    "", -- 3 blank (no depth/parent)
    "  - desc bullet", -- 4 → parent 1
  }, "\n"))
  local m = by_line(ns)
  eq(m[3].kind, "blank")
  eq(m[3].depth, nil)
  eq(m[4].parent_line, 1)
end

-- ── heading attachment (separate axis) ──────────────────────────────────────

T["heading: tasks carry the nearest preceding ATX heading; headings are not nodes"] = function()
  local ns = parse(table.concat({
    "# Top", -- not a node
    "- [ ] under top", -- 2
    "## Section A", -- not a node
    "- [ ] under A", -- 4
    "  - nested bullet", -- 5 (no heading field; bullets don't track it)
    "### Section B ###", -- not a node, closing ### stripped
    "- [ ] under B", -- 7
  }, "\n"))
  local m = by_line(ns)
  eq(m[1], nil)
  eq(m[2].kind, "task")
  eq(m[2].heading, "Top")
  eq(m[2].task.heading, "Top")
  eq(m[4].heading, "Section A")
  eq(m[7].heading, "Section B")
end

T["heading: a task above any heading has nil heading"] = function()
  local ns = parse("- [ ] orphan\n# Later")
  local m = by_line(ns)
  eq(m[1].kind, "task")
  eq(m[1].heading, nil)
end

T["heading: a heading flushes the indent stack (no cross-heading subtree)"] = function()
  -- A more-indented task that FOLLOWS a heading must NOT parent to a node from
  -- before the heading.  Headings are structural breaks: the indented task is
  -- top-level despite sitting under `- [ ] root` in column terms.
  local ns = parse(table.concat({
    "- [ ] root", -- 1 depth 0, parent nil
    "## A", -- heading: flush
    "  - [ ] indented", -- 3 depth 0 (fresh stack), parent nil — NOT child of line 1
  }, "\n"))
  local m = by_line(ns)
  eq(m[1].parent_line, nil)
  eq(m[1].depth, 0)
  eq(m[3].kind, "task")
  eq(m[3].parent_line, nil) -- flushed: does not cross the heading to line 1
  eq(m[3].depth, 0)
end

-- ── on_task hook (global_filter / DateFallback analogue) ─────────────────────

T["on_task: returning false drops the task and keeps the tree well-formed"] = function()
  -- Sibling veto: line 2 (`drop me`) sits at the SAME indent as kept line 1, so
  -- resolving line 2 pops line 1 off the stack; line 2 is then vetoed and NOT
  -- re-pushed.  Line 3 (`child`, indented) therefore finds an EMPTY stack and is
  -- top-level (parent_line=nil, depth=0).  Crucially it never references the
  -- dropped line 2, satisfying the well-formedness contract.
  local ns = nodes.parse_lines(vim.split("- [ ] keep #t\n- [ ] drop me\n  - [ ] child #t", "\n", { plain = true }), {
    on_task = function(task)
      return task.description:find("#t", 1, true) ~= nil
    end,
  })
  local m = by_line(ns)
  eq(m[1].kind, "task")
  eq(m[1].parent_line, nil)
  eq(m[1].depth, 0)
  eq(m[2], nil) -- dropped
  eq(m[3].kind, "task")
  eq(m[3].parent_line, nil) -- not the dropped line 2; stack was empty
  eq(m[3].depth, 0)
end

T["on_task: 3-level veto re-parents leaf to nearest KEPT ancestor"] = function()
  -- root(kept) / mid(vetoed) / leaf(kept): the leaf is indented under mid,
  -- which is indented under root.  mid is dropped and NOT pushed, so leaf must
  -- re-parent to root (the nearest kept ancestor) with contiguous depth — never
  -- to the dropped mid line.
  local ns =
    nodes.parse_lines(vim.split("- [ ] root #t\n  - [ ] mid drop\n    - [ ] leaf #t", "\n", { plain = true }), {
      on_task = function(task)
        return task.description:find("#t", 1, true) ~= nil
      end,
    })
  local m = by_line(ns)
  eq(m[1].kind, "task")
  eq(m[1].parent_line, nil)
  eq(m[1].depth, 0)
  eq(m[2], nil) -- mid vetoed + dropped
  eq(m[3].kind, "task")
  eq(m[3].parent_line, 1) -- re-parented to kept root, NOT the dropped mid (line 2)
  eq(m[3].depth, 1) -- contiguous: root.depth + 1, no gap
end

T["on_task: leaf under only-vetoed ancestors becomes top-level"] = function()
  -- root(vetoed) / leaf(kept): every ancestor of leaf is vetoed, so leaf is
  -- top-level (parent_line=nil, depth=0), never referencing the dropped root.
  local ns = nodes.parse_lines(vim.split("- [ ] root drop\n  - [ ] leaf #t", "\n", { plain = true }), {
    on_task = function(task)
      return task.description:find("#t", 1, true) ~= nil
    end,
  })
  local m = by_line(ns)
  eq(m[1], nil) -- root vetoed + dropped
  eq(m[2].kind, "task")
  eq(m[2].parent_line, nil) -- no kept ancestor → top-level
  eq(m[2].depth, 0)
end

-- ── tasks() projection ──────────────────────────────────────────────────────

T["tasks(): returns only task nodes in line order"] = function()
  local ns = parse(table.concat({
    "- [ ] one",
    "  - desc",
    "",
    "- [ ] two",
  }, "\n"))
  local ts = nodes.tasks(ns)
  eq(#ts, 2)
  eq(ts[1].task.description, "one")
  eq(ts[2].task.description, "two")
end

-- ── discovery-vs-parse prefix equivalence ───────────────────────────────────
-- The rg DISCOVERY_PATTERN in index/scan.lua decides WHICH files get full-read.
-- It must accept every prefix the parser (task/parse.lua) treats as a task,
-- otherwise a file whose only task is e.g. `- [ ]nospace` is never indexed.
-- task/parse.lua's PREFIX_PAT makes the space after `]` OPTIONAL.  These tests
-- pin that the node parser classifies a no-space checkbox as a task AND that a
-- Lua transcription of DISCOVERY_PATTERN matches it, so future drift is caught.

T["parse: a checkbox with NO space after ] is still a task (parser side)"] = function()
  local ns = parse("- [ ]nospace")
  local m = by_line(ns)
  eq(m[1].kind, "task")
  eq(m[1].task.status_symbol, " ")
  eq(m[1].task.description, "nospace")
end

T["discovery pattern matches whatever the parser accepts (no-space prefix)"] = function()
  -- Lua transcription of index/scan.lua's DISCOVERY_PATTERN
  -- ("^\\s*[-*+] \\[.\\]"): no mandatory trailing space after `]`.
  local DISCOVERY_LUA = "^%s*[-*+] %[.%]"
  -- Lines the parser treats as tasks must also match discovery.
  for _, line in ipairs({
    "- [ ] spaced",
    "- [ ]nospace",
    "  - [x]done",
    "* [ ]star",
    "+ [-]plus",
  }) do
    eq(parse(line)[1].kind, "task")
    eq(line:match(DISCOVERY_LUA) ~= nil, true)
  end
end

-- ── parse_file: disk read + size guard ──────────────────────────────────────

T["parse_file: reads a real file into nodes"] = function()
  local path = vim.fn.tempname() .. ".md"
  local f = assert(io.open(path, "w"))
  f:write("# H\n- [ ] task\n  - bullet\n")
  f:close()

  local ns = nodes.parse_file(path)
  os.remove(path)

  local m = by_line(ns)
  eq(m[2].kind, "task")
  eq(m[2].heading, "H")
  eq(m[3].kind, "bullet")
  eq(m[3].parent_line, 2)
end

T["parse_file: oversize files return an empty list (size guard)"] = function()
  local path = vim.fn.tempname() .. ".md"
  local f = assert(io.open(path, "w"))
  f:write("- [ ] a task line longer than the byte budget\n")
  f:close()

  local ns = nodes.parse_file(path, { max_bytes = 5 })
  os.remove(path)
  eq(#ns, 0)
end

T["parse_file: missing file returns an empty list"] = function()
  local ns = nodes.parse_file("/no/such/file/nowhere.md")
  eq(#ns, 0)
end

return T
