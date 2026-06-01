-- lua/obsidian-tasks/render/insert_classify.lua
-- Phase 5b: single-line free-form INSERT classifier + placement for the
-- show-tree dashboard.
--
-- A freshly-typed line in a `show tree` dashboard is classified along two
-- INDEPENDENT axes (§6 of show_tree_v1.md):
--   • KIND   — what the marker says:
--       a checkbox ("- [ ]" / "* [ ]" / …) OR bare/ambiguous text (no list
--       marker) ⇒ TASK (repaired into a well-formed "- [ ] …" task);
--       an explicit list bullet "-" / "*" / "+" with NO checkbox ⇒ DESCRIPTION
--       (kept a bullet, marker preserved, NEVER forced into a checkbox).
--   • DEPTH  — the leading whitespace, mapped to a visual level via the
--       2-space-per-level dashboard convention.
--
-- Placement rules (§7, induced-forest model — Phase 2):
--   • DEPTH is LITERAL: the typed line's dashboard indentation maps to a level
--     (2 spaces per level, a tab = 1 level), clamped to at most one level deeper
--     than the line immediately above it (no level-skipping) → typed_depth is
--     clamped to (anchor_depth + 1).
--   • Parent = the nearest managed row above at depth (clamped-1).  A col-0 line
--     (depth 0) has NO parent and becomes a TRUE TOP-LEVEL item.  This holds for
--     BOTH kinds — the OLD col-0 description promotion-to-nearest-top-task rule is
--     GONE: depth is depth.  A user pressing `o` after a lit row inherits that
--     row's indent (autoindent), so the new line attaches as a sibling/child of
--     that row; a genuinely outdented col-0 line becomes a real top-level item.
--   • KIND is independent: a checkbox / bare text ⇒ TASK; a "-"/"*"/"+" bullet
--     with NO checkbox ⇒ DESCRIPTION (marker preserved, never forced to checkbox).
--
-- rows_above includes DIM ANCESTOR breadcrumb rows at their TRUE absolute depths
-- (Phase 1): a dim row is a perfectly valid anchor/parent at its real depth.  The
-- classifier does NOT special-case dim vs lit — depth is depth, and the caller
-- reads the dim row's real source meta for the write.
--
-- The classifier is PURE: it takes the typed line plus a small description of
-- the managed rows above the insert (their depth + kind) and returns a resolved
-- { kind, depth, marker?, body } record.  The caller (render/edit.lua) translates
-- the resolved depth into a source indent relative to the resolved parent's
-- source indent and writes the line.

local M = {}

--- Classify the typed marker of *line* (after leading whitespace).
--- @param line string  the raw typed dashboard line
--- @return string kind   "task" | "description"
--- @return string|nil marker  the bullet marker ("-"/"*"/"+") for a description, nil for a task
--- @return string body   the content after the marker (+ one space) for a description,
---                        or the whole trimmed line for a task
function M.classify_kind(line)
  local body = line:gsub("^%s*", "")
  -- A checkbox anywhere after an optional list marker ⇒ TASK (it IS a task).
  -- Match "<marker> [x]" or a bare "[x]" form.
  local has_checkbox = body:match("^[-*+]%s+%[.%]") ~= nil or body:match("^%[.%]") ~= nil
  if has_checkbox then
    return "task", nil, body
  end
  -- An explicit list bullet WITHOUT a checkbox ⇒ DESCRIPTION; preserve the marker.
  local marker, rest = body:match("^([-*+])%s+(.*)$")
  if marker then
    return "description", marker, rest
  end
  -- A bare bullet with no following space ("-", "*") — treat as a description with
  -- an empty body so the user's marker is preserved.
  marker = body:match("^([-*+])$")
  if marker then
    return "description", marker, ""
  end
  -- Bare / ambiguous text (no list marker) ⇒ TASK (these are task dashboards).
  return "task", nil, body
end

--- Map a leading-whitespace string to a visual depth via the 2-space convention.
--- Rounds down: 0-1 spaces ⇒ 0, 2-3 ⇒ 1, 4-5 ⇒ 2, …
--- @param line string
--- @return integer
function M.typed_depth(line)
  local ws = line:match("^(%s*)") or ""
  -- Tabs count as one level each; spaces are 2-per-level.
  local spaces = 0
  for ch in ws:gmatch(".") do
    if ch == "\t" then
      spaces = spaces + 2
    else
      spaces = spaces + 1
    end
  end
  return math.floor(spaces / 2)
end

--- Resolve KIND + DEPTH + auto-attach for a single typed line inserted into a
--- show-tree dashboard.
---
--- *rows_above* is an array (top-of-buffer → anchor order) of the managed rows
--- strictly above the insert position, each:
---   { depth = <integer>, kind = "task"|"description" }
--- with rows_above[#rows_above] == the immediate anchor (first managed row above
--- the insert).  Read-only BLANK rows must be EXCLUDED by the caller (they have
--- no stable depth/kind for attachment).
---
--- Returns a resolved record:
---   { kind = "task"|"description",
---     marker = <bullet marker or nil>,
---     body = <content after the marker, or the whole task body>,
---     depth = <clamped resolved depth = LITERAL typed depth, clamped>,
---     parent_index = <1-based index into rows_above of the resolved PARENT, or nil
---                     when the line is top-level (depth 0)> }
---
--- DEPTH is the literal typed dashboard indentation (Phase 2): a col-0 line is a
--- top-level item (depth 0, no parent) for BOTH task and description kinds — the
--- old col-0 description promotion rule is gone.  Parent resolution is purely by
--- depth, so a DIM ancestor row is a valid parent at its true absolute depth.
---
--- @param line       string
--- @param rows_above table[]   { {depth, kind}, … } in top→anchor order
--- @return table
function M.resolve(line, rows_above)
  local kind, marker, body = M.classify_kind(line)
  local typed = M.typed_depth(line)

  local anchor = rows_above[#rows_above]
  local anchor_depth = anchor and anchor.depth or 0

  -- CLAMP: at most one level deeper than the line immediately above.
  local clamped = math.min(typed, anchor_depth + 1)
  if clamped < 0 then
    clamped = 0
  end

  -- LITERAL depth for BOTH kinds.  A col-0 line is a true top-level item (no
  -- parent).  Otherwise the parent is the nearest preceding managed row whose
  -- depth == clamped-1 (a dim ancestor at that depth qualifies just like a lit
  -- row — depth is depth).
  if clamped == 0 then
    return { kind = kind, marker = marker, body = body, depth = 0, parent_index = nil }
  end

  local parent_index = nil
  for i = #rows_above, 1, -1 do
    if rows_above[i].depth == clamped - 1 then
      parent_index = i
      break
    end
  end
  -- If no exact-depth parent found (shouldn't happen post-clamp), fall back to
  -- the immediate anchor.
  return {
    kind = kind,
    marker = marker,
    body = body,
    depth = clamped,
    parent_index = parent_index or #rows_above,
  }
end

return M
