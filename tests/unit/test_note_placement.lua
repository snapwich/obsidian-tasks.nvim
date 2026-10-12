-- tests/unit/test_note_placement.lua
-- Plan D4 (group-top insert, step 2b): where a group-top insert goes inside
-- its target note (the daily note, or the file of a filename group).
--
-- note_placement.place(lines, heading, level, new_lines) is pure.  *lines* are
-- the note's lines (readfile form: no trailing-newline element), *heading* the
-- target heading text (nil = "(No heading)"), *level* the level for a heading
-- that must be created (nil = 2), *new_lines* the task line(s) to write.  It
-- returns { row, lines_to_insert, created_heading }: a pure insert of
-- lines_to_insert BEFORE 0-indexed *row*.
--
-- The property test at the end re-indexes the result with index/nodes.lua and
-- asserts the inserted task's heading equals the target heading — the "task
-- shows in the group where the user typed it" invariant for heading groups.

local T = MiniTest.new_set()

local placement = require("obsidian-tasks.render.note_placement")
local nodes_mod = require("obsidian-tasks.index.nodes")

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

local NEW = "- [ ] NEWTASK"

--- Splice result *r* into *lines* and return the new line list.
local function apply(lines, r)
  local out = {}
  for i = 1, r.row do
    out[#out + 1] = lines[i]
  end
  for _, l in ipairs(r.lines_to_insert) do
    out[#out + 1] = l
  end
  for i = r.row + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

local function place(lines, heading, level)
  local r = placement.place(lines, heading, level, { NEW })
  return r, apply(lines, r)
end

-- ── heading exists ──────────────────────────────────────────────────────────

T["placement: heading with list items → after the last item"] = function()
  local lines = { "# Day", "", "## Work", "- [ ] a", "- [ ] b", "", "## Home", "- [ ] c" }
  local r, out = place(lines, "Work")
  eq(r.created_heading, false)
  eq(r.row, 5)
  eq(out, { "# Day", "", "## Work", "- [ ] a", "- [ ] b", NEW, "", "## Home", "- [ ] c" })
end

T["placement: last item's subtree and continuation stay with it"] = function()
  local lines = {
    "## Work",
    "- [ ] a",
    "- [ ] b",
    "  - [ ] child",
    "    more child text",
    "",
    "  child para after blank",
    "trailing prose",
    "## Home",
  }
  local _, out = place(lines, "Work")
  eq(out, {
    "## Work",
    "- [ ] a",
    "- [ ] b",
    "  - [ ] child",
    "    more child text",
    "",
    "  child para after blank",
    NEW,
    "trailing prose",
    "## Home",
  })
end

T["placement: a nested last line does not split the root's continuation"] = function()
  -- The last LIST line is the child, but the root's continuation (indent 2)
  -- follows it: the new task goes after the whole root block.
  local lines = { "## Work", "- [ ] a", "    - [ ] child", "  more of a", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", "    - [ ] child", "  more of a", NEW, "## Home" })
end

T["placement: trailing blank lines and prose are not moved"] = function()
  local lines = { "## Work", "- [ ] a", "", "Some prose.", "", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW, "", "Some prose.", "", "## Home" })
end

T["placement: list items after prose in the section → after the last one"] = function()
  local lines = { "## Work", "- [ ] a", "", "prose", "", "- [ ] b", "", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", "", "prose", "", "- [ ] b", NEW, "", "## Home" })
end

T["placement: heading without list items → after the heading, one blank between"] = function()
  local lines = { "## Work", "## Home", "- [ ] c" }
  local r, out = place(lines, "Work")
  eq(r.row, 1)
  eq(r.created_heading, false)
  eq(out, { "## Work", "", NEW, "", "## Home", "- [ ] c" })
end

T["placement: heading without list items, existing blank after it"] = function()
  local lines = { "## Work", "", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "", NEW, "", "## Home" })
end

T["placement: heading without list items keeps its prose below the task"] = function()
  local lines = { "## Work", "Some prose." }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "", NEW, "", "Some prose." })
end

