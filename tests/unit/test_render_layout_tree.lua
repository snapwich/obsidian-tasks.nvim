-- tests/unit/test_render_layout_tree.lua
-- Unit tests for render/layout.lua's `show tree` path (Phase 4).
--
-- Covers: tree_rows → render records with depth-relative 2-space indent, the
-- task/bullet/blank kind mapping, read-only flagging of bullet/blank rows,
-- fold_group threading, group headers on group transitions, and source order.

local T = MiniTest.new_set()

local layout_mod = require("obsidian-tasks.render.layout")
local parse_task = require("obsidian-tasks.task.parse")

local eq = MiniTest.expect.equality

--- Parse a valid task line and tag it with src metadata.
local function task_row(line, path, src_line, depth, fold_group, group_name, group_index, matched, dim)
  local t = parse_task.parse(line)
  assert(t ~= nil, "expected task line: " .. line)
  t._src_path = path
  t._src_line = src_line
  return {
    kind = "task",
    depth = depth,
    src_path = path,
    src_line = src_line,
    task = t,
    matched = matched or false,
    dim = dim or nil,
    fold_group = fold_group,
    group_name = group_name or "",
    group_index = group_index or 0,
  }
end

local function bullet_row(text, path, src_line, depth, fold_group, group_name, group_index, marker, indent)
  return {
    kind = "bullet",
    depth = depth,
    src_path = path,
    src_line = src_line,
    text = text,
    bullet_marker = marker or "-",
    bullet_indent = indent or "",
    matched = false,
    fold_group = fold_group,
    group_name = group_name or "",
    group_index = group_index or 0,
  }
end

local function blank_row(path, src_line, fold_group, group_name, group_index)
  return {
    kind = "blank",
    depth = nil,
    src_path = path,
    src_line = src_line,
    text = nil,
    matched = false,
    fold_group = fold_group,
    group_name = group_name or "",
    group_index = group_index or 0,
  }
end

local function make_result(tree_rows, total)
  return {
    groups = {},
    total = total or 0,
    hide_flags = { backlinks = true }, -- suppress wikilink suffix for clean asserts
    header_summary = "",
    errors = {},
    tree_rows = tree_rows,
  }
end

local function records_of_kind(records, kind)
  local out = {}
  for _, r in ipairs(records) do
    if r.kind == kind then
      out[#out + 1] = r
    end
  end
  return out
end

-- ── task rows: depth → 2-space indent ────────────────────────────────────────

T["tree: nested task row gets 2-space-per-level indent"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] Root", p, 1, 0, 1, "", 0, true),
    task_row("  - [ ] Child", p, 2, 1, 1, "", 0, false),
    task_row("    - [ ] Grand", p, 3, 2, 1, "", 0, false),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 3)
  -- Root: no extra indent.
  eq(tasks[1].text, "- [ ] Root")
  -- Child: depth 1 → 2 leading spaces.
  eq(tasks[2].text, "  - [ ] Child")
  -- Grandchild: depth 2 → 4 leading spaces.
  eq(tasks[3].text, "    - [ ] Grand")
  -- tree_kind + fold_group threaded.
  eq(tasks[1].tree_kind, "task")
  eq(tasks[1].fold_group, 1)
  eq(tasks[1].matched, true)
  eq(tasks[2].matched, false)
end

-- ── bullet rows: editable, indented, original marker preserved ───────────────

T["tree: bullet row is editable, indented by depth, keeps '-' marker"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] Root", p, 1, 0, 1, "", 0, true),
    bullet_row("a note", p, 2, 1, 1, "", 0, "-", "  "),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 2)
  -- Bullet renders with its ORIGINAL marker, indented 2 spaces (depth 1).
  eq(tasks[2].text, "  - a note")
  eq(tasks[2].tree_kind, "bullet")
  -- Phase 5a: bullets are EDITABLE — NOT read-only.
  eq(tasks[2].read_only, nil)
  -- Write-back metadata carried for the raw bullet pipeline.
  eq(tasks[2].source_indent, "  ")
  eq(tasks[2].bullet_marker, "-")
  -- source_text is the verbatim source line for drift detection.
  eq(tasks[2].source_text, "  - a note")
  -- Task row is NOT read-only (editable).
  eq(tasks[1].read_only, nil)
