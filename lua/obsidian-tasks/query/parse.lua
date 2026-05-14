-- lua/obsidian-tasks/query/parse.lua
-- Parse query block text (contents of a ```tasks fence) into an AST.
--
-- Output shape:
--   {
--     filters  = { node, ... },   -- each node: { kind, children | filter }
--     sort_by  = { { key, reverse }, ... },
--     group_by = { { key, reverse }, ... },
--     limit    = N or nil,
--     hide     = { 'priority', 'due date', ... },
--     errors   = { { kind, msg, line }, ... },
--   }
--
-- Filter node kinds:
--   'leaf'  { kind='leaf', filter={type=..., ...} }
--   'and'   { kind='and',  children={node, node} }
--   'or'    { kind='or',   children={node, node} }
--   'not'   { kind='not',  children={node} }

local M = {}

local date_nl = require("obsidian-tasks.cmp.date_nl")

-- ── Date parsing ─────────────────────────────────────────────────────────────
-- Delegates to cmp/date_nl for the full NL set (today, tomorrow, yesterday,
-- next <weekday>, this <weekday>, in N days/weeks/months, YYYY-MM-DD).
-- Falls back to returning the trimmed string as-is so unknown values are
-- preserved rather than silently discarded (the query evaluator validates).

local function parse_date(s)
  if not s then
    return nil
  end
  local trimmed = s:match("^%s*(.-)%s*$")
  return date_nl.parse(trimmed) or trimmed
end

-- ── Field / keyword tables ──────────────────────────────────────────────────

--- Ordered list of date fields (for deterministic prefix matching).
local DATE_FIELDS_LIST = { "cancelled", "scheduled", "created", "happens", "start", "done", "due" }

--- Priority level names.
local PRIORITY_LEVELS = {
  highest = true,
  high = true,
  medium = true,
  low = true,
  lowest = true,
  none = true,
}

--- Sort key canonical names.
local SORT_KEYS = {
  status = true,
  priority = true,
  due = true,
  scheduled = true,
  start = true,
  done = true,
  created = true,
  cancelled = true,
  happens = true,
  path = true,
  folder = true,
  root = true,
  backlink = true,
  description = true,
  heading = true,
  filename = true,
  tags = true,
  urgency = true,
  recurrence = true,
  recurring = true,
  id = true,
  blocking = true,
}

--- Group key canonical names (same as sort minus 'description' and 'blocking').
local GROUP_KEYS = {
  status = true,
  priority = true,
  due = true,
  scheduled = true,
  start = true,
  done = true,
  created = true,
  cancelled = true,
  happens = true,
  path = true,
  folder = true,
  root = true,
  backlink = true,
  heading = true,
  filename = true,
  tags = true,
  urgency = true,
  recurrence = true,
  recurring = true,
  id = true,
}

--- Hide subkey canonical names (lower-cased multi-word keys).
local HIDE_KEYS = {
  ["priority"] = true,
  ["due date"] = true,
  ["scheduled date"] = true,
  ["start date"] = true,
  ["done date"] = true,
  ["created date"] = true,
  ["cancelled date"] = true,
  ["recurrence rule"] = true,
  ["on completion"] = true,
  ["tags"] = true,
  ["id"] = true,
  ["depends on"] = true,
  ["backlinks"] = true,
  ["task count"] = true,
  ["tree"] = true,
  ["edit button"] = true,
  ["postpone button"] = true,
}

--- Text field keyword → canonical field name.
--- Covers both singular and plural variants.
local TEXT_FIELD_KEYWORDS = {
  path = "path",
  paths = "path",
  folder = "folder",
  folders = "folder",
  root = "root",
  roots = "root",
  backlink = "backlink",
  backlinks = "backlink",
  filename = "filename",
  filenames = "filename",
  description = "description",
  descriptions = "description",
  heading = "heading",
  headings = "heading",
  recurrence = "recurrence",
  id = "id",
}

--- Sorted list of text field keywords, longest first (prevents short prefix shadowing long one).
local TEXT_FIELD_KW_LIST = {}
for kw in pairs(TEXT_FIELD_KEYWORDS) do
  TEXT_FIELD_KW_LIST[#TEXT_FIELD_KW_LIST + 1] = kw
end
table.sort(TEXT_FIELD_KW_LIST, function(a, b)
  return #a > #b
end)

-- ── Boolean expression helpers ──────────────────────────────────────────────

--- Return the index of the closing ')' that matches the '(' at `start`.
--- @param s string
--- @param start integer  position of the opening '('
--- @return integer|nil
local function find_matching_paren(s, start)
  local depth = 0
  for i = start, #s do
    local c = s:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
  end
  return nil
end

--- Find the first top-level ' and ' or ' or ' operator in `s`.
--- "Top-level" means not nested inside parentheses.
--- Returns: op_start, op_end, op_kind  (1-based positions)
---   op_start = index of the leading space
---   op_end   = index of the trailing space (inclusive)
--- @param s string
--- @return integer|nil, integer|nil, string|nil
local function find_top_level_bool_op(s)
  local depth = 0
  local lower = s:lower()
  local i = 1
  while i <= #s do
    local c = s:sub(i, i)
    if c == "(" then
      depth = depth + 1
    elseif c == ")" then
      depth = depth - 1
    elseif depth == 0 then
      -- ' and ' is 5 chars
      if lower:sub(i, i + 4) == " and " then
        return i, i + 4, "and"
      end
      -- ' or ' is 4 chars
      if lower:sub(i, i + 3) == " or " then
        return i, i + 3, "or"
      end
    end
    i = i + 1
  end
  return nil, nil, nil
end

-- ── Leaf filter parser ──────────────────────────────────────────────────────

--- Parse a simple (non-boolean) filter from a lower-cased string.
--- @param s   string  lower-cased, trimmed
--- @param orig string  original-case, trimmed (for value preservation)
--- @return table|nil  filter spec table, or nil if unrecognized
local function parse_leaf_filter(s, orig)
  -- ── status ──────────────────────────────────────────────────────────────
  if s == "done" then
    return { type = "done" }
  end
  if s == "not done" then
    return { type = "not_done" }
  end

  -- status.name is <name>
  local sn_val = s:match("^status%.name is (.+)$")
  if sn_val then
    -- Preserve original case for the status name value
    local orig_val = orig:match("^[Ss]tatus%.name is (.+)$") or sn_val
    return { type = "status_name", operator = "is", value = orig_val }
  end

  -- status.type is <TYPE>  (normalised to upper-case)
  local st_val = s:match("^status%.type is (.+)$")
  if st_val then
    return { type = "status_type", operator = "is", value = st_val:upper() }
  end

  -- ── recurring ───────────────────────────────────────────────────────────
  if s == "is recurring" then
    return { type = "is_recurring" }
  end
  if s == "is not recurring" then
    return { type = "is_not_recurring" }
  end

  -- ── priority ────────────────────────────────────────────────────────────
  local pri_is = s:match("^priority is (.+)$")
  if pri_is and PRIORITY_LEVELS[pri_is] then
    return { type = "priority", operator = "is", value = pri_is }
  end

  local pri_above = s:match("^priority above (.+)$")
  if pri_above and PRIORITY_LEVELS[pri_above] then
    return { type = "priority", operator = "above", value = pri_above }
  end

  local pri_below = s:match("^priority below (.+)$")
  if pri_below and PRIORITY_LEVELS[pri_below] then
    return { type = "priority", operator = "below", value = pri_below }
  end

  local pri_not_is = s:match("^priority not is (.+)$")
  if pri_not_is and PRIORITY_LEVELS[pri_not_is] then
    return { type = "priority", operator = "not_is", value = pri_not_is }
  end

  -- ── date filters ────────────────────────────────────────────────────────
  -- Iterate longest field names first to prevent 'done' matching before 'cancelled' etc.
  for _, field in ipairs(DATE_FIELDS_LIST) do
    if s == "has " .. field .. " date" then
      return { type = "has_date", field = field }
    end
    if s == "no " .. field .. " date" then
      return { type = "no_date", field = field }
    end
    if s == field .. " date is invalid" then
      return { type = "date_invalid", field = field }
    end
    for _, op in ipairs({ "before", "after", "on", "in" }) do
      local prefix = field .. " " .. op .. " "
      if #s > #prefix and s:sub(1, #prefix) == prefix then
        local date_val = parse_date(orig:sub(#prefix + 1))
        return { type = "date", field = field, operator = op, value = date_val }
      end
    end
  end

  -- ── text field filters ───────────────────────────────────────────────────
  for _, kw in ipairs(TEXT_FIELD_KW_LIST) do
    local canonical = TEXT_FIELD_KEYWORDS[kw]
    -- '<kw> includes <val>' and '<kw> include <val>' (plural verb variant)
    for _, verb in ipairs({ kw .. " includes ", kw .. " include " }) do
      if #s > #verb and s:sub(1, #verb) == verb then
        return { type = "text", field = canonical, operator = "includes", value = orig:sub(#verb + 1) }
      end
    end
    -- '<kw> does not include <val>' and '<kw> do not include <val>'
    for _, verb in ipairs({ kw .. " does not include ", kw .. " do not include " }) do
      if #s > #verb and s:sub(1, #verb) == verb then
        return { type = "text", field = canonical, operator = "does_not_include", value = orig:sub(#verb + 1) }
      end
    end
    -- '<kw> regex matches <pat>'
    local rx_pfx = kw .. " regex matches "
    if #s > #rx_pfx and s:sub(1, #rx_pfx) == rx_pfx then
      return { type = "text", field = canonical, operator = "regex_matches", value = orig:sub(#rx_pfx + 1) }
    end
    -- '<kw> regex does not match <pat>'
    local rx_not_pfx = kw .. " regex does not match "
    if #s > #rx_not_pfx and s:sub(1, #rx_not_pfx) == rx_not_pfx then
      return { type = "text", field = canonical, operator = "regex_does_not_match", value = orig:sub(#rx_not_pfx + 1) }
    end
  end

  -- ── tag filters ─────────────────────────────────────────────────────────
  if s == "has tag" then
    return { type = "tag", operator = "has" }
  end
  if s == "no tag" then
    return { type = "tag", operator = "no" }
  end

  -- 'tag includes <val>' / 'tags include <val>' / 'tags includes <val>'
  for _, prefix in ipairs({ "tag includes ", "tags include ", "tags includes " }) do
    if #s > #prefix and s:sub(1, #prefix) == prefix then
      return { type = "tag", operator = "includes", value = orig:sub(#prefix + 1) }
    end
  end

  -- 'tag does not include <val>' / 'tags do not include <val>'
  for _, prefix in ipairs({ "tag does not include ", "tags do not include " }) do
    if #s > #prefix and s:sub(1, #prefix) == prefix then
      return { type = "tag", operator = "does_not_include", value = orig:sub(#prefix + 1) }
    end
  end

  -- ── misc filters ────────────────────────────────────────────────────────
  if s == "exclude sub-items" then
    return { type = "exclude_sub_items" }
  end

  local urg_above = s:match("^urgency above (.+)$")
  if urg_above then
    return { type = "urgency", operator = "above", value = tonumber(urg_above) or urg_above }
  end

  local urg_below = s:match("^urgency below (.+)$")
  if urg_below then
    return { type = "urgency", operator = "below", value = tonumber(urg_below) or urg_below }
  end

  if s == "random" then
    return { type = "random" }
  end

  return nil
end

-- ── Recursive filter expression parser ─────────────────────────────────────

-- Forward declaration for mutual recursion.
local parse_filter_expr

--- Parse a filter expression: boolean (and/or/not) or a simple leaf.
---
--- Syntax mirrors obsidian-tasks (vaults are portable between the two
--- implementations).  Accepts:
---   • bare leaf: `done`, `priority is high`, `tag includes #work`
---   • binary infix: `A AND B`, `A OR B` — operands need not be wrapped in
---     parens; left-associative chaining (`A AND B AND C` → ((A AND B) AND C))
---   • unary prefix: `NOT A` or `NOT (A)` — equivalent
---   • grouping: `(expr)` — strip wrapping parens; any sub-expression may be
---     wrapped to override the natural left-association
---   • case-insensitive operators: `AND`/`and`, `OR`/`or`, `NOT`/`not`
---
--- @param s string  trimmed expression string (original case)
--- @return table|nil  filter node, or nil if unrecognizable
parse_filter_expr = function(s)
  s = s:match("^%s*(.-)%s*$")
  if s == "" then
    return nil
  end

  -- ── Top-level OR / AND ────────────────────────────────────────────────
  -- Find the LAST top-level OR (lowest precedence, left-associative).  Splits
  -- the line into `left OR right`.  If no OR, look for the last top-level AND.
  -- find_top_level_bool_op already skips operators inside parens.
  --
  -- Splitting on the LAST occurrence builds a left-deep tree that matches
  -- typical infix evaluation order: `A AND B AND C` parses as `(A AND B) AND C`.
  local function find_last_op(target_kind)
    local last_start, last_end
    local i = 1
    while true do
      local op_start, op_end, op_kind = find_top_level_bool_op(s:sub(i))
      if not op_kind then
        break
      end
      if op_kind == target_kind then
        last_start = i + op_start - 1
        last_end = i + op_end - 1
      end
      i = i + op_end
    end
    return last_start, last_end
  end

  for _, op in ipairs({ "or", "and" }) do
    local op_start, op_end = find_last_op(op)
    if op_start then
      local left_str = s:sub(1, op_start - 1)
      local right_str = s:sub(op_end + 1)
      local left = parse_filter_expr(left_str)
      local right = parse_filter_expr(right_str)
      if left and right then
        return { kind = op, children = { left, right } }
      end
    end
  end

  local lower = s:lower()

  -- ── Leaf filter (tried BEFORE the unary NOT prefix) ───────────────────
  -- Known leaves like `not done`, `no due date`, `not is low`, `is not
  -- recurring` begin with "not"/"no" but are recognised as a single leaf
  -- type by the leaf parser.  We try the leaf parser first so the AST
  -- doesn't double-wrap them as kind="not" around a kind="leaf" sibling.
  local filter = parse_leaf_filter(lower, s)
  if filter then
    return { kind = "leaf", filter = filter }
  end

  -- ── NOT <expr> (with or without parens around the operand) ────────────
  if lower:sub(1, 4) == "not " then
    local rest = s:sub(5):match("^%s*(.-)%s*$")
    local child = parse_filter_expr(rest)
    if child then
      return { kind = "not", children = { child } }
    end
  end

  -- ── Wrapping parens — strip and recurse on the inner expression ──────
  -- Handles both `(filter)` and `(A AND B)` (the latter handled by the
  -- recursive call's top-level operator detection above).
  if s:sub(1, 1) == "(" then
    local close = find_matching_paren(s, 1)
    if close and close == #s then
      local inner = s:sub(2, close - 1)
      local child = parse_filter_expr(inner)
      if child then
        return child
      end
    end
  end

  return nil
end

-- ── Line-level directive parser ─────────────────────────────────────────────

--- Return true if `s` (lower-cased) is a v2 dependency filter keyword.
--- @param s string
--- @return boolean
local function is_v2_filter(s)
  if s == "is blocked" or s == "is not blocked" or s == "is blocking" or s == "is not blocking" then
    return true
  end
  if s:sub(1, 19) == "blocked by includes" then
    return true
  end
  return false
end

--- Parse one non-blank, non-comment line into the AST.  Mutates `ast`.
--- @param ast      table
--- @param line     string  original-case trimmed
--- @param line_num integer
local function parse_line(ast, line, line_num)
  local lower = line:lower()

  -- ── filter by function (unsupported scripting) ───────────────────────
  if lower:sub(1, 18) == "filter by function" then
    ast.errors[#ast.errors + 1] = {
      kind = "unsupported",
      msg = "Scripting filters not supported in nvim",
      line = line_num,
    }
    return
  end

  -- ── v2 dependency filters ────────────────────────────────────────────
  if is_v2_filter(lower) then
    ast.errors[#ast.errors + 1] = {
      kind = "v2_feature",
      msg = "Dependency filters are a v2 feature",
      line = line_num,
    }
    return
  end

  -- ── sort by [reverse] <key> ──────────────────────────────────────────
  do
    local key = lower:match("^sort by reverse (.+)$")
    if key and SORT_KEYS[key] then
      ast.sort_by[#ast.sort_by + 1] = { key = key, reverse = true }
      return
    end
    key = lower:match("^sort by (.+)$")
    if key and SORT_KEYS[key] then
      ast.sort_by[#ast.sort_by + 1] = { key = key, reverse = false }
      return
    end
  end

  -- ── group by [reverse] <key> ─────────────────────────────────────────
  do
    local key = lower:match("^group by reverse (.+)$")
    if key and GROUP_KEYS[key] then
      ast.group_by[#ast.group_by + 1] = { key = key, reverse = true }
      return
    end
    key = lower:match("^group by (.+)$")
    if key and GROUP_KEYS[key] then
      ast.group_by[#ast.group_by + 1] = { key = key, reverse = false }
      return
    end
  end

  -- ── hide <subkey> ────────────────────────────────────────────────────
  do
    local subkey = lower:match("^hide (.+)$")
    if subkey and HIDE_KEYS[subkey] then
      ast.hide[#ast.hide + 1] = subkey
      return
    end
  end

  -- ── limit <N> ────────────────────────────────────────────────────────
  do
    local n = lower:match("^limit (%d+)$")
    if n then
      ast.limit = tonumber(n)
      return
    end
  end

  -- ── filter expression (leaf or boolean) ──────────────────────────────
  local node = parse_filter_expr(line)
  if node then
    ast.filters[#ast.filters + 1] = node
    return
  end

  -- ── unknown directive → structured parse error ───────────────────────
  ast.errors[#ast.errors + 1] = {
    kind = "parse_error",
    msg = "Unknown query directive: " .. line,
    line = line_num,
  }
end

-- ── Public API ───────────────────────────────────────────────────────────────

--- Parse a query block string into an AST.
---
--- @param query_text string  newline-separated query block contents
--- @return table  { filters, sort_by, group_by, limit, hide, errors }
function M.parse(query_text)
  local ast = {
    filters = {},
    sort_by = {},
    group_by = {},
    limit = nil,
    hide = {},
    errors = {},
  }

  if not query_text or query_text == "" then
    return ast
  end

  local lines = vim.split(query_text, "\n", { plain = true })
  for line_num, line in ipairs(lines) do
    local trimmed = line:match("^%s*(.-)%s*$")
    -- Skip blank lines and comment lines (starting with '#')
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      parse_line(ast, trimmed, line_num)
    end
  end

  return ast
end

return M
