-- lua/obsidian-tasks/render/wikilink.lua
-- Wikilink suffix helpers for the edit-in-place flush path (P5).
--
-- At render time the plugin appends `[[<note_basename>]]` to every task line
-- so the user can navigate to the source file from the dashboard.  When a
-- managed row is flushed back to the source file the suffix must be stripped
-- before writing — otherwise the source task accumulates spurious wikilink
-- tokens on every edit.
--
-- Only the *expected* suffix (the one that matches the current note's basename)
-- is stripped.  Other `[[...]]` tokens that the user typed as part of the task
-- description survive verbatim.
--
-- Implementation is a stub; real logic lands in GREEN task ot-v0s1.

local M = {}

--- Strip the expected wikilink suffix `[[<expected_basename>]]` from the
--- trailing end of *text*.
---
--- Rules:
---   • Only a suffix is stripped — `[[<expected_basename>]]` that appears
---     elsewhere in *text* (mid-line) is left untouched.
---   • If the suffix is absent, or if it matches a different basename, *text*
---     is returned unchanged.
---   • The space before the opening `[[` is consumed as part of the suffix.
---   • Matching is case-sensitive.
---
--- @param text              string  the rendered task line content
--- @param expected_basename string  the source note's basename (without .md extension)
--- @return string  *text* with the expected suffix stripped, or *text* unchanged
function M.strip_expected_suffix(text, expected_basename)
  if not expected_basename or expected_basename == "" then
    return text
  end
  -- The render pipeline appends " [[<basename>]]" (with a leading space).
  local suffix = " [[" .. expected_basename .. "]]"
  if #text >= #suffix and text:sub(-#suffix) == suffix then
    -- Strip the suffix (including its leading space).
    return text:sub(1, -(#suffix + 1))
  end
  return text
end

return M