T["placement: heading at end of file"] = function()
  local lines = { "# Day", "## Work" }
  local r, out = place(lines, "Work")
  eq(r.row, 2)
  eq(out, { "# Day", "## Work", "", NEW })
end

T["placement: the section ends at a SUBheading (any level)"] = function()
  -- A task under `### Sub` belongs to Sub's group, so the insert for Work
  -- must stay above `### Sub` even though Sub is a deeper level.
  local lines = { "## Work", "- [ ] a", "### Sub", "- [ ] s" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW, "### Sub", "- [ ] s" })
end

T["placement: heading with only a subheading below → before the subheading"] = function()
  local lines = { "## Work", "### Sub", "- [ ] s" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "", NEW, "", "### Sub", "- [ ] s" })
end

T["placement: duplicate headings → the LAST one wins (any level)"] = function()
  local lines = { "## Work", "- [ ] a", "# Other", "### Work", "- [ ] b", "## End" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", "# Other", "### Work", "- [ ] b", NEW, "## End" })
end

T["placement: heading text match ignores the ATX closing sequence"] = function()
  local lines = { "## Work ##", "- [ ] a" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work ##", "- [ ] a", NEW })
end

T["placement: multi-line new_lines are inserted as one block"] = function()
  local lines = { "## Work", "- [ ] a", "## Home" }
  local r = placement.place(lines, "Work", nil, { "- [ ] x", "  - [ ] y" })
  eq(r.row, 2)
  eq(r.lines_to_insert, { "- [ ] x", "  - [ ] y" })
end

-- ── heading missing ─────────────────────────────────────────────────────────

T["placement: missing heading → blank + heading + task at end of file"] = function()
  local lines = { "# Day", "- [ ] a" }
  local r, out = place(lines, "Work", 3)
  eq(r.created_heading, true)
  eq(r.row, 2)
  eq(out, { "# Day", "- [ ] a", "", "### Work", NEW })
end

T["placement: missing heading, level nil → ## fallback"] = function()
  local _, out = place({ "text" }, "Work")
  eq(out, { "text", "", "## Work", NEW })
end

T["placement: missing heading after a trailing blank → no second blank"] = function()
  local _, out = place({ "text", "" }, "Work")
  eq(out, { "text", "", "## Work", NEW })
end

T["placement: missing heading, empty file → heading + task only"] = function()
  local r, out = place({}, "Work", 2)
  eq(r.row, 0)
  eq(r.created_heading, true)
  eq(out, { "## Work", NEW })
end

-- ── (No heading) ────────────────────────────────────────────────────────────

T["placement: (No heading) → before the first heading"] = function()
  local lines = { "Intro text.", "", "## Work", "- [ ] a" }
  local r, out = place(lines, nil)
  eq(r.created_heading, false)
  eq(out, { "Intro text.", "", NEW, "", "## Work", "- [ ] a" })
end

T["placement: (No heading) after frontmatter, heading right after it"] = function()
  local lines = { "---", "tags:", "  - daily", "---", "## Work" }
  local _, out = place(lines, nil)
  eq(out, { "---", "tags:", "  - daily", "---", NEW, "", "## Work" })
end

T["placement: (No heading) with preamble list items → after the last one"] = function()
  local lines = { "---", "a: 1", "---", "- [ ] p", "  - [ ] q", "", "## Work" }
  local _, out = place(lines, nil)
  eq(out, { "---", "a: 1", "---", "- [ ] p", "  - [ ] q", NEW, "", "## Work" })
end

T["placement: (No heading), preamble prose right above the heading"] = function()
  local lines = { "Created today", "## Work" }
  local _, out = place(lines, nil)
  eq(out, { "Created today", "", NEW, "", "## Work" })
end

T["placement: (No heading), file starts with a heading → row 0"] = function()
  local r, out = place({ "# Day" }, nil)
  eq(r.row, 0)
  eq(out, { NEW, "", "# Day" })
end

T["placement: (No heading), no headings → end of file"] = function()
  local _, out = place({ "Some text" }, nil)
  eq(out, { "Some text", "", NEW })
end

T["placement: (No heading), no headings, list items → after the last item"] = function()
  local _, out = place({ "- [ ] a", "", "prose" }, nil)
  eq(out, { "- [ ] a", NEW, "", "prose" })
end

T["placement: (No heading), frontmatter only → right after it"] = function()
  local _, out = place({ "---", "a: 1", "---" }, nil)
  eq(out, { "---", "a: 1", "---", NEW })
end

T["placement: (No heading), YAML list items in frontmatter are not list items"] = function()
  local lines = { "---", "tags:", "  - x", "---", "# Day" }
  local _, out = place(lines, nil)
  eq(out, { "---", "tags:", "  - x", "---", NEW, "", "# Day" })
end

T["placement: (No heading), empty file"] = function()
  local r, out = place({}, nil)
  eq(r.row, 0)
  eq(out, { NEW })
end

-- ── code fences and frontmatter ─────────────────────────────────────────────
-- A `# ...` line inside a fenced code block (a ```tasks query block's comment
-- lines, a shell snippet) or inside the frontmatter is not a heading, and a
-- list item inside a fence is not a list item.  Placement must agree with the
-- indexer (index/nodes.lua), so the task shows in the group where it was typed.

T["placement: (No heading) never goes inside a ```tasks query block (review probe)"] = function()
  local lines = { "```tasks", "# due this week", "not done", "```", "", "## log", "text" }
  local _, out = place(lines, nil)
  eq(out, { "```tasks", "# due this week", "not done", "```", "", NEW, "", "## log", "text" })
end

T["placement: (No heading), a fence with a # line and no real heading → end of file"] = function()
  local lines = { "```tasks", "# comment", "```" }
  local _, out = place(lines, nil)
  eq(out, { "```tasks", "# comment", "```", "", NEW })
end

T["placement: a fenced # line BEFORE the section is not the target heading"] = function()
  local lines = { "## Work", "- [ ] a", "## Home", "```", "# Work", "```" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW, "## Home", "```", "# Work", "```" })
end

T["placement: a fenced # line is not a heading that can be matched"] = function()
  local lines = { "## Home", "```", "# Work", "```" }
  local r, out = place(lines, "Work")
  eq(r.created_heading, true)
  eq(out, { "## Home", "```", "# Work", "```", "", "## Work", NEW })
end

T["placement: a fenced # line INSIDE the section does not end it"] = function()
  local lines = { "## Work", "- [ ] a", "```sh", "# a shell comment", "- [ ] fake", "```", "- [ ] b", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", "```sh", "# a shell comment", "- [ ] fake", "```", "- [ ] b", NEW, "## Home" })
end

T["placement: list items inside a fence AFTER the last item are not items"] = function()
  local lines = { "## Work", "- [ ] a", "", "```", "- [ ] fake", "```", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW, "", "```", "- [ ] fake", "```", "## Home" })
end

T["placement: a section with only a fence has no list items"] = function()
  local lines = { "## Work", "~~~", "- [ ] fake", "# x", "~~~", "## Home" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "", NEW, "", "~~~", "- [ ] fake", "# x", "~~~", "## Home" })
end

T["placement: an unclosed fence — nothing goes inside it"] = function()
  local lines = { "## Work", "- [ ] a", "```", "# x", "- [ ] fake" }
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW, "```", "# x", "- [ ] fake" })
  -- A missing heading goes before the unclosed fence, not at the end of file.
  local r2, out2 = place(lines, "Home")
  eq(r2.created_heading, true)
  eq(out2, { "## Work", "- [ ] a", "", "## Home", NEW, "", "```", "# x", "- [ ] fake" })
  -- (No heading) with no real heading: before the unclosed fence.
  local _, out3 = place({ "text", "```", "# x" }, nil)
  eq(out3, { "text", "", NEW, "", "```", "# x" })
