-- tests/unit/test_md_structure.lua
-- util/md_structure.lua: the one fence/frontmatter-aware notion of "heading
-- line" and "list item line" that the indexer (index/nodes.lua) and the
-- group-top placement (render/note_placement.lua) share.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality
local md = require("obsidian-tasks.util.md_structure")

T["frontmatter: body_start and code lines; # comment is not a heading"] = function()
  local st = md.scan({ "---", "# c", "  - x", "---", "# Real", "- item" })
  eq(st.body_start, 4)
  eq({ st.code[1], st.code[2], st.code[3], st.code[4], st.code[5] }, { true, true, true, true, nil })
  eq(st.heading(2), nil)
  eq(st.list_item(3), nil)
  eq(st.heading(5), "Real")
  eq(select(2, st.list_item(6)), "-")
end

T["frontmatter: unclosed --- is not frontmatter"] = function()
  local st = md.scan({ "---", "# Real" })
  eq(st.body_start, 0)
  eq(st.heading(2), "Real")
end

T["fence: ``` and ~~~ hide headings and list items, fence lines included"] = function()
  local st = md.scan({ "```tasks", "# c", "```", "~~~", "- [ ] x", "~~~", "# Real" })
  for i = 1, 6 do
    eq(st.code[i], true)
  end
  eq(st.heading(2), nil)
  eq(st.list_item(5), nil)
  eq(st.heading(7), "Real")
  eq(st.open_fence, nil)
end

T["fence: closer needs the same char and at least the opener's length"] = function()
  local st = md.scan({ "````", "```", "~~~~", "````", "# Real" })
  eq(st.code[4], true)
  eq(st.heading(5), "Real")
end

T["fence: a backtick run with a backtick in the info string is not a fence"] = function()
  local st = md.scan({ "```inline``` text", "# Real" })
  eq(st.heading(2), "Real")
end

T["fence: an unclosed fence runs to the end; open_fence is its line"] = function()
  local st = md.scan({ "# A", "  ```", "# B" })
  eq(st.open_fence, 2)
  eq(st.heading(3), nil)
end

T["CRLF lines are read like LF lines"] = function()
  local st = md.scan({ "---\r", "a: 1\r", "---\r", "```\r", "# x\r", "```\r", "## Real\r" })
  eq(st.body_start, 3)
  eq(st.heading(5), nil)
  eq(st.heading(7), "Real")
end

return T
