-- tests/unit/test_group_attr_inject.lua
-- RED-phase unit tests for P9: inject_group_attributes helper.
--
-- All tests that expect the helper to MODIFY the line are FAILING in RED
-- (the stub returns the line unchanged).  Tests that expect NO modification
-- (file / folder / heading groups; tag already present; no group-by) are
-- regression guards and PASS in both RED and GREEN.
--
-- group_context format:
--   { { by="tag",      value="someday"     },   -- bare tag name (no #)
--     { by="priority", value="high"        },   -- canonical level name
--     { by="status",   value="In Progress" }, } -- status name
--
-- task_origin mirrors task._origin from P2 parse:
--   { [field_key] = "emoji"|"dataview", ... }
-- Nil / empty table → defaults to emoji form.

local T = MiniTest.new_set()

local inject = require("obsidian-tasks.render.group_attr").inject_group_attributes

local function eq(actual, expected, msg)
  MiniTest.expect.equality(actual, expected, msg)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Build a task_origin table that indicates emoji style for the given field.
--- @param field string
--- @return table
local function emoji_origin(field)
  return { [field] = "emoji" }
end

--- Build a task_origin table that indicates dataview style for the given field.
--- @param field string
--- @return table
local function dv_origin(field)
  return { [field] = "dataview" }
end

-- ── Tag group ─────────────────────────────────────────────────────────────────

-- RED FAIL: stub returns unchanged; GREEN should append "#someday".
T["group_attr: single group by tag — #someday appended"] = function()
  local result = inject("- [ ] New task", { { by = "tag", value = "someday" } }, nil)
  eq(result, "- [ ] New task #someday", "tag attribute must be appended")
end

-- RED FAIL: both #someday and priority emoji expected; stub returns unchanged.
T["group_attr: multi-level tag + priority (emoji) — both appended"] = function()
  local result =
    inject("- [ ] New task", { { by = "tag", value = "someday" }, { by = "priority", value = "high" } }, nil)
  eq(result, "- [ ] New task #someday ⏫", "tag and priority emoji must both be appended")
end

-- PASS in RED: tag already present → no duplicate.
-- Stub returns unchanged, which is the correct no-duplicate result.
T["group_attr: tag already present — no duplicate appended"] = function()
  local result = inject("- [ ] New task #someday", { { by = "tag", value = "someday" } }, nil)
  eq(result, "- [ ] New task #someday", "must not append duplicate tag")
end

-- ── Priority group ────────────────────────────────────────────────────────────

-- RED FAIL: stub returns unchanged; GREEN should append ⏫.
T["group_attr: single group by priority — emoji origin appends ⏫ for high"] = function()
  local result = inject("- [ ] New task", { { by = "priority", value = "high" } }, emoji_origin("priority"))
  eq(result, "- [ ] New task ⏫", "priority emoji ⏫ must be appended for high priority")
end

-- RED FAIL: stub returns unchanged; GREEN should append [priority:: high].
T["group_attr: single group by priority — dataview origin appends [priority:: high]"] = function()
  local result = inject("- [ ] New task", { { by = "priority", value = "high" } }, dv_origin("priority"))
  eq(result, "- [ ] New task [priority:: high]", "dataview priority field must be appended")
end

-- RED FAIL: medium priority → 🔼.
T["group_attr: priority medium — emoji 🔼 appended"] = function()
  local result = inject("- [ ] New task", { { by = "priority", value = "medium" } }, nil)
  eq(result, "- [ ] New task 🔼", "priority emoji 🔼 must be appended for medium priority")
end

-- RED FAIL: low priority → 🔽.
T["group_attr: priority low — emoji 🔽 appended"] = function()
  local result = inject("- [ ] New task", { { by = "priority", value = "low" } }, nil)
  eq(result, "- [ ] New task 🔽", "priority emoji 🔽 must be appended for low priority")
end

-- RED FAIL: lowest priority → ⏬.
T["group_attr: priority lowest — emoji ⏬ appended"] = function()
  local result = inject("- [ ] New task", { { by = "priority", value = "lowest" } }, nil)
  eq(result, "- [ ] New task ⏬", "priority emoji ⏬ must be appended for lowest priority")
end

-- RED FAIL: highest priority → 🔺.
T["group_attr: priority highest — emoji 🔺 appended"] = function()
  local result = inject("- [ ] New task", { { by = "priority", value = "highest" } }, nil)
  eq(result, "- [ ] New task 🔺", "priority emoji 🔺 must be appended for highest priority")
end

-- ── Status group ──────────────────────────────────────────────────────────────

-- RED FAIL: stub returns unchanged; GREEN should set checkbox to [/].
T["group_attr: single group by status In Progress — checkbox set to [/]"] = function()
  local result = inject("- [ ] New task", { { by = "status", value = "In Progress" } }, nil)
  eq(result, "- [/] New task", "checkbox must be set to [/] for In Progress group")
end

-- RED FAIL: Done group → [x].
T["group_attr: single group by status Done — checkbox set to [x]"] = function()
  local result = inject("- [ ] New task", { { by = "status", value = "Done" } }, nil)
  eq(result, "- [x] New task", "checkbox must be set to [x] for Done group")
end

-- RED FAIL: Cancelled group → [-].
T["group_attr: single group by status Cancelled — checkbox set to [-]"] = function()
  local result = inject("- [ ] New task", { { by = "status", value = "Cancelled" } }, nil)
  eq(result, "- [-] New task", "checkbox must be set to [-] for Cancelled group")
end

-- PASS in RED: checkbox already correct for status group → no modification.
-- Stub returns unchanged (correct for this case).
T["group_attr: status checkbox already correct — no modification"] = function()
  local result = inject("- [/] New task", { { by = "status", value = "In Progress" } }, nil)
  eq(result, "- [/] New task", "must not modify already-correct checkbox")
end

-- ── File / folder / heading groups (no auto-add) ──────────────────────────────

-- PASS in RED: file group → no modification.
T["group_attr: group by file — no modification"] = function()
  local result = inject("- [ ] New task", { { by = "file", value = "daily.md" } }, nil)
  eq(result, "- [ ] New task", "file group must not add any attribute")
end

-- PASS in RED: folder group → no modification.
T["group_attr: group by folder — no modification"] = function()
  local result = inject("- [ ] New task", { { by = "folder", value = "daily" } }, nil)
  eq(result, "- [ ] New task", "folder group must not add any attribute")
end

-- PASS in RED: heading group → no modification.
T["group_attr: group by heading — no modification"] = function()
  local result = inject("- [ ] New task", { { by = "heading", value = "My heading" } }, nil)
  eq(result, "- [ ] New task", "heading group must not add any attribute")
end

-- ── No group-by ───────────────────────────────────────────────────────────────

-- PASS in RED: empty group_context → no modification.
T["group_attr: no group-by — no modification"] = function()
  local result = inject("- [ ] Ungrouped task", {}, nil)
  eq(result, "- [ ] Ungrouped task", "empty group context must not modify the line")
end

-- PASS in RED: nil group_context → no modification (defensive).
T["group_attr: nil group_context — no modification"] = function()
  local result = inject("- [ ] Ungrouped task", nil, nil)
  eq(result, "- [ ] Ungrouped task", "nil group context must not modify the line")
end

-- ── Multi-level ───────────────────────────────────────────────────────────────

-- RED FAIL: tag + priority dataview → both appended in dataview form.
T["group_attr: multi-level tag + priority dataview — tag appended, [priority:: high] appended"] = function()
  local result = inject(
    "- [ ] New task",
    { { by = "tag", value = "someday" }, { by = "priority", value = "high" } },
    dv_origin("priority")
  )
  eq(result, "- [ ] New task #someday [priority:: high]", "tag and dataview priority must both be appended")
end

-- RED FAIL: status + tag → checkbox set AND tag appended.
T["group_attr: multi-level status + tag — checkbox set and tag appended"] = function()
  local result =
    inject("- [ ] New task", { { by = "status", value = "In Progress" }, { by = "tag", value = "work" } }, nil)
  eq(result, "- [/] New task #work", "checkbox must be set and tag appended for status+tag group")
end

return T