end

T["placement: (No heading), a # comment in the frontmatter is not a heading"] = function()
  local lines = { "---", "# a yaml comment", "a: 1", "---", "## Work" }
  local _, out = place(lines, nil)
  eq(out, { "---", "# a yaml comment", "a: 1", "---", NEW, "", "## Work" })
  local r2, out2 = place(lines, "a yaml comment")
  eq(r2.created_heading, true)
  eq(out2, { "---", "# a yaml comment", "a: 1", "---", "## Work", "", "## a yaml comment", NEW })
end

T["append: never inside an unclosed fence"] = function()
  local lines = { "# Day", "- [ ] a", "```", "code" }
  local r = placement.append(lines, { NEW })
  eq(apply(lines, r), { "# Day", "- [ ] a", NEW, "", "```", "code" })
end

T["append: a list item inside a closed fence at the end is not a list"] = function()
  local lines = { "```", "- [ ] fake", "```" }
  local r = placement.append(lines, { NEW })
  eq(apply(lines, r), { "```", "- [ ] fake", "```", "", NEW })
end

-- ── trailing newline ────────────────────────────────────────────────────────

T["placement: file without a trailing newline"] = function()
  -- "## Work\n- [ ] a" (no final \n) → readfile gives the same lines as with
  -- one; a split of the raw text gives no trailing "" element either.
  local lines = vim.split("## Work\n- [ ] a", "\n")
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW })
end