end

T["tree: bullet row renders '*' / '+' markers as themselves (no synthesized '-')"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] Root", p, 1, 0, 1, "", 0, true),
    bullet_row("star note", p, 2, 1, 1, "", 0, "*", "    "),
    bullet_row("plus note", p, 3, 1, 1, "", 0, "+", "\t"),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 3)
  -- '*' bullet: dashboard keeps the original marker at depth-relative indent.
  eq(tasks[2].text, "  * star note")
  eq(tasks[2].bullet_marker, "*")
  -- SOURCE form preserves the ORIGINAL 4-space indent (not the dashboard's).
  eq(tasks[2].source_indent, "    ")
  eq(tasks[2].source_text, "    * star note")
  -- '+' bullet with a TAB source indent round-trips byte-for-byte.
  eq(tasks[3].text, "  + plus note")
  eq(tasks[3].bullet_marker, "+")
  eq(tasks[3].source_indent, "\t")
  eq(tasks[3].source_text, "\t+ plus note")
end

-- ── blank rows: empty line, read-only ────────────────────────────────────────

T["tree: blank row renders empty and is read-only"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] Root", p, 1, 0, 1, "", 0, true),
    blank_row(p, 2, 1, "", 0),
    bullet_row("after blank", p, 3, 1, 1, "", 0),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 3)
  eq(tasks[2].text, "")
  eq(tasks[2].tree_kind, "blank")
  eq(tasks[2].read_only, true)
end

-- ── source order + caller order preserved ────────────────────────────────────

T["tree: rows emitted in given (source/caller) order"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] R1", p, 1, 0, 1, "", 0, true),
    task_row("  - [ ] R1child", p, 2, 1, 1, "", 0, false),
    task_row("- [ ] R2", p, 5, 0, 2, "", 1, true),
  }
  local out = layout_mod.layout(make_result(rows, 2))
  local tasks = records_of_kind(out, "task")
  eq(tasks[1].text, "- [ ] R1")
  eq(tasks[2].text, "  - [ ] R1child")
  eq(tasks[3].text, "- [ ] R2")
  eq(tasks[1].fold_group, 1)
  eq(tasks[2].fold_group, 1)
  eq(tasks[3].fold_group, 2)
end

-- ── group headers on transitions ─────────────────────────────────────────────

