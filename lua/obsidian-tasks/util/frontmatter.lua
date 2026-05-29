-- lua/obsidian-tasks/util/frontmatter.lua
-- Minimal YAML-lite parser for note frontmatter.
--
-- This is NOT a general YAML parser. It covers only the surface obsidian-tasks
-- actually consumes:
--   • `aliases`            — string OR list (inline `[a, b]` or block `- a`)
--   • `tasks-plugin.ignore` — nested map (`tasks-plugin:` / `  ignore: true`)
--                             OR the flat dotted key (`tasks-plugin.ignore: true`)
-- Other keys are parsed best-effort as scalars / lists; anything it cannot make
-- sense of is silently skipped. Quoted strings keep their contents verbatim;
-- bare `true`/`false` become booleans; everything else stays a string (so a
-- numeric-looking alias is preserved as text).

local M = {}

--- Trim surrounding whitespace.
--- @param s string
--- @return string
local function trim(s)
  s = s:gsub("^%s+", "")
  s = s:gsub("%s+$", "")
  return s
end

--- Parse a bare scalar: strip one layer of matching quotes, coerce booleans.
--- @param raw string
--- @return string|boolean|nil
local function parse_scalar(raw)
  local s = trim(raw)
  if s == "" then
    return nil
  end
  local q = s:sub(1, 1)
  if (q == '"' or q == "'") and #s >= 2 and s:sub(-1) == q then
    return s:sub(2, -2)
  end
  if s == "true" then
    return true
  end
  if s == "false" then
    return false
  end
  return s
end

--- Parse the inside of an inline `[a, b, c]` list. Naive comma split — quoted
--- commas are not handled (out of scope for the consumed surface).
--- @param inner string  text between the brackets
--- @return table
local function parse_inline_list(inner)
  local items = {}
  inner = trim(inner)
  if inner == "" then
    return items
  end
  for part in (inner .. ","):gmatch("(.-),") do
    local v = parse_scalar(part)
    if v ~= nil then
      items[#items + 1] = v
    end
  end
  return items
end

--- Parse a value to the right of `key:`. Inline list when bracketed, else scalar.
--- @param rest string
--- @return any
local function parse_value(rest)
  rest = trim(rest)
  if rest:sub(1, 1) == "[" and rest:sub(-1) == "]" then
    return parse_inline_list(rest:sub(2, -2))
  end
  return parse_scalar(rest)
end

--- Parse frontmatter YAML lines (the region between the `---` fences) into a
--- table. Always succeeds; the second return value is reserved for parity with
--- the previous adapter contract and is currently always an empty list.
---
--- @param lines string[]  the YAML region, one entry per line
--- @return table fields
--- @return string[] errors
function M.parse(lines)
  local result = {}
  if type(lines) ~= "table" then
    return result, {}
  end

  -- Top-level key currently awaiting indented block children (map or list).
  local current_key = nil

  for _, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    local trimmed = trim(line)
    if trimmed == "" or trimmed:sub(1, 1) == "#" then
      -- Blank or comment line: ignore. A blank does not terminate a YAML block,
      -- so current_key is preserved.
    elseif current_key and trimmed:match("^%-%s+") then
      -- Block list item (any indent), belonging to current_key.
      if type(result[current_key]) ~= "table" then
        result[current_key] = {}
      end
      local v = parse_scalar(trimmed:match("^%-%s+(.*)$"))
      if v ~= nil then
        local t = result[current_key]
        t[#t + 1] = v
      end
    else
      local indent = #(line:match("^(%s*)"))
      if indent == 0 then
        local key, rest = line:match("^([%w%-_%.]+):%s*(.*)$")
        if key then
          if trim(rest) == "" then
            current_key = key -- block follows; container made lazily by children
          else
            result[key] = parse_value(rest)
            current_key = nil
          end
        else
          current_key = nil
        end
      elseif current_key then
        -- Indented, not a list item → nested map entry under current_key.
        local subkey, subrest = line:match("^%s*([%w%-_%.]+):%s*(.*)$")
        if subkey then
          if type(result[current_key]) ~= "table" then
            result[current_key] = {}
          end
          result[current_key][subkey] = parse_value(subrest)
        end
      end
    end
  end

  return result, {}
end

return M