T["placement: raw split WITH a trailing newline keeps the final empty element last"] = function()
  local lines = vim.split("## Work\n- [ ] a\n", "\n")
  local _, out = place(lines, "Work")
  eq(out, { "## Work", "- [ ] a", NEW, "" })
  local _, out2 = place(lines, "Home")
  eq(out2, { "## Work", "- [ ] a", "", "## Home", NEW })
end

-- ── property test ───────────────────────────────────────────────────────────
-- Deterministic variety by loop index (no math.random): each seed picks
-- frontmatter / preamble / sections / headings levels / list shapes / prose.

local LIST_SHAPES = {
  {},
  { "- [ ] t1" },
  { "- [ ] t1", "- [x] t2" },
  { "- [ ] t1", "  - [ ] c1", "    more c1" },
  { "- [ ] t1", "", "  continuation para" },
  { "* bullet", "  - [ ] under bullet" },
  { "  - [ ] indented root", "    - [ ] deeper" },
  { "- [ ] t1", "", "", "- [ ] t2" },
}
local PROSE = { {}, { "Some prose." }, { "", "Prose after blank.", "" }, { "" } }
local NAMES = { "Work", "Home", "Ideas", "Work", "Sub" }
-- Fenced blocks whose lines look like headings / list items (they are not).
local FENCES = {
  {},
  { "```tasks", "# Work", "not done", "```" },
  { "~~~", "## Home", "- [ ] fenced task", "~~~" },
  { "```sh", "# Sub", "```" },
  { "````md", "```", "# Ideas", "- [ ] x", "````" },
}

