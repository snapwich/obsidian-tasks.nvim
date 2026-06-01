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

-- ── Numbered date-range shorthands ──────────────────────────────────────────
-- Upstream-compatible query shorthands that expand to an inclusive [start,end]
-- ISO range: year (`2024`), month (`2024-01`), quarter (`2024-Q1`), ISO week
-- (`2024-W09`).  Query-filter-only — a task LINE still stores a concrete date,
-- so these never reach task/parse.lua or task/serialize.lua.

--- Inclusive Monday..Sunday ISO-8601 week range, as YYYY-MM-DD strings.
--- ISO 8601: weeks start Monday; week 1 is the week containing the year's
--- first Thursday.  Jan 4 is always in week 1, so we anchor on it and let
--- os.time normalise day-of-month overflow into adjacent months/years (this
--- also yields the correct cross-year span for W53 / W01).
--- @param year integer  ISO week-year
--- @param week integer  1..53
--- @return string monday_iso
--- @return string sunday_iso
local function iso_week_range(year, week)
  local jan4 = os.time({ year = year, month = 1, day = 4, hour = 12 })
  -- os.date wday is Sun=1..Sat=7; convert to ISO weekday Mon=1..Sun=7.
  local iso_wday = (os.date("*t", jan4).wday + 5) % 7 + 1
  -- Day-of-January for Monday of the requested week.  May be ≤0 or >31;
  -- os.time normalises it into the correct month/year.
  local monday_day = 4 - (iso_wday - 1) + (week - 1) * 7
  local monday = os.time({ year = year, month = 1, day = monday_day, hour = 12 })
  local sunday = os.time({ year = year, month = 1, day = monday_day + 6, hour = 12 })
  local monday_iso = os.date("%Y-%m-%d", monday) --[[@as string]]
  local sunday_iso = os.date("%Y-%m-%d", sunday) --[[@as string]]
  return monday_iso, sunday_iso
end

--- Expand a numbered date-range shorthand to an inclusive [start,end] ISO pair.
--- Disambiguates purely by structure; returns nil for anything that is not a
--- recognised shorthand (including bare YYYY-MM-DD point dates).
--- @param s string  trimmed candidate
--- @return string|nil start_iso
--- @return string|nil end_iso
local function expand_period(s)
  -- Year: `2024`
  local y = s:match("^(%d%d%d%d)$")
  if y then
    return y .. "-01-01", y .. "-12-31"
  end
  -- ISO week: `2024-W09`
  local wy, ww = s:match("^(%d%d%d%d)%-[Ww](%d%d)$")
  if wy then
    local week = tonumber(ww)
    if week and week >= 1 and week <= 53 then
      return iso_week_range(tonumber(wy), week)
    end
    return nil
  end
  -- Quarter: `2024-Q1`
  local qy, qq = s:match("^(%d%d%d%d)%-[Qq](%d)$")
  if qy then
    local q = tonumber(qq)
    if q and q >= 1 and q <= 4 then
      local first_month = (q - 1) * 3 + 1
      -- Last day of the quarter: day 0 of the month after the quarter ends.
      local last_t = os.time({ year = tonumber(qy), month = first_month + 3, day = 0, hour = 12 })
      local last_iso = os.date("%Y-%m-%d", last_t) --[[@as string]]
      return string.format("%s-%02d-01", qy, first_month), last_iso
    end
    return nil
  end
  -- Month: `2024-01`
  local my, mm = s:match("^(%d%d%d%d)%-(%d%d)$")
  if my then
    local m = tonumber(mm)
    if m and m >= 1 and m <= 12 then
      -- Last day of month: day 0 of the following month.
      local last_t = os.time({ year = tonumber(my), month = m + 1, day = 0, hour = 12 })
      local last_iso = os.date("%Y-%m-%d", last_t) --[[@as string]]
      return my .. "-" .. mm .. "-01", last_iso
    end
    return nil
  end
  return nil
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
  random = true,
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
  random = true,
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
  ["edit button"] = true,
  ["postpone button"] = true,
}

