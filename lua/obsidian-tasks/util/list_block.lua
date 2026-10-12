-- lua/obsidian-tasks/util/list_block.lua
-- The continuation rule for a list item in a source note, shared by every
-- source write that must step past an item and its subtree:
-- cmd.insert_after_anchor, cmd.delete_block and render/note_placement.
--
-- PURE: works on a line list (readfile form), no IO.

local M = {}

-- Count leading whitespace characters in a line.
local function indent_of(line)
  local s = line:match("^(%s*)")
  return s and #s or 0
end

-- A line is blank iff it is empty or whitespace-only.
local function is_blank(line)
  return line:match("^%s*$") ~= nil
end

M.indent_of = indent_of
M.is_blank = is_blank

--- First 0-indexed row AFTER the continuation block of the item at *row*.
---
--- Walks forward from row + 1 while the row is a continuation of the item:
---   a. a non-blank line with indent > *indent* is a continuation;
---   b. a blank line whose NEXT non-blank row has indent > *indent* is part of
---      the continuation (and so is that next row);
---   c. any other line ends the block.  A trailing blank that is not followed
---      by an indented row is NOT part of the block.
---
--- @param lines  string[]  the note's lines (1-indexed array)
--- @param row    integer   0-indexed row of the item
--- @param indent integer   leading-whitespace count of the item
--- @return integer  0-indexed row after the block (== #lines at end of file)
function M.continuation_end(lines, row, indent)
  local n = #lines
  -- lines is 1-indexed: lines[i + 1] is the 0-indexed row i.
  local i = row + 1

  while i < n do
    local line = lines[i + 1]

    if is_blank(line) then
      -- Blank line: look at the next non-blank row to decide whether this blank
      -- is part of the continuation (blank-followed-by-indented rule).
      local next_i = i + 1
      while next_i < n and is_blank(lines[next_i + 1]) do
        next_i = next_i + 1
      end
      -- No following non-blank row, or it is not indented deeper: the blank
      -- ends the continuation.
      if next_i >= n or indent_of(lines[next_i + 1]) <= indent then
        break
      end
      i = i + 1
    elseif indent_of(line) <= indent then
      -- Non-blank row at same or shallower indent: not a continuation.
      break
    else
      -- Non-blank row indented deeper: continuation line.
      i = i + 1
    end
  end

  return i
end

return M