--- Build a note from seed *s*.  Returns lines and the list of heading texts.
local function gen_note(s)
  local lines, heads = {}, {}
  local function push_all(t)
    for _, l in ipairs(t) do
      lines[#lines + 1] = l
    end
  end
  if s % 3 == 0 then
    push_all({ "---", "tags:", "  - daily", "---" })
  end
  if s % 4 == 1 then
    push_all({ "Preamble line" })
  end
  if s % 5 == 2 then
    push_all({ "- [ ] preamble task" })
  end
  if s % 6 == 1 then
    push_all({ "```tasks", "# due this week", "not done", "```" })
  end
  local nsec = s % 4
  for k = 1, nsec do
    local name = NAMES[((s + k) % #NAMES) + 1]
    local level = ((s + k) % 3) + 1
    lines[#lines + 1] = string.rep("#", level) .. " " .. name
    heads[#heads + 1] = name
    push_all(PROSE[((s * 7 + k) % #PROSE) + 1])
    push_all(FENCES[((s + k * 3) % #FENCES) + 1])
    push_all(LIST_SHAPES[((s * 3 + k) % #LIST_SHAPES) + 1])
    push_all(FENCES[((s * 5 + k) % #FENCES) + 1])
    push_all(PROSE[((s + k * 5) % #PROSE) + 1])
  end
  if s % 11 == 4 then
    -- An unclosed fence ends the note.
    push_all({ "```", "# Work", "- [ ] in the open fence" })
  end
  return lines, heads
end

--- The heading of the task whose text contains NEWTASK, after a re-index.
local function inserted_heading(out)
  local found, heading = 0, "<missing>"
  for _, n in ipairs(nodes_mod.parse_lines(out)) do
    if n.kind == "task" and n.task.description:find("NEWTASK", 1, true) then
      found = found + 1
      heading = n.heading
    end
  end
  return found, heading
end

--- Every original line must survive, in order (we only insert).
local function is_superset_in_order(orig, out)
  local j = 1
  for _, l in ipairs(out) do
    if j <= #orig and orig[j] == l then
      j = j + 1
    end
  end
  return j == #orig + 1
end

--- The NEWTASK node after re-indexing *lines*, or nil.
local function new_task_node(lines)
  for _, n in ipairs(nodes_mod.parse_lines(lines)) do
    if n.kind == "task" and n.task.description:find("NEWTASK", 1, true) then
      return n
    end
  end
  return nil
end

T["placement: an indented fence under the last item with a column-0 line inside → after the fence"] = function()
  local cases = {
    { "## log", "- [ ] a", "  ```", "code at col 0", "  ```", "## next", "x" },
    { "## log", "- [ ] a", "", "  ```", "", "z", "  ```", "## next" },
  }
  for _, lines in ipairs(cases) do
    local out = apply(lines, placement.place(lines, "log", nil, { NEW }))
    local n = new_task_node(out)
    eq(n ~= nil, true, "NEWTASK is indexed (not inside the fence): " .. vim.inspect(out))
    eq(n.task.heading, "log")
  end
  local lines = { "- [ ] a", "  ```", "code at col 0", "  ```", "", "# h" }
  local out = apply(lines, placement.place(lines, nil, nil, { NEW }))
  eq(new_task_node(out) ~= nil, true, "(No heading): NEWTASK is indexed: " .. vim.inspect(out))
end

T["placement: property — re-indexed task heading equals the target"] = function()
  local checked = 0
  for s = 0, 239 do
    local lines, heads = gen_note(s)
    local targets = { false, "Missing" }
    for _, h in ipairs(heads) do
      targets[#targets + 1] = h
    end
    for _, target in ipairs(targets) do
      local heading = target or nil
      local r = placement.place(lines, heading, (s % 6) + 1, { NEW })
      local out = apply(lines, r)
      local found, got = inserted_heading(out)
      local ctx = ("seed %d target %s\n%s"):format(s, tostring(heading), table.concat(out, "\n"))
      eq(found, 1, "exactly one NEWTASK: " .. ctx)
      eq(got, heading, "heading: " .. ctx)
      eq(is_superset_in_order(lines, out), true, "original lines kept: " .. ctx)
      eq(#out, #lines + #r.lines_to_insert, "pure insert: " .. ctx)
      eq(r.created_heading, heading == "Missing", "created_heading: " .. ctx)
      checked = checked + 1
    end
  end
  eq(checked > 500, true)
end

-- ── end of file (plan D3: tags / priority / status, filename, ungrouped) ─────

T["append: empty file → the task alone"] = function()
  local r = placement.append({}, { NEW })
  eq(r.row, 0)
  eq(r.lines_to_insert, { NEW })
  eq(r.created_heading, false)
end

T["append: last line is a list item → directly after it"] = function()
  local lines = { "# Day", "", "- [ ] a" }
  local r = placement.append(lines, { NEW })
  eq(apply(lines, r), { "# Day", "", "- [ ] a", NEW })
end

T["append: last line is prose or a heading → one blank between"] = function()
  local lines = { "# Day", "text" }
  local r = placement.append(lines, { NEW })
  eq(apply(lines, r), { "# Day", "text", "", NEW })
  local lines2 = { "# Day" }
  eq(apply(lines2, placement.append(lines2, { NEW })), { "# Day", "", NEW })
end

T["append: last line is blank → no extra blank"] = function()
  local lines = { "# Day", "" }
  local r = placement.append(lines, { NEW })
  eq(apply(lines, r), { "# Day", "", NEW })
end

return T