--- `show <key>` / `hide <key>` toggle keys.  Both `show tree` and `hide tree`
--- drive the SAME boolean (ast.tree); `tree` is intentionally NOT in HIDE_KEYS
--- so `hide tree` is handled as a tree toggle (not a generic hide subkey that
--- would leak a `tree` hide flag).  Only `tree` is recognised for now —
--- `show urgency` and other toggles are deferred and error like unknown keys.
local SHOW_KEYS = {
  ["tree"] = true,
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

  -- ── dependency filters ─────────────────────────────────────────────────
  if s == "is blocking" then
    return { type = "is_blocking" }
  end
  if s == "is not blocking" then
    return { type = "is_not_blocking" }
  end
  if s == "is blocked" then
    return { type = "is_blocked" }
  end
  if s == "is not blocked" then
    return { type = "is_not_blocked" }
  end
  do
    local id_val = s:match("^id is (.+)$")
    if id_val then
      return { type = "id_is", value = id_val }
    end
    local dep_val = s:match("^depends on (.+)$")
    if dep_val then
      return { type = "depends_on", value = dep_val }
    end
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
    -- Operator list is ordered longest-first so the multi-word `on or before`
    -- / `on or after` match BEFORE the single-word `on` does.  Operator
    -- canonical names use underscores so the filter dispatcher can switch on
    -- them safely.
    local ops = {
      { syntax = "on or before", canon = "on_or_before" },
      { syntax = "on or after", canon = "on_or_after" },
      { syntax = "before", canon = "before" },
      { syntax = "after", canon = "after" },
      { syntax = "on", canon = "on" },
      { syntax = "in", canon = "in" },
    }
    for _, op in ipairs(ops) do
      local prefix = field .. " " .. op.syntax .. " "
      if #s > #prefix and s:sub(1, #prefix) == prefix then
        local raw = orig:sub(#prefix + 1):match("^%s*(.-)%s*$")
        -- Two-date range: `due in 2024-01-01 2024-02-01` — `in` / `on` /
        -- `before` / `after` / `on or before` / `on or after` all accept a
        -- second date as the range upper-bound when followed by space + ISO.
        local d1, d2 = raw:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d%d%d%-%d%d%-%d%d)$")
        if d1 and d2 then
          return {
            type = "date",
            field = field,
            operator = op.canon,
            value = d1,
            value_end = d2,
          }
        end
        -- Numbered date-range shorthand (`due before 2024-W09`): the operator
        -- composes with the expanded [start,end] range in filter.lua.
        local p_start, p_end = expand_period(raw)
        if p_start then
          return {
            type = "date",
            field = field,
            operator = op.canon,
            value = p_start,
            value_end = p_end,
          }
        end
        local date_val = parse_date(raw)
        return { type = "date", field = field, operator = op.canon, value = date_val }
      end
    end
    -- ── Period shortcuts: `<field> 2024`, `<field> 2024-03`, `<field>
    --    2024-Q1`, `<field> 2024-W09` ─────────────────────────────────────
    -- The implicit "in" form: no operator, the value is a numbered date range.
    local prefix_bare = field .. " "
    if #s > #prefix_bare and s:sub(1, #prefix_bare) == prefix_bare then
      local rest = orig:sub(#prefix_bare + 1):match("^%s*(.-)%s*$")
      -- Year / month / quarter / ISO week.
      local p_start, p_end = expand_period(rest)
      if p_start then
        return {
          type = "date",
          field = field,
          operator = "in",
          value = p_start,
          value_end = p_end,
        }
      end
      -- Bare two-date range without operator (`due 2024-01-01 2024-02-01`).
      local rd1, rd2 = rest:match("^(%d%d%d%d%-%d%d%-%d%d)%s+(%d%d%d%d%-%d%d%-%d%d)$")
      if rd1 and rd2 then
        return {
          type = "date",
          field = field,
          operator = "in",
          value = rd1,
          value_end = rd2,
        }
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

  -- ── sort by <key> [reverse] ──────────────────────────────────────────
  -- Trailing `reverse` keyword, matching obsidian-tasks (`sort by due reverse`).
  do
    local key = lower:match("^sort by (.+) reverse$")
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

  -- ── group by <key> [reverse] ─────────────────────────────────────────
  do
    local key = lower:match("^group by (.+) reverse$")
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

  -- ── show <key> / hide <key> toggles (tree) ───────────────────────────
  -- `show tree` opts INTO the tree (default flat); `hide tree` is the explicit
  -- default-off (upstream parity).  Both drive ast.tree — last directive wins.
  -- Handled BEFORE the generic `hide <subkey>` so `hide tree` is the toggle,
  -- not a hide-list entry.  Unknown show/hide keys fall through to the generic
  -- hide handler (for hide) or the unknown-directive error (for show).
  do
    local show_key = lower:match("^show (.+)$")
    if show_key then
      if SHOW_KEYS[show_key] then
        if show_key == "tree" then
          ast.tree = true
        end
        return
      end
      -- Unknown show key (e.g. `show urgency`): deferred → structured error,
      -- consistent with an unknown `hide <key>`.
      ast.errors[#ast.errors + 1] = {
        kind = "parse_error",
        msg = "Unknown query directive: " .. line,
        line = line_num,
      }
      return
    end
    local hide_toggle = lower:match("^hide (.+)$")
    if hide_toggle == "tree" then
      ast.tree = false
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

  -- ── explain ──────────────────────────────────────────────────────────
  -- Flag the AST so the renderer can prepend a human-readable summary of
  -- the parsed query to the result list.  Matches upstream's `explain`
  -- keyword.
  if lower == "explain" then
    ast.explain = true
    return
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
    explain = false,
    -- Tree membership (Phase 2): `show tree` opts IN, default FLAT.  `hide
    -- tree` re-disables (upstream parity).  Drives query/tree.lua assembly.
    tree = false,
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
