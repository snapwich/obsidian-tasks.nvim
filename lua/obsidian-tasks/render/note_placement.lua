-- lua/obsidian-tasks/render/note_placement.lua
-- Where a group-top insert goes inside its target note (plan D4, ADR 0005).
--
-- The target note is today's daily note, or the file of a filename group.  The
-- heading group decides the section:
--   • Heading exists → the LAST heading with that text (any level).  The
--     section runs to the next heading of ANY level: the index gives a task the
--     nearest ATX heading above it, so a task under a `###` subheading joins
--     the subheading's group, not ours.
--       – section has list items → after the last top-level item, its subtree
--         and its continuation (util/list_block rule);
--       – no list items → after the heading line, with one blank between.
--     Trailing prose and blank lines are not moved.
--   • Heading missing → end of file: a blank, the heading, the task.
--   • "(No heading)" (heading == nil) → the region between the frontmatter and
--     the first heading: after its last list item, else directly before the
--     first heading.  No headings → end of file.
--
-- PURE: works on the note's lines (readfile form, no trailing-newline element),
-- no IO.  The caller writes the result as one count=0 apply_source_edit.

local M = {}

local heading_mod = require("obsidian-tasks.index.heading")
local list_block = require("obsidian-tasks.util.list_block")

--- 0-indexed row after the frontmatter (0 when there is none).  Same fence rule
--- as util/obsidian.parse_frontmatter_lines, except that an unclosed fence is
--- not frontmatter.
--- @param lines string[]
--- @return integer
local function body_start(lines)
  if lines[1] ~= "---" then
    return 0
  end
  for i = 2, #lines do
    if lines[i] == "---" then
      return i
    end
  end
  return 0
end

--- 0-indexed row of the first heading at or after *from*, before *to*.
--- @return integer|nil
local function next_heading(lines, from, to)
  for row = from, to - 1 do
    if heading_mod.parse(lines[row + 1]) ~= nil then
      return row
    end
  end
  return nil
end

--- Insert row after the last top-level list item of the section [from, to), or
--- nil when the section has no list items.  The node parser gives the depth
--- (the slice has no headings, so depth 0 == top-level).
--- @return integer|nil
local function after_last_item(lines, from, to)
  if to <= from then
    return nil
  end
  local slice = {}
  for row = from, to - 1 do
    slice[#slice + 1] = lines[row + 1]
  end
  local last_root = nil
  for _, n in ipairs(require("obsidian-tasks.index.nodes").parse_lines(slice)) do
    if n.kind ~= "blank" and n.depth == 0 then
      last_root = from + n.line_num - 1
    end
  end
  if last_root == nil then
    return nil
  end
  local row = list_block.continuation_end(lines, last_root, list_block.indent_of(lines[last_root + 1]))
  return math.min(row, to)
end

--- Concatenate string arrays.
local function concat(...)
  local out = {}
  for _, t in ipairs({ ... }) do
    for _, l in ipairs(t) do
      out[#out + 1] = l
    end
  end
  return out
end

--- True when 0-indexed *row* exists and is not blank.
local function non_blank_at(lines, row)
  local l = lines[row + 1]
  return l ~= nil and not list_block.is_blank(l)
end

--- Compute the placement of *new_lines* in a note.
---
--- @param lines     string[]       the note's lines
--- @param heading   string|nil     target heading text; nil = "(No heading)"
--- @param level     integer|nil    level for a heading we must create (default 2)
--- @param new_lines string[]       the task line(s) to write, in order
--- @return { row: integer, lines_to_insert: string[], created_heading: boolean }
---   insert lines_to_insert before 0-indexed *row* (count = 0)
function M.place(lines, heading, level, new_lines)
  local n = #lines

  -- ── (No heading) ──────────────────────────────────────────────────────────
  if heading == nil then
    local from = body_start(lines)
    local first_h = next_heading(lines, from, n)
    local to = first_h or n
    local row = after_last_item(lines, from, to)
    if row ~= nil then
      return { row = row, lines_to_insert = concat(new_lines), created_heading = false }
    end
    -- No list items in the region: directly before the first heading, or at
    -- end of file.  Keep a blank between the task and prose / the heading.
    local before = (to > from and non_blank_at(lines, to - 1)) and { "" } or {}
    local after = first_h and { "" } or {}
    return { row = to, lines_to_insert = concat(before, new_lines, after), created_heading = false }
  end

  -- ── heading exists: the LAST heading with that text ───────────────────────
  local h_row = nil
  for row = 0, n - 1 do
    if heading_mod.parse(lines[row + 1]) == heading then
      h_row = row
    end
  end

  if h_row ~= nil then
    local from = h_row + 1
    local to = next_heading(lines, from, n) or n
    local row = after_last_item(lines, from, to)
    if row ~= nil then
      return { row = row, lines_to_insert = concat(new_lines), created_heading = false }
    end
    -- No list items: after the heading with one blank between; a blank after
    -- the task too when the next line is prose or a heading.
    local after = non_blank_at(lines, from) and { "" } or {}
    return { row = from, lines_to_insert = concat({ "" }, new_lines, after), created_heading = false }
  end

  -- ── heading missing: append blank + heading + task ────────────────────────
  local before = non_blank_at(lines, n - 1) and { "" } or {}
  local heading_line = string.rep("#", level or 2) .. " " .. heading
  return { row = n, lines_to_insert = concat(before, { heading_line }, new_lines), created_heading = true }
end

return M
