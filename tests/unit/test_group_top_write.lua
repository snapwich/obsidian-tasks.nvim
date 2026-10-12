-- tests/unit/test_group_top_write.lua
-- Plan D3 / D7 (group-top insert, step 4): the pure parts of the group-top
-- write path in render/group_top_write.lua.
--
--   target(group_by, segments)       → where a group-top insert goes, from the
--                                      STRUCTURED group segments (never a
--                                      " / " split of the joined group name);
--   build_lines(block_lines, opts)   → the source lines for a typed / pasted
--                                      block: roots clamped to depth 0, group
--                                      attributes on roots only, global filter
--                                      on every task line;
--   heading_level(lines, row, text)  → the level of the real heading line above
--                                      a task (copied when the heading must be
--                                      created in the target note).

local T = MiniTest.new_set()

local gtw = require("obsidian-tasks.render.group_top_write")

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

local function by(...)
  local out = {}
  for _, k in ipairs({ ... }) do
    out[#out + 1] = { key = k }
  end
  return out
end

-- ── target ────────────────────────────────────────────────────────────────────

T["target"] = MiniTest.new_set()

T["target"]["ungrouped → daily note, end of file, no attributes"] = function()
  local t = gtw.target({}, {})
  eq(t.kind, "daily")
  eq(t.in_section, false)
  eq(t.attrs, {})
end

T["target"]["heading → daily note, in that heading's section"] = function()
  local t = gtw.target(by("heading"), { "technical debt" })
  eq(t.kind, "daily")
  eq(t.in_section, true)
  eq(t.heading, "technical debt")
  eq(t.attrs, {})
end

T["target"]["(No heading) → daily note, the region before the first heading"] = function()
  local t = gtw.target(by("heading"), { "(No heading)" })
  eq(t.kind, "daily")
  eq(t.in_section, true)
  eq(t.heading, nil)
end

T["target"]["tags → daily note, end of file, tag attribute"] = function()
  local t = gtw.target(by("tags"), { "#work" })
  eq(t.kind, "daily")
  eq(t.in_section, false)
  eq(t.attrs, { { by = "tag", value = "work" } })
end

T["target"]["tags 'No tags' → no tag attribute"] = function()
  local t = gtw.target(by("tags"), { "No tags" })
  eq(t.kind, "daily")
  eq(t.attrs, {})
end

T["target"]["priority → canonical level name"] = function()
  local t = gtw.target(by("priority"), { "Priority 2: High" })
  eq(t.kind, "daily")
  eq(t.attrs, { { by = "priority", value = "high" } })
end

T["target"]["status → status name"] = function()
  local t = gtw.target(by("status"), { "In Progress" })
  eq(t.attrs, { { by = "status", value = "In Progress" } })
end

T["target"]["filename → that file, end of file"] = function()
  local t = gtw.target(by("filename"), { "work" })
  eq(t.kind, "file")
  eq(t.in_section, false)
end

T["target"]["filename + heading → that file, in the heading's section"] = function()
  local t = gtw.target(by("filename", "heading"), { "work", "technical debt" })
  eq(t.kind, "file")
  eq(t.in_section, true)
  eq(t.heading, "technical debt")
end

T["target"]["folder / path / root → fallback, reason names the key"] = function()
  for _, key in ipairs({ "folder", "path", "root" }) do
    local t = gtw.target(by(key), { "projects" })
    eq(t.kind, "fallback", key)
    eq(t.reason, key)
  end
end

T["target"]["filename + folder → that file (the file satisfies every location key)"] = function()
  local t = gtw.target(by("folder", "filename"), { "projects", "work" })
  eq(t.kind, "file")
end

T["target"]["heading + tags → daily heading section + tag attribute"] = function()
  local t = gtw.target(by("heading", "tags"), { "technical debt", "#work" })
  eq(t.kind, "daily")
  eq(t.in_section, true)
  eq(t.heading, "technical debt")
  eq(t.attrs, { { by = "tag", value = "work" } })
end

T["target"]["a heading segment that contains ' / ' stays one heading"] = function()
  local t = gtw.target(by("heading", "tags"), { "Design / Build", "#work" })
  eq(t.heading, "Design / Build")
  eq(t.attrs, { { by = "tag", value = "work" } })
end

T["target"]["a key with no group-top rule → fallback"] = function()
  local t = gtw.target(by("due"), { "2026-10-12" })
  eq(t.kind, "fallback")
  eq(t.reason, "due")
end

-- ── build_lines ───────────────────────────────────────────────────────────────

T["build_lines"] = MiniTest.new_set()

T["build_lines"]["flat: bare text → top-level task + global filter"] = function()
  local r = gtw.build_lines({ "Buy milk" }, { tree = false, attrs = {}, global_filter = "#task" })
  eq(r.lines, { "- [ ] Buy milk #task" })
  eq(r.first_task, 1)
  eq(r.root_description, false)
end

T["build_lines"]["flat: indented line → depth 0"] = function()
  local r = gtw.build_lines({ "    - [ ] Deep" }, { tree = false, attrs = {}, global_filter = "#task" })
  eq(r.lines, { "- [ ] Deep #task" })
end

T["build_lines"]["flat: every line is a root task with the attributes"] = function()
  local r = gtw.build_lines(
    { "- [ ] One", "  - [ ] Two" },
    { tree = false, attrs = { { by = "tag", value = "work" } }, global_filter = "#task" }
  )
  eq(r.lines, { "- [ ] One #work #task", "- [ ] Two #work #task" })
end

T["build_lines"]["tree: subtree keeps its shape, attributes on the root only"] = function()
  local r = gtw.build_lines(
    { "- [ ] Parent", "  - [ ] Child", "  - a note" },
    { tree = true, attrs = { { by = "tag", value = "work" } }, global_filter = "#task" }
  )
  eq(r.lines, { "- [ ] Parent #work #task", "  - [ ] Child #task", "  - a note" })
  eq(r.first_task, 1)
end

T["build_lines"]["tree: an indented root is clamped to depth 0"] = function()
  local r = gtw.build_lines({ "    - [ ] A", "      - [ ] B" }, { tree = true, attrs = {}, global_filter = "#task" })
  eq(r.lines, { "- [ ] A #task", "  - [ ] B #task" })
end

T["build_lines"]["tree: a single indented line is clamped to depth 0"] = function()
  local r = gtw.build_lines({ "      - [ ] Lonely" }, { tree = true, attrs = {}, global_filter = "#task" })
  eq(r.lines, { "- [ ] Lonely #task" })
end

T["build_lines"]["tree: a root description bullet is kept as typed and flagged"] = function()
  local r = gtw.build_lines({ "- just a note" }, { tree = true, attrs = {}, global_filter = "#task" })
  eq(r.lines, { "- just a note" })
  eq(r.root_description, true)
  eq(r.first_task, nil)
end

T["build_lines"]["first_task skips a leading description root"] = function()
  local r = gtw.build_lines({ "- a note", "- [ ] Real" }, { tree = true, attrs = {}, global_filter = "#task" })
  eq(r.first_task, 2)
end

T["build_lines"]["no global filter configured → nothing appended"] = function()
  local r = gtw.build_lines({ "Plain" }, { tree = false, attrs = {}, global_filter = nil })
  eq(r.lines, { "- [ ] Plain" })
end

-- ── heading_level ─────────────────────────────────────────────────────────────

T["heading_level"] = MiniTest.new_set()

T["heading_level"]["level of the nearest heading above when its text matches"] = function()
  local lines = { "# Project", "### technical debt", "- [ ] B #task", "- [ ] C #task" }
  eq(gtw.heading_level(lines, 3, "technical debt"), 3)
  eq(gtw.heading_level(lines, 2, "technical debt"), 3)
end

T["heading_level"]["nil when the nearest heading has other text, or none exists"] = function()
  eq(gtw.heading_level({ "## other", "- [ ] B" }, 1, "technical debt"), nil)
  eq(gtw.heading_level({ "- [ ] B" }, 0, "technical debt"), nil)
end

return T
