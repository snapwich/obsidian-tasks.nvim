-- lua/obsidian-tasks/render/foldtext.lua
-- Pure summarizer: query AST + result count → human-readable summary string.
-- Consumed by render/init.lua and rendered as a virt_lines_above extmark by
-- render/draw.lua (see draw.set_summary).  The string is no longer used as
-- Neovim foldtext: we used to set `vim.wo.foldtext` to a Lua callback, but
-- render-markdown.nvim and similar plugins overlay decorations at column 0 of
-- the folded fence line and competed with our text.  Moving the summary to a
-- virt_lines_above extmark on the opening fence sidesteps that collision.

local M = {}

-- ── Internal: date value humanisation ─────────────────────────────────────────

--- Convert an ISO date string to a human-readable label when possible.
--- Recognises today / tomorrow / yesterday; leaves other dates as-is.
--- @param val any
--- @return string
local function fmt_date(val)
  if type(val) ~= "string" then
    return tostring(val or "")
  end
  local today = os.date("%Y-%m-%d")
  local tomorrow = os.date("%Y-%m-%d", os.time() + 86400)
  local yesterday = os.date("%Y-%m-%d", os.time() - 86400)
  if val == today then
    return "today"
  elseif val == tomorrow then
    return "tomorrow"
  elseif val == yesterday then
    return "yesterday"
  end
  return val
end

-- ── Internal: leaf filter → short phrase ──────────────────────────────────────

--- Map a parsed leaf filter spec to a short human-readable phrase.
--- @param filter table  filter spec from query/parse.lua leaf node
--- @return string
local function leaf_phrase(filter)
  local t = filter.type

  -- status
  if t == "not_done" then
    return "not done"
  end
  if t == "done" then
    return "done"
  end
  if t == "status_name" then
    return "status " .. (filter.value or "")
  end
  if t == "status_type" then
    return "status type " .. (filter.value or ""):lower()
  end

  -- recurrence
  if t == "is_recurring" then
    return "recurring"
  end
  if t == "is_not_recurring" then
    return "not recurring"
  end

  -- priority
  if t == "priority" then
    local op_labels = { is = "is", above = "above", below = "below", not_is = "not" }
    return "priority " .. (op_labels[filter.operator] or filter.operator) .. " " .. (filter.value or "")
  end

  -- date presence
  if t == "has_date" then
    return "has " .. filter.field .. " date"
  end
  if t == "no_date" then
    return "no " .. filter.field .. " date"
  end
  if t == "date_invalid" then
    return filter.field .. " date invalid"
  end

  -- date comparison  (due before today, due on today, etc.)
  if t == "date" then
    return filter.field .. " " .. filter.operator .. " " .. fmt_date(filter.value)
  end

  -- text field filters
  if t == "text" then
    local op_labels = {
      includes = "includes",
      does_not_include = "excludes",
      regex_matches = "~",
      regex_does_not_match = "!~",
    }
    return filter.field .. " " .. (op_labels[filter.operator] or filter.operator) .. " " .. (filter.value or "")
  end

  -- tag filters
  if t == "tag" then
    if filter.operator == "has" then
      return "has tag"
    end
    if filter.operator == "no" then
      return "no tag"
    end
    -- tag includes #next → show "#next"
    local val = filter.value or ""
    if val:sub(1, 1) ~= "#" then
      val = "#" .. val
    end
    return val
  end

  -- misc
  if t == "exclude_sub_items" then
    return "exclude sub-items"
  end
  if t == "urgency" then
    return "urgency " .. filter.operator .. " " .. tostring(filter.value or "")
  end
  if t == "random" then
    return "random"
  end

  -- unknown: surface the type name so users can see what's there
  return "<" .. t .. ">"
end

-- ── Internal: AST walker ──────────────────────────────────────────────────────

--- Recursively collect short phrases from an AST filter node.
--- @param node table   filter AST node (leaf / and / or / not)
--- @param out  table   accumulator (list of strings)
local function collect_phrases(node, out)
  if not node then
    return
  end
  if node.kind == "leaf" then
    out[#out + 1] = leaf_phrase(node.filter)
  elseif node.kind == "and" then
    -- AND: flatten both sides into the same phrase list (most common case).
    for _, child in ipairs(node.children or {}) do
      collect_phrases(child, out)
    end
  elseif node.kind == "or" then
    -- OR: render as "A or B".
    local parts = {}
    for _, child in ipairs(node.children or {}) do
      local sub = {}
      collect_phrases(child, sub)
      parts[#parts + 1] = table.concat(sub, " · ")
    end
    out[#out + 1] = table.concat(parts, " or ")
  elseif node.kind == "not" then
    local sub = {}
    if node.children and node.children[1] then
      collect_phrases(node.children[1], sub)
    end
    out[#out + 1] = "not (" .. table.concat(sub, " · ") .. ")"
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Convert a query AST + result count to a summary string.
---
--- Shape: "📋 <filter summary>  (N)"
--- Special cases:
---   • No filters  → "📋 all tasks  (N)"
---   • Parse errors → "📋 invalid query"  (count is ignored)
---
--- @param ast    table    { filters, errors, ... } from query/parse.lua
--- @param count  integer  number of task lines rendered in this block
--- @return string
function M.summarize(ast, count)
  if ast.errors and #ast.errors > 0 then
    return "📋 invalid query"
  end

  local phrases = {}
  for _, node in ipairs(ast.filters or {}) do
    collect_phrases(node, phrases)
  end

  local summary
  if #phrases == 0 then
    summary = "all tasks"
  else
    summary = table.concat(phrases, " · ")
  end

  return string.format("📋 %s  (%d)", summary, count)
end

return M
