-- tests/unit/test_wikilink_strip.lua
-- RED-phase tests for render/wikilink.strip_expected_suffix (P5).
--
-- Positive cases (suffix present, matches) FAIL while the stub returns input
-- unchanged.  Negative cases (suffix absent or non-matching) pass immediately
-- since the stub's no-op behaviour matches the expected "survives" outcome.
-- Positive cases pass once the GREEN task (ot-v0s1) implements real stripping.
--
-- Locked invariants:
--   • Only a trailing `[[<expected_basename>]]` is stripped.
--   • `[[<other_note>]]` anywhere in text — including at the end — survives.
--   • `[[<expected_basename>]]` appearing mid-line (not at the end) survives.
--   • Whitespace between the last task token and the wikilink suffix is trimmed.

local T = MiniTest.new_set()

local wikilink = require("obsidian-tasks.render.wikilink")

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

-- ── Positive: exact suffix is stripped ───────────────────────────────────────

T["strip_expected_suffix: exact [[basename]] suffix removed"] = function()
  -- Rendered: "- [ ] Foo [[Bar]]" where note basename = "Bar"
  local result = wikilink.strip_expected_suffix("- [ ] Foo [[Bar]]", "Bar")
  eq(result, "- [ ] Foo", "expected wikilink suffix should be stripped")
end

T["strip_expected_suffix: suffix with whitespace before it is stripped"] = function()
  -- Dashboard adds a space before the wikilink; strip should also consume it.
  local result = wikilink.strip_expected_suffix("- [ ] Buy milk [[Shopping List]]", "Shopping List")
  eq(result, "- [ ] Buy milk", "suffix (with preceding space) should be stripped")
end

T["strip_expected_suffix: suffix on task with date field"] = function()
  local result = wikilink.strip_expected_suffix("- [ ] Task 📅 2024-01-15 [[my-note]]", "my-note")
  eq(result, "- [ ] Task 📅 2024-01-15", "suffix should be stripped after date field")
end

-- ── Negative: non-matching [[other]] suffix survives ─────────────────────────

T["strip_expected_suffix: [[other note]] at end survives unchanged"] = function()
  -- The wikilink at end does NOT match the expected basename → leave it alone.
  local text = "- [ ] Foo [[other note]]"
  local result = wikilink.strip_expected_suffix(text, "Bar")
  eq(result, text, "non-matching wikilink suffix should survive unchanged")
end

T["strip_expected_suffix: no wikilink at all survives unchanged"] = function()
  local text = "- [ ] Plain task description"
  local result = wikilink.strip_expected_suffix(text, "Bar")
  eq(result, text, "text without any wikilink should survive unchanged")
end

-- ── Negative: mid-line [[expected_basename]] survives ────────────────────────

T["strip_expected_suffix: [[basename]] mid-line (not suffix) survives"] = function()
  -- User typed a legit wikilink mid-description; should not be stripped.
  local text = "- [ ] See [[Bar]] for details"
  local result = wikilink.strip_expected_suffix(text, "Bar")
  eq(result, text, "mid-line wikilink matching basename should survive unchanged")
end

T["strip_expected_suffix: [[basename]] followed by more text survives"] = function()
  -- Even if the matching basename appears, it's not at the very end.
  local text = "- [ ] [[Bar]] and then more text"
  local result = wikilink.strip_expected_suffix(text, "Bar")
  eq(result, text, "non-trailing wikilink should survive unchanged")
end

-- ── Edge cases ────────────────────────────────────────────────────────────────

T["strip_expected_suffix: empty text survives unchanged"] = function()
  local result = wikilink.strip_expected_suffix("", "Bar")
  eq(result, "", "empty text should be returned as-is")
end

T["strip_expected_suffix: basename is case-sensitive"] = function()
  -- [[bar]] with lowercase 'b' should NOT match expected_basename "Bar".
  local text = "- [ ] Foo [[bar]]"
  local result = wikilink.strip_expected_suffix(text, "Bar")
  eq(result, text, "basename matching should be case-sensitive; [[bar]] != [[Bar]]")
end

return T
