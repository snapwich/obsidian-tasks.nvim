-- tests/unit/test_lenient_parse.lua
-- Lenient parsing: invalid field values are captured under _raw_fields and
-- _errors so the task still has structure, but filters/sorts treat the
-- field as absent and the renderer can mark it invalid.

local T = MiniTest.new_set()
local parse = require("obsidian-tasks.task.parse")
local serialize = require("obsidian-tasks.task.serialize")

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

-- ── date fields ──────────────────────────────────────────────────────────────

T["lenient date: emoji 'someday' captured as invalid"] = function()
  local t = parse.parse("- [ ] task 📅 someday")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "someday")
  eq(type(t._errors.due), "string")
end

T["lenient date: dataview 'not-a-date' captured as invalid"] = function()
  local t = parse.parse("- [ ] task [due:: not-a-date]")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "not-a-date")
  eq(type(t._errors.due), "string")
end

T["lenient date: day 32 rejected"] = function()
  local t = parse.parse("- [ ] task 📅 2025-01-32")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "2025-01-32")
end

T["lenient date: month 13 rejected"] = function()
  local t = parse.parse("- [ ] task 📅 2025-13-01")
  eq(t.fields.due, nil)
  eq(t._raw_fields.due, "2025-13-01")
end

T["lenient date: valid ISO leaves _raw_fields empty"] = function()
  local t = parse.parse("- [ ] task 📅 2025-05-16")
  eq(t.fields.due, "2025-05-16")
  eq(t._raw_fields.due, nil)
  eq(t._errors.due, nil)
end

T["lenient date: all date fields validated"] = function()
  local t = parse.parse("- [ ] task ⏳ bad 🛫 worse ✅ ugly")
  eq(t.fields.scheduled, nil)
  eq(t._raw_fields.scheduled, "bad")
  eq(t.fields.start, nil)
  eq(t._raw_fields.start, "worse")
  eq(t.fields.done, nil)
  eq(t._raw_fields.done, "ugly")
end

-- ── priority ─────────────────────────────────────────────────────────────────

T["lenient priority: dataview 'bogus' captured as invalid"] = function()
  local t = parse.parse("- [ ] task [priority:: bogus]")
  eq(t.fields.priority, nil)
  eq(t._raw_fields.priority, "bogus")
  eq(type(t._errors.priority), "string")
end

T["lenient priority: dataview valid level accepted"] = function()
  local t = parse.parse("- [ ] task [priority:: high]")
  eq(t.fields.priority, "high")
  eq(t._raw_fields.priority, nil)
end

T["lenient priority: emoji unaffected (only known emojis ever match)"] = function()
  local t = parse.parse("- [ ] task ⏫")
  eq(t.fields.priority, "high")
  eq(t._errors.priority, nil)
end

-- ── non-validated kinds ──────────────────────────────────────────────────────

T["lenient: recurrence string passes through unchanged"] = function()
  local t = parse.parse("- [ ] task 🔁 every weird thing")
  eq(t.fields.recurrence, "every weird thing")
  eq(t._raw_fields.recurrence, nil)
end

T["lenient: id string passes through"] = function()
  local t = parse.parse("- [ ] task 🆔 anything-goes_42")
  eq(t.fields.id, "anything-goes_42")
end

-- ── serialize round-trips ────────────────────────────────────────────────────

T["serialize: invalid emoji-origin date re-emits raw"] = function()
  local t = parse.parse("- [ ] task 📅 someday")
  local line = serialize.serialize(t)
  eq(line, "- [ ] task 📅 someday")
end

T["serialize: invalid dataview-origin priority re-emits raw"] = function()
  local t = parse.parse("- [ ] task [priority:: bogus]")
  local line = serialize.serialize(t)
  eq(line, "- [ ] task [priority:: bogus]")
end

T["serialize: multiple invalid fields all re-emit"] = function()
  local t = parse.parse("- [ ] task 📅 someday ⏳ never")
  local line = serialize.serialize(t)
  -- Serializer canonicalizes field order: start < scheduled < due, so
  -- scheduled comes before due.
  eq(line, "- [ ] task ⏳ never 📅 someday")
end

-- ── raw_line normalization ───────────────────────────────────────────────────
-- Drift detection compares raw_line (set by the parser) to disk-read source
-- lines (which strip line endings).  Parser must strip trailing \n / \r\n so
-- callers that hand it un-stripped lines (e.g. ripgrep-backed index/scan) get
-- a comparable raw_line.

T["raw_line: trailing \\n stripped"] = function()
  local t = parse.parse("- [ ] task 📅 2026-05-20\n")
  eq(t.raw_line, "- [ ] task 📅 2026-05-20")
end

T["raw_line: trailing \\r\\n stripped"] = function()
  local t = parse.parse("- [ ] task 📅 2026-05-20\r\n")
  eq(t.raw_line, "- [ ] task 📅 2026-05-20")
end

T["raw_line: no trailing newline → unchanged"] = function()
  local t = parse.parse("- [ ] task 📅 2026-05-20")
  eq(t.raw_line, "- [ ] task 📅 2026-05-20")
end

-- ── serialize_with_meta: invalid_ranges ──────────────────────────────────────

T["serialize_with_meta: invalid date emits one range covering the value"] = function()
  local t = parse.parse("- [ ] task 📅 someday")
  local out = serialize.serialize_with_meta(t)
  eq(#out.invalid_ranges, 1)
  local s, e = out.invalid_ranges[1][1], out.invalid_ranges[1][2]
  -- The range should cover exactly "someday" inside out.text.
  eq(out.text:sub(s, e - 1), "someday")
end

T["serialize_with_meta: valid task emits no ranges"] = function()
  local t = parse.parse("- [ ] task 📅 2025-05-16")
  local out = serialize.serialize_with_meta(t)
  eq(#out.invalid_ranges, 0)
end

T["serialize_with_meta: dataview priority value range covers exactly the level"] = function()
  local t = parse.parse("- [ ] task [priority:: bogus]")
  local out = serialize.serialize_with_meta(t)
  eq(#out.invalid_ranges, 1)
  local s, e = out.invalid_ranges[1][1], out.invalid_ranges[1][2]
  eq(out.text:sub(s, e - 1), "bogus")
end

T["serialize_with_meta: multiple invalid fields produce multiple ranges"] = function()
  local t = parse.parse("- [ ] task 📅 someday ⏳ never")
  local out = serialize.serialize_with_meta(t)
  eq(#out.invalid_ranges, 2)
end

return T
