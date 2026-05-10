-- lua/obsidian-tasks/render/foldtext.lua
-- Query-derived foldtext for dashboard buffers.
--
-- Two public surfaces:
--   M.summarize(ast, count)  — pure function, easy to unit-test.
--   M.foldtext()             — called by Neovim via vim.wo.foldtext; reads
--                              v:foldstart / v:foldend, looks up cached count.
--   M.set_result_count(bufnr, fence_first, count)  — called by render/init.lua
--                              after each render to cache the result count per block.
--   M.clear_buffer(bufnr)   — called on BufDelete / clear.

local M = {}

-- ── Result count cache ────────────────────────────────────────────────────────
-- _result_cache[bufnr][fence_first_0indexed] = count
-- Populated by render/init.lua after each render so foldtext() can look up the
-- count without re-running the query.
local _result_cache = {}

--- Store the rendered result count for a block.
--- @param bufnr      integer
--- @param fence_first integer  0-indexed opening-fence row
--- @param count      integer
function M.set_result_count(bufnr, fence_first, count)
  if not _result_cache[bufnr] then
    _result_cache[bufnr] = {}
  end
  _result_cache[bufnr][fence_first] = count
end

--- Drop all cached counts for a buffer (call on clear / BufDelete).
--- @param bufnr integer
function M.clear_buffer(bufnr)
  _result_cache[bufnr] = nil
end

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

--- Pure function: convert a query AST + result count to a foldtext summary string.
---
--- Shape: "📋 <filter summary>  (N)"
--- Special cases:
---   • No filters  → "📋 all tasks  (N)"
---   • Parse errors → "📋 invalid query"  (count is ignored)
---
--- @param ast   table    { filters, errors, ... } from query/parse.lua
--- @param count integer  number of task lines rendered in this block
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

--- Called by Neovim as the foldtext function.
--- Set via: vim.wo.foldtext = 'v:lua.require("obsidian-tasks.render.foldtext").foldtext()'
---
--- Reads v:foldstart (1-indexed), extracts the query text between the opening
--- and closing fence, parses it, looks up the cached result count, and delegates
--- to M.summarize().
---
--- @return string
function M.foldtext()
  local bufnr = vim.api.nvim_get_current_buf()
  local fold_start = vim.v.foldstart -- 1-indexed, the opening ```tasks line
  local fold_end = vim.v.foldend -- 1-indexed, last line in the fold

  -- 0-indexed fence row (key into _result_cache).
  local fence_first = fold_start - 1

  -- Extract query lines: everything between the opening fence and the first
  -- closing fence (```) that falls within the fold.
  -- nvim_buf_get_lines uses 0-indexed [start, end) so fold_start..fold_end-1
  -- gives us the lines after the opening fence through the last folded line.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, fold_start, fold_end - 1, false)
  local query_lines = {}
  for _, line in ipairs(buf_lines) do
    if line:match("^%s*```%s*$") then
      break
    end
    query_lines[#query_lines + 1] = line
  end
  local query_text = table.concat(query_lines, "\n")

  -- Parse to detect structural errors.
  local ok, ast = pcall(require("obsidian-tasks.query.parse").parse, query_text)
  if not ok then
    return "📋 invalid query"
  end

  -- Look up the cached result count written by render/init.lua.
  local count = (_result_cache[bufnr] or {})[fence_first] or 0

  return M.summarize(ast, count)
end

return M
