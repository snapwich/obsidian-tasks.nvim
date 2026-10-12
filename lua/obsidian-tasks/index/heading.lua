-- lua/obsidian-tasks/index/heading.lua
-- Markdown ATX heading detector, used by the indexer to record the heading
-- a task line sits under (upstream's `task.precedingHeader`).
--
-- v1 scope: column-0 ATX headings only (`# …` … `###### …`).  Setext headings
-- are out of scope.  This parser looks at ONE line; whether that line can be a
-- heading at all (not in the frontmatter, not in a fenced code block) is
-- util/md_structure.lua's job — callers go through md_structure.scan(lines).

local M = {}

--- Parse a single line as an ATX heading.
---
--- Returns the heading text (leading `#`s and an optional trailing closing
--- `#` sequence stripped, then trimmed) for a heading line, or nil otherwise.
--- The text may be the empty string (e.g. `## `).
---
--- A task line (`- [ ] …`) never matches `^#+%s`, so there is no ambiguity
--- with the task scanner.
---
--- @param line string
--- @return string|nil
function M.parse(line)
  local hashes, rest = line:match("^(#+)[ \t]+(.*)$")
  if not hashes or #hashes > 6 then
    return nil
  end
  -- Strip an ATX closing sequence: whitespace + trailing run of `#`.
  rest = rest:gsub("[ \t]+#+[ \t]*$", "")
  return (vim.trim(rest))
end

return M
