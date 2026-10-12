-- lua/obsidian-tasks/util/md_structure.lua
-- Which lines of a note are markdown structure: the ONE notion of "heading
-- line" and "list item line" that the indexer (index/nodes.lua) and the
-- group-top placement (render/note_placement.lua, render/group_top_write.lua)
-- share.  They must agree: a group-top task shows in the group where the user
-- typed it only when placement sees the same headings as the index.
--
-- Like Obsidian, a line inside the YAML frontmatter or inside a fenced code
-- block is never a heading or a list item.  The common case is a ```tasks
-- query block, whose comment lines start with `#`.
--
--   Frontmatter: line 1 is exactly `---`, up to the next `---` line.  An
--     unclosed block is not frontmatter (same rule as Obsidian).
--   Fence: a line of 3+ backticks or 3+ tildes, at any indent (a fence inside
--     a list item is indented).  A backtick fence's info string has no
--     backtick.  The closing line uses the same character, at least as many,
--     and nothing else.  An unclosed fence runs to the end of the note
--     (CommonMark).
--
-- PURE: works on a line list (readfile form), no IO.  Line indices are
-- 1-indexed (lines[i]).

local M = {}

-- A list item: optional indent, then a `-`/`*`/`+` marker followed by a space.
-- The body capture is everything after the marker and the space.
local LIST_PAT = "^(%s*)([-*+])%s(.*)$"
-- A marker on its own line ("-", "  *") with no body.
local LIST_BARE_PAT = "^(%s*)([-*+])%s*$"

--- Opening fence on *line*: the fence character and the run length, or nil.
--- @param line string
--- @return string|nil char
--- @return integer|nil len
local function fence_open(line)
  local run, info = line:match("^%s*(```+)(.*)$")
  if run and not info:find("`", 1, true) then
    return "`", #run
  end
  run = line:match("^%s*(~~~+)")
  if run then
    return "~", #run
  end
  return nil, nil
end

--- True when *line* closes a fence of *char* × *len*.
local function fence_close(line, char, len)
  local run = line:match("^%s*([`~]+)%s*$")
  return run ~= nil and #run >= len and run == string.rep(char, #run)
end

--- Scan *lines* once.
---
--- Result:
---   code[i]     true when line i is in the frontmatter or in a fenced code
---               block (the fence lines included)
---   body_start  number of frontmatter lines (0 when there is none): the
---               0-indexed row of the first body line
---   open_fence  1-indexed line of an unclosed opening fence, or nil
---   heading(i)  heading text of line i, or nil (never for a code line)
---   list_item(i) indent, marker, body of a list item on line i, or nil
---               (never for a code line)
---
--- @param lines string[]
--- @param opts  table|nil  { heading = parser with .parse(line) } (tests)
--- @return table
function M.scan(lines, opts)
  local heading_mod = (opts and opts.heading) or require("obsidian-tasks.index.heading")
  local code = {}
  local n = #lines
  local function text(i)
    return (lines[i]:gsub("\r$", ""))
  end

  local body_start = 0
  if n > 0 and text(1) == "---" then
    for i = 2, n do
      if text(i) == "---" then
        for k = 1, i do
          code[k] = true
        end
        body_start = i
        break
      end
    end
  end

  local open_fence = nil
  local char, len = nil, nil
  for i = body_start + 1, n do
    local line = text(i)
    if char then
      code[i] = true
      if fence_close(line, char, len) then
        char, len, open_fence = nil, nil, nil
      end
    else
      char, len = fence_open(line)
      if char then
        code[i] = true
        open_fence = i
      end
    end
  end

  local s = { code = code, body_start = body_start, open_fence = open_fence }

  function s.heading(i)
    if code[i] or lines[i] == nil then
      return nil
    end
    return heading_mod.parse(text(i))
  end

  function s.list_item(i)
    if code[i] or lines[i] == nil then
      return nil
    end
    local line = text(i)
    local ws, marker, body = line:match(LIST_PAT)
    if ws == nil then
      ws, marker = line:match(LIST_BARE_PAT)
      body = ws and "" or nil
    end
    if ws == nil then
      return nil
    end
    return ws, marker, body
  end

  return s
end

return M
