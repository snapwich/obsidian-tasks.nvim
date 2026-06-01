-- lua/obsidian-tasks/index/nodes.lua
-- Unified per-file node parser.
--
-- Full-reads a markdown file (or a list of lines) and produces a flat,
-- line-ordered list of NODES describing the document's list structure.  This
-- replaces the two former task-only parsers (index/scan.lua's inline rg parse
-- and index/init.lua's parse_file) with one source of truth.
--
-- Node kinds:
--   task   — a list item WITH a checkbox (`- [ ] …`); carries the parsed Task
--            (via task/parse.lua) and the nearest preceding ATX heading.
--   bullet — a list item WITHOUT a checkbox (`-`/`*`/`+` marker); a description
--            line.  Carries the trimmed body text PLUS enough to reconstruct the
--            source line byte-for-byte: `marker` (one of `-`/`*`/`+`, the literal
--            list marker) and `indent` (the raw leading-whitespace string).
--            (Tasks already carry `.indent` on their parsed Task; bullets mirror
--            that here so Phase-5 edit-through can round-trip the original marker
--            and indent.)
--   blank  — an empty / whitespace-only line.  Preserved so a subtree's
--            interspersed blanks ride along during rendering (later phase).
--
-- Non-list prose lines that are not tasks/bullets/blank are NOT nodes (they are
-- never descriptions in the round-trip-safe nested-list form) and are omitted.
-- ATX heading lines are likewise not nodes — they update the running heading
-- that gets attached to task nodes (heading is a separate axis, not hierarchy).
--
-- Structure axes (independent):
--   depth       — numeric indent level (0 = top-level), derived from leading
--                 whitespace and clamped so a line is at most one level deeper
--                 than the nearest node above it (no level-skipping).
--   parent_line — line_num of the nearest shallower node above (nil at top).
--   kind        — task vs bullet vs blank (the marker axis).
--
-- TREE CONTRACT (well-formedness guarantees on the returned list):
--   * parent_line ALWAYS references a node that is PRESENT in the returned list
--     (or is nil for a top-level node).  It never dangles to an omitted line —
--     not a prose line, and not a task vetoed by on_task.
--   * depth is contiguous: a node's depth is exactly its parent's depth + 1
--     (or 0 when parent_line is nil).  There are no depth gaps.
--   When on_task vetoes a task, that line is omitted from the list AND removed
--   from the indent stack, so its descendants re-parent to the nearest KEPT
--   ancestor (becoming top-level if every ancestor was vetoed).  A heading also
--   flushes the indent stack (see below), so no subtree spans a heading.
--
-- Node shapes:
--   { kind = "task",   line_num, depth, parent_line, task = <Task>, heading? }
--   { kind = "bullet", line_num, depth, parent_line, text = <string>,
--                      marker = <"-"|"*"|"+">, indent = <string>,
--                      source_line = <string> (verbatim on-disk line) }
--   { kind = "blank",  line_num }

local M = {}

-- A list item: optional indent, then a `-`/`*`/`+` marker followed by a space
-- (or end-of-line).  The body capture is everything after the marker+space.
local LIST_PAT = "^(%s*)([-*+])%s(.*)$"
-- A marker on its own line ("-", "  *") with no trailing space/body.
local LIST_BARE_PAT = "^(%s*)([-*+])%s*$"

--- Compute the indent "width" of a leading-whitespace string, expanding tabs to
--- the next multiple of 4 columns (matches common Markdown list nesting).
--- @param ws string  leading whitespace
--- @return integer  column width
local function indent_width(ws)
  local width = 0
  for i = 1, #ws do
    if ws:sub(i, i) == "\t" then
      width = width + (4 - (width % 4))
    else
      width = width + 1
    end
  end
  return width
end

--- Parse a list of *lines* into a node list.
---
--- *opts* (all optional):
---   heading    — require("obsidian-tasks.index.heading") (injectable for tests)
---   parse      — require("obsidian-tasks.task.parse")     (injectable for tests)
---   on_task    — fun(task)  hook to post-process / veto a task node.  Return
---                false to DROP the task (used for global_filter).  Mutating the
---                task in place (e.g. DateFallback) is allowed.
---
--- @param lines string[]
--- @param opts  table|nil
--- @return table[]  ordered node list
function M.parse_lines(lines, opts)
  opts = opts or {}
  local heading = opts.heading or require("obsidian-tasks.index.heading")
  local parse = opts.parse or require("obsidian-tasks.task.parse")
  local on_task = opts.on_task

  local nodes = {}
  local current_heading = nil

  -- Indent stack of { width, line_num } for resolving parent_line.  The parent
  -- of a node is the nearest node above it with a strictly smaller indent
  -- width.  Depth is the stack size at insertion (after popping deeper entries),
  -- which inherently applies the no-skip clamp: a node can be at most one level
  -- deeper than its resolved parent.
  local stack = {}

  for i, raw in ipairs(lines) do
    local line = raw:gsub("\r$", "")
    local line_num = i

    -- ── blank ───────────────────────────────────────────────────────────────
    if line:match("^%s*$") then
      nodes[#nodes + 1] = { kind = "blank", line_num = line_num }
    else
      -- ── heading (separate axis; not a node) ────────────────────────────────
      local h = heading.parse(line)
      if h ~= nil then
        current_heading = h
        -- A heading is a structural break: flush the indent stack so the next
        -- list item starts fresh at top-level.  No subtree spans a heading.
        stack = {}
      else
        -- ── list item? ───────────────────────────────────────────────────────
        local ws, marker, body = line:match(LIST_PAT)
        if ws == nil then
          ws, marker = line:match(LIST_BARE_PAT)
          if ws ~= nil then
            body = ""
          end
        end

        if ws ~= nil then
          local width = indent_width(ws)

          -- Resolve parent: pop stack entries whose indent is >= this line's.
          while #stack > 0 and stack[#stack].width >= width do
            stack[#stack] = nil
          end
          local parent_line = (#stack > 0) and stack[#stack].line_num or nil
          local depth = #stack -- clamp: at most one deeper than parent

          -- Classify by marker axis: checkbox => task, else bullet.
          local task = parse.parse(line)
          if task ~= nil then
            task.heading = current_heading
            local keep = true
            if on_task then
              keep = on_task(task) ~= false
            end
            if keep then
              nodes[#nodes + 1] = {
                kind = "task",
                line_num = line_num,
                depth = depth,
                parent_line = parent_line,
                task = task,
                heading = current_heading,
              }
              -- Push the KEPT task so descendants resolve to it.
              stack[#stack + 1] = { width = width, line_num = line_num }
            end
            -- A vetoed task is NOT pushed onto the stack: descendants must
            -- re-parent to the nearest KEPT ancestor (well-formedness contract),
            -- not dangle to this omitted line.
          else
            nodes[#nodes + 1] = {
              kind = "bullet",
              line_num = line_num,
              depth = depth,
              parent_line = parent_line,
              text = vim.trim(body or ""),
              -- Round-trip metadata (Phase 5a): the literal list marker and the
              -- raw leading-whitespace indent, so edit-through can reconstruct
              -- the source line exactly (marker + indent are NOT derivable from
              -- the trimmed body / numeric depth).
              marker = marker,
              indent = ws,
              -- The VERBATIM on-disk line (after the same trailing-\r strip the
              -- node parser applies to every line, matching vim.fn.readfile on
              -- LF files).  Tasks carry task.raw_line for this; bullets mirror it
              -- here so drift/locate compares against the EXACT disk line rather
              -- than a trimmed reconstruction.  Without this, a bullet whose disk
              -- line has trailing spaces or multiple post-marker spaces fails
              -- M.locate's exact match → its edit/delete is silently dropped.
              source_line = line,
            }
            stack[#stack + 1] = { width = width, line_num = line_num }
          end
        end
        -- else: non-list prose — omitted (never a node).
      end
    end
  end

  return nodes
end

--- Full-read the file at *abs_path* into a list of lines, applying the
--- file-size guard (*max_bytes*) via fs_stat before reading.
---
--- Returns nil on read error / oversize file (callers treat nil as "no nodes").
--- This is the SINGLE disk read shared by the indexer's ignore check and node
--- parse — read once, derive both frontmatter and nodes from the same lines.
---
--- @param abs_path string
--- @param max_bytes integer|nil  skip files larger than this (default: no limit)
--- @return string[]|nil  the file's lines, or nil on error / oversize
function M.read_lines(abs_path, max_bytes)
  if max_bytes then
    local stat = vim.uv.fs_stat(abs_path)
    if stat == nil or stat.size > max_bytes then
      return nil
    end
  end

  local lines = {}
  local ok = pcall(function()
    local f = io.open(abs_path, "r")
    if not f then
      error("cannot open file")
    end
    for line in f:lines() do
      lines[#lines + 1] = line
    end
    f:close()
  end)
  if not ok then
    return nil
  end

  return lines
end

--- Full-read the file at *abs_path* and parse it into nodes.
---
--- Applies the file-size guard (*opts.max_bytes*) via fs_stat before reading.
--- Returns an empty list on read error / oversize file.
---
--- @param abs_path string
--- @param opts     table|nil  same as parse_lines, plus:
---   max_bytes — integer  skip files larger than this (default: no limit)
--- @return table[]  node list
function M.parse_file(abs_path, opts)
  opts = opts or {}
  local lines = M.read_lines(abs_path, opts.max_bytes)
  if lines == nil then
    return {}
  end
  return M.parse_lines(lines, opts)
end

--- Filter a node list to its task nodes, in line order.
--- @param nodes table[]
--- @return table[]  the kind=="task" subset (same node objects)
function M.tasks(nodes)
  local out = {}
  for _, n in ipairs(nodes) do
    if n.kind == "task" then
      out[#out + 1] = n
    end
  end
  return out
end

return M