T["tree: group header emitted on group-name transition"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] A", p, 1, 0, 1, "#alpha", 0, true),
    task_row("- [ ] B", p, 2, 0, 2, "#beta", 0, true),
  }
  local out = layout_mod.layout(make_result(rows, 2))
  local headers = records_of_kind(out, "group_header")
  eq(#headers, 2)
  eq(headers[1].text, "## #alpha")
  eq(headers[2].text, "## #beta")
end

-- ── footer still rendered ────────────────────────────────────────────────────

T["tree: footer present with matched-root count"] = function()
  local p = "/v/a.md"
  local rows = {
    task_row("- [ ] Root", p, 1, 0, 1, "", 0, true),
    task_row("  - [ ] Child", p, 2, 1, 1, "", 0, false),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local footers = records_of_kind(out, "footer")
  eq(#footers, 1)
  -- total reflects matched roots (1), not the 2 emitted rows.
  eq(footers[1].text:find("1 result") ~= nil, true)
end

-- ── induced-forest: absolute depth + DIM connector ancestors ─────────────────

T["tree: a deep matched task with a 4-space on-disk indent strips to flush-left at depth 0"] = function()
  -- The matched task is the top-level root (depth 0) but its on-disk line is
  -- indented (e.g. the file uses 4-space nesting and this is at column 4).  The
  -- DISPLAY must strip the leading whitespace and re-apply tree_indent(0) = ""
  -- (flush-left) WITHOUT touching source_indent / source_text.
  local p = "/v/a.md"
  local rows = {
    -- On-disk line carries a 4-space indent; depth (true source depth) is 0.
    task_row("    - [ ] Indented root", p, 1, 0, 1, "", 0, true),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 1)
  -- DISPLAY is flush-left (depth 0 → no indent), even though disk had 4 spaces.
  eq(tasks[1].text, "- [ ] Indented root")
  -- INVARIANT: source_indent is the TRUE on-disk indent (4 spaces), NOT derived
  -- from the rendered flush-left column.
  eq(tasks[1].source_indent, "    ")
  -- INVARIANT: source_text is the VERBATIM disk line (raw_line), not the render.
  eq(tasks[1].source_text, "    - [ ] Indented root")
end

T["tree: DIM connector-ancestor task row is editable, dimmed, at true depth, with real source meta"] = function()
  local p = "/v/a.md"
  local rows = {
    -- Dim breadcrumb ancestors at true depths 0 and 1 (fold_group 0 sentinel).
    task_row("- [ ] grandparent", p, 1, 0, 0, "", 0, false, true),
    task_row("  - [ ] parent", p, 2, 1, 0, "", 0, false, true),
    -- Lit matched root at true depth 2.
    task_row("    - [ ] matched", p, 3, 2, 1, "", 0, true, false),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 3)
  -- Dim rows render at their true depth (2-space-per-level), dimmed.
  eq(tasks[1].text, "- [ ] grandparent")
  eq(tasks[1].dim, true)
  eq(tasks[2].text, "  - [ ] parent")
  eq(tasks[2].dim, true)
  -- Lit matched row: dim nil.
  eq(tasks[3].text, "    - [ ] matched")
  eq(tasks[3].dim, nil)
  -- Dim ancestor rows are EDITABLE (not read_only) and registered as managed
  -- task rows carrying real source meta for later edit phases.
  eq(tasks[1].read_only, nil)
  eq(tasks[1].tree_kind, "task")
  eq(tasks[1].source_indent, "")
  eq(tasks[1].source_text, "- [ ] grandparent")
  eq(tasks[2].read_only, nil)
  eq(tasks[2].source_indent, "  ")
  eq(tasks[2].source_text, "  - [ ] parent")
  -- Dim rows carry the sentinel fold_group 0 (always visible, not foldable).
  eq(tasks[1].fold_group, 0)
  eq(tasks[2].fold_group, 0)
  -- Lit row is in a real fold group.
  eq(tasks[3].fold_group, 1)
end

T["tree: a completed (Done) lit task is dimmed in place (no reorder)"] = function()
  -- A completed task in the tree path must still carry dim (live-completed),
  -- in its emitted position — proving dim-in-place applies to BOTH flat and tree.
  local p = "/v/a.md"
  local rows = {
    task_row("- [x] Done root", p, 1, 0, 1, "", 0, true),
    task_row("  - [ ] Active child", p, 2, 1, 1, "", 1, false),
  }
  local out = layout_mod.layout(make_result(rows, 1), { dim_completed = true })
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 2)
  -- Done root emitted FIRST (its position), dimmed.
  eq(tasks[1].text, "- [x] Done root")
  eq(tasks[1].dim, true)
  -- Active child not dimmed.
  eq(tasks[2].dim, nil)
end

T["tree: a DIM connector-ancestor BULLET row is editable, dimmed, with bullet write-back meta"] = function()
  local p = "/v/a.md"
  local rows = {
    -- A bullet ancestor (a checkbox nested under a `-` bullet), dim.
    {
      kind = "bullet",
      depth = 0,
      src_path = p,
      src_line = 1,
      text = "a plain bullet",
      bullet_marker = "-",
      bullet_indent = "",
      bullet_source_text = "- a plain bullet",
      matched = false,
      dim = true,
      fold_group = 0,
      group_name = "",
      group_index = 0,
    },
    task_row("  - [ ] matched", p, 2, 1, 1, "", 0, true, false),
  }
  local out = layout_mod.layout(make_result(rows, 1))
  local tasks = records_of_kind(out, "task")
  eq(#tasks, 2)
  eq(tasks[1].tree_kind, "bullet")
  eq(tasks[1].dim, true)
  eq(tasks[1].read_only, nil)
  eq(tasks[1].text, "- a plain bullet")
  eq(tasks[1].source_indent, "")
  eq(tasks[1].bullet_marker, "-")
  eq(tasks[1].source_text, "- a plain bullet")
  eq(tasks[1].fold_group, 0)
end

return T
