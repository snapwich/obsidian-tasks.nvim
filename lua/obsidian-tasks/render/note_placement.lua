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
-- M.append is the end-of-file rule for targets with no heading level (tags /
-- priority / status groups, a filename group, an ungrouped or zero-result
-- dashboard): directly after a last list item, else after one blank line.
--
-- Headings and list items come from util/md_structure.lua, the scan the
-- indexer uses too: a `# ...` line inside a fenced code block (a ```tasks query
-- block's comment lines) or inside the frontmatter is not a heading, and a list
-- item inside a fence is not a list item.  Nothing goes inside an unclosed
-- fence: it runs to the end of the note, so the note "ends" at its opening line
-- for every end-of-file rule, with a blank line between the task and it.
--
-- PURE: works on the note's lines (readfile form, no trailing-newline element),
-- no IO.  The caller writes the result as one count=0 apply_source_edit.

local M = {}

local list_block = require("obsidian-tasks.util.list_block")
local md_structure = require("obsidian-tasks.util.md_structure")

--- 0-indexed row of the first heading at or after *from*, before *to*.
--- @return integer|nil
local function next_heading(st, from, to)
  for row = from, to - 1 do
    if st.heading(row + 1) ~= nil then
      return row
    end
  end
  return nil
end

--- Insert row after the last top-level list item of the section [from, to), or
--- nil when the section has no list items.  The node parser runs on the whole
--- note (so fences and frontmatter are seen in context) and gives the depth; a
--- heading flushes its indent stack, so depth 0 == top-level in the section.
--- The continuation walk goes by indent only, so it can stop on a shallow line
--- INSIDE a fence that opens under the item; step past the rest of that fence.
--- @return integer|nil
local function after_last_item(st, lines, from, to)
  if to <= from then
    return nil
  end
  local last_root = nil
  for _, n in ipairs(require("obsidian-tasks.index.nodes").parse_lines(lines)) do
    local row = n.line_num - 1
    if n.kind ~= "blank" and n.depth == 0 and row >= from and row < to then
      last_root = row
    end
  end
  if last_root == nil then
    return nil
  end
  local row = list_block.continuation_end(lines, last_root, list_block.indent_of(lines[last_root + 1]))
  while row < to and st.code[row + 1] and st.code[row] do
    row = row + 1
  end
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
  local st = md_structure.scan(lines)
  -- End of the note for placement: the opening line of an unclosed fence.
  local n = st.open_fence and (st.open_fence - 1) or #lines
  local tail = st.open_fence and { "" } or {}

  -- ── (No heading) ──────────────────────────────────────────────────────────
  if heading == nil then
    local from = st.body_start
    local first_h = next_heading(st, from, n)
    local to = first_h or n
    local row = after_last_item(st, lines, from, to)
    if row ~= nil then
      return { row = row, lines_to_insert = concat(new_lines), created_heading = false }
    end
    -- No list items in the region: directly before the first heading, or at
    -- end of file.  Keep a blank between the task and prose / the heading.
    local before = (to > from and non_blank_at(lines, to - 1)) and { "" } or {}
    local after = first_h and { "" } or tail
    return { row = to, lines_to_insert = concat(before, new_lines, after), created_heading = false }
  end

  -- ── heading exists: the LAST heading with that text ───────────────────────
  local h_row = nil
  for row = 0, n - 1 do
    if st.heading(row + 1) == heading then
      h_row = row
    end
  end

  if h_row ~= nil then
    local from = h_row + 1
    local to = next_heading(st, from, n) or n
    local row = after_last_item(st, lines, from, to)
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
  return { row = n, lines_to_insert = concat(before, { heading_line }, new_lines, tail), created_heading = true }
end

--- Compute an end-of-file placement of *new_lines* in a note.
---
--- The task joins a list that ends the file; after prose or a heading it gets
--- one blank line between.  A blank last line (or an empty file) needs none.
--- An unclosed fence is never entered: the task goes before it.
---
--- @param lines     string[]  the note's lines
--- @param new_lines string[]  the task line(s) to write, in order
--- @return { row: integer, lines_to_insert: string[], created_heading: boolean }
function M.append(lines, new_lines)
  local st = md_structure.scan(lines)
  local n = st.open_fence and (st.open_fence - 1) or #lines
  local tail = st.open_fence and { "" } or {}
  local last = lines[n]
  local before = (last ~= nil and not list_block.is_blank(last) and st.list_item(n) == nil) and { "" } or {}
  return { row = n, lines_to_insert = concat(before, new_lines, tail), created_heading = false }
end

return M
