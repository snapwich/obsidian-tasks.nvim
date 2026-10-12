-- lua/obsidian-tasks/render/group_top_write.lua
-- The group-top write path (plan D3–D9, ADR 0005).
--
-- A task typed or pasted in a group-top slot has no anchor: the managed rows
-- above it belong to the previous group.  So it goes to today's daily note (or,
-- for a filename group, to that file), at the place that keeps it in the group
-- where the user typed it.  render/edit_insert.lua calls M.write for:
--   • a group-top block (the rows below a group header that on_lines moved up,
--     see render/group_top.lua), and
--   • a no-anchor block in an ungrouped or zero-result dashboard.
--
-- Target, by group key (M.target reads the STRUCTURED group segments, never a
-- " / " split of the joined group name — a heading can contain " / "):
--
--   heading                  → daily note, in that heading's section
--   (No heading)             → daily note, before the first heading
--   tags / priority / status → daily note, end of file + group attribute (P9)
--   filename                 → the end of that file (task B's source note)
--   folder / path / root     → below-fence fallback + warning (the daily note
--                              would put the task in a different group)
--   other keys (dates, …)    → below-fence fallback + warning
--   ungrouped / zero-result  → daily note, end of file
--   multi-level              → what each level contributes; a filename level
--                              wins over the daily note
--
-- Write conditions (plan D8): one count = 0 apply_source_edit (one contiguous
-- write, one undo entry; undo removes only the written lines and never deletes
-- a note we created).  A target open with unsaved changes is refused: the
-- caller reverts the typed rows.

local M = {}

local edit_util = require("obsidian-tasks.render.edit_util")
local md_structure = require("obsidian-tasks.util.md_structure")

-- Location keys that only a filename level can satisfy (see M.target).
local LOCATION_KEYS = { folder = true, path = true, root = true }

local FALLBACK_TAIL = " — kept below the dashboard; move it where it belongs"

-- ── Pure parts ────────────────────────────────────────────────────────────────

--- Where a group-top insert goes, from the block's group_by directives and the
--- group's per-key segments.
---
--- Result:
---   kind       "daily" | "file" | "fallback"
---   in_section true → place in the *heading* section (note_placement.place);
---              false → end of file (note_placement.append)
---   heading    the section heading text; nil with in_section = "(No heading)"
---   attrs      group_attr context for the ROOT tasks ({ by, value } list)
---   reason     the group key that forces the fallback
---
--- @param group_by table[]   { { key, reverse }, … }
--- @param segments string[]  one segment per group_by level
--- @return table
function M.target(group_by, segments)
  local t = { kind = "daily", in_section = false, heading = nil, attrs = {} }
  local has_filename = false
  local location = nil
  for i, directive in ipairs(group_by or {}) do
    local key = directive.key
    local seg = (segments and segments[i]) or ""
    if key == "heading" then
      t.in_section = true
      t.heading = (seg ~= "(No heading)") and seg or nil
    elseif key == "filename" then
      has_filename = true
    elseif LOCATION_KEYS[key] then
      location = location or key
    elseif key == "tags" then
      -- "No tags" has no attribute to add.
      local tag = seg:match("^#(.+)$")
      if tag then
        t.attrs[#t.attrs + 1] = { by = "tag", value = tag }
      end
    elseif key == "priority" then
      -- "Priority 2: High" → "high" (same reverse-parse as the anchored path).
      local level = seg:match("Priority %d+: (%a+)$") or seg
      t.attrs[#t.attrs + 1] = { by = "priority", value = level:lower() }
    elseif key == "status" then
      t.attrs[#t.attrs + 1] = { by = "status", value = seg }
    else
      return { kind = "fallback", reason = key, attrs = {} }
    end
  end
  if has_filename then
    -- Task B's own file satisfies every location key (folder, path, root).
    t.kind = "file"
  elseif location then
    return { kind = "fallback", reason = location, attrs = {} }
  end
  return t
end

--- The source lines for a group-top block (plan D7).
---
--- Flat dashboard: every line is a top-level task (the flat insert rule).
--- `show tree` dashboard: the two-pass block model (render/insert_block.lua)
--- with no rows above, so the block keeps its relative indentation and every
--- block root is clamped to depth 0.  A root description bullet is written as
--- typed and flagged (it does not show in the dashboard).
---
--- Group attributes go on ROOT tasks only (descendants come in by subtree
--- drag).  The global filter goes on EVERY task line: the index drops a child
--- task without it (plan D6).
---
--- @param block_lines string[]  typed / pasted lines, top→bottom
--- @param opts table  { tree = boolean, attrs = table, global_filter = string|nil }
--- @return table  { lines = string[], first_task = integer|nil, root_description = boolean }
---   first_task: index in *lines* of the first root task (else the first task)
function M.build_lines(block_lines, opts)
  local group_attr = require("obsidian-tasks.render.group_attr")
  local attrs = opts.attrs or {}

  local function task_line(indent, raw, is_root)
    local body = (edit_util.repair_prefix(raw))
    body = edit_util.normalize_date_fields(body)
    if is_root then
      body = group_attr.inject_group_attributes(body, attrs, nil)
    end
    body = edit_util.ensure_global_filter(body, opts.global_filter)
    return indent .. body
  end

  local out = {}
  if not opts.tree then
    for i, l in ipairs(block_lines) do
      out[i] = task_line("", l:match("^%s*(.*)"), true)
    end
    return { lines = out, first_task = (#out > 0) and 1 or nil, root_description = false }
  end

  local records = require("obsidian-tasks.render.insert_block").resolve(block_lines, {})
  local indent = {} -- per record: the computed source indent
  local first_root_task, first_task = nil, nil
  local root_description = false
  for i, rec in ipairs(records) do
    -- With no rows above, a record is either a block root (parent nil, or an
    -- "above" parent that does not exist) or a child of an earlier block line.
    local is_root = rec.parent == nil or rec.parent.scope ~= "block"
    indent[i] = is_root and "" or ((indent[rec.parent.index] or "") .. "  ")
    if rec.kind == "description" then
      out[i] = indent[i] .. (rec.marker or "-") .. " " .. (rec.body or "")
      root_description = root_description or is_root
    else
      out[i] = task_line(indent[i], rec.body or "", is_root)
      first_task = first_task or i
      if is_root then
        first_root_task = first_root_task or i
      end
    end
  end
  return { lines = out, first_task = first_root_task or first_task, root_description = root_description }
end

--- Level of the nearest heading at or above 0-indexed *row* in *lines*, when
--- its text is *text* (the heading task B really sits under); else nil.  A `#`
--- line in a code fence or in the frontmatter is not a heading (the indexer's
--- rule, util/md_structure.lua).
---
--- @param lines string[]
--- @param row   integer
--- @param text  string
--- @return integer|nil
function M.heading_level(lines, row, text)
  local st = md_structure.scan(lines)
  for r = math.min(row, #lines - 1), 0, -1 do
    local h = st.heading(r + 1)
    if h ~= nil then
      if h == text then
        return #lines[r + 1]:match("^(#+)")
      end
      return nil
    end
  end
  return nil
end

-- ── Effectful parts ───────────────────────────────────────────────────────────

--- Level of the LAST heading with *text* in *lines* (the one placement uses).
--- @return integer|nil
local function last_heading_level(lines, text)
  local st = md_structure.scan(lines)
  local level = nil
  for i, line in ipairs(lines) do
    if st.heading(i) == text then
      level = #line:match("^(#+)")
    end
  end
  return level
end

--- Create the missing note at *path* (plan D5).  The obsidian.nvim daily note
--- is written by obsidian.nvim so its template and frontmatter apply; any other
--- path (a custom resolver) becomes an empty file.
---
--- @param path string  normalized absolute path
--- @param date integer os.time() value the path was resolved for
--- @return boolean ok
local function create_note(path, date)
  if type(Obsidian) == "table" then
    local ok = pcall(function()
      local daily = require("obsidian.daily")
      if vim.fs.normalize(tostring((daily.daily_note_path(date)))) ~= path then
        error("not the obsidian.nvim daily note")
      end
      local note = daily.daily and daily.daily({ date = date }) or daily.today()
      local template = Obsidian.opts and Obsidian.opts.daily_notes and Obsidian.opts.daily_notes.template
      note:write({ template = template })
    end)
    if ok and vim.fn.filereadable(path) == 1 then
      return true
    end
  end
  pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  local ok = pcall(vim.fn.writefile, {}, path)
  return ok and vim.fn.filereadable(path) == 1
end

--- Workspace root prefix ("…/vault/") of the dashboard, or nil.
local function root_prefix(bufnr)
  local ws = require("obsidian-tasks.render.revert").workspace(bufnr)
  if ws == nil then
    ws = require("obsidian-tasks.util.obsidian").workspace_for_path(vim.api.nvim_buf_get_name(bufnr))
  end
  if not ws or not ws.root then
    return nil
  end
  local root = vim.fs.normalize(tostring(ws.root))
  return root:sub(-1) == "/" and root or (root .. "/")
end

--- *path* relative to the vault root, or nil when it is outside the vault.
local function vault_relative(prefix, path)
  if prefix and path:sub(1, #prefix) == prefix then
    return path:sub(#prefix + 1)
  end
  return nil
end

--- A short name for one top-level filter node, for the "hides it" warning.
local function filter_label(node)
  if node.kind == "leaf" and node.filter then
    local name = node.filter.field or node.filter.type or "query"
    return (tostring(name):gsub("_", " ")) .. " filter"
  end
  return "boolean filter"
end

--- Why the query of *blk* hides the task at *path*:*src_line*, or nil when it
--- shows it.  Runs the query filters on the task as the index now has it
--- (heading, global filter and filename date included), at its vault-relative
--- path — the same inputs query/run.lua uses.
local function hidden_reason(blk, prefix, path, src_line)
  local rel = path
  if prefix then
    rel = vault_relative(prefix, path)
    if rel == nil then
      return "outside the vault"
    end
  end
  local task = nil
  for _, n in ipairs(require("obsidian-tasks.index").nodes_for(path) or {}) do
    if n.kind == "task" and n.line_num == src_line then
      task = n.task
      break
    end
  end
  if task == nil then
    return "global filter"
  end
  local filter_mod = require("obsidian-tasks.query.filter")
  for _, node in ipairs(blk.filters or {}) do
    local ok, pass = pcall(function()
      return filter_mod.compile(node)(task, rel)
    end)
    if ok and not pass then
      return filter_label(node)
    end
  end
  return nil
end

--- Write one group-top block to its target note.
---
--- @param bufnr integer  dashboard buffer
--- @param block table[]  { {row, new_text}, … } contiguous typed / pasted rows
--- @param ctx   table    { blk = block state, group_name = string|nil,
---                         b_meta = meta of task B (the first task of the
---                         group, below the slot) | nil, ungrouped = boolean }
--- @return "written"|"fallback"|"failed" outcome
--- @return string|nil  warning for the fallback (nil = the default no-anchor one)
function M.write(bufnr, block, ctx)
  local log = require("obsidian-tasks.log")
  local cmd = require("obsidian-tasks.cmd")
  local placement = require("obsidian-tasks.render.note_placement")
  local blk = ctx.blk or {}

  -- 1. Target from the structured group segments.
  local group_by = ctx.ungrouped and {} or (blk.group_by or {})
  local segments = {}
  if #group_by > 0 then
    segments = (blk.group_segments or {})[ctx.group_name or ""]
    if segments == nil then
      -- A group the last run did not produce (a linger-only group): split the
      -- name only when the split is unambiguous.
      segments = vim.split(ctx.group_name or "", " / ", { plain = true })
      if #segments ~= #group_by then
        return "fallback", nil
      end
    end
  end
  local target = M.target(group_by, segments)
  if target.kind == "fallback" then
    return "fallback",
      ("group by %s: a new task at the top of a group has no note to go to"):format(target.reason) .. FALLBACK_TAIL
  end

  -- 2. Target path.
  local date = os.time()
  local path
  if target.kind == "file" then
    path = ctx.b_meta and ctx.b_meta.source_file
  else
    path = require("obsidian-tasks.util.daily_note").resolve(date)
  end
  if path == nil or path == "" then
    return "fallback", nil
  end
  path = vim.fs.normalize(path)
  local prefix = root_prefix(bufnr)
  local shown = vault_relative(prefix, path) or vim.fn.fnamemodify(path, ":~")

  -- 3. Write conditions.  The dashboard's own note keeps its buffer
  -- authoritative (rendered rows are not on disk), and apply_source_edit cannot
  -- map a source row into another dashboard's rendered buffer: keep the line.
  if path == vim.fs.normalize(vim.api.nvim_buf_get_name(bufnr)) then
    -- Name the real target: a filename group's file can be this note too.
    local what = (target.kind == "file") and shown or "the daily note"
    return "fallback", what .. " is this dashboard" .. FALLBACK_TAIL
  end
  local loaded = cmd._loaded_source_buf(path)
  if loaded and vim.b[loaded].obsidian_tasks_dashboard then
    return "fallback", shown .. " is open as a dashboard" .. FALLBACK_TAIL
  end
  if loaded and vim.bo[loaded].modified then
    log.warn(shown .. " has unsaved changes — save it and retry")
    return "failed"
  end

  -- 4. Lines to write.
  local block_lines = {}
  for i, ir in ipairs(block) do
    block_lines[i] = ir.new_text
  end
  local plugin_opts = require("obsidian-tasks").opts or {}
  local built = M.build_lines(block_lines, {
    tree = blk.tree or false,
    attrs = target.attrs,
    global_filter = plugin_opts.global_filter,
  })

  -- 5. A missing note is created first; undo never deletes it (plan D8).
  local created_note = false
  if vim.fn.filereadable(path) == 0 then
    if not create_note(path, date) then
      return "fallback", "could not create " .. shown .. FALLBACK_TAIL
    end
    created_note = true
  end
  local ok_r, lines = pcall(vim.fn.readfile, path)
  if not ok_r or type(lines) ~= "table" then
    return "fallback", "could not read " .. shown .. FALLBACK_TAIL
  end

  -- 6. Placement.  A heading we create copies the level of task B's real
  -- heading line (walk up from B's source row), else "##".
  local placed
  if target.in_section then
    local level = nil
    if target.heading and ctx.b_meta and ctx.b_meta.source_file and ctx.b_meta.source_row then
      local ok_b, b_lines = pcall(vim.fn.readfile, ctx.b_meta.source_file)
      if ok_b and type(b_lines) == "table" then
        level = M.heading_level(b_lines, ctx.b_meta.source_row, target.heading)
      end
    end
    placed = placement.place(lines, target.heading, level, built.lines)
    if target.heading then
      local shown_level = placed.created_heading and (level or 2) or last_heading_level(lines, target.heading) or 2
      shown = shown .. " › " .. string.rep("#", shown_level) .. " " .. target.heading
    else
      shown = shown .. " › (No heading)"
    end
  else
    placed = placement.append(lines, built.lines)
  end

  -- 7. One contiguous write: one undo entry, disk authoritative.
  local ok = cmd.apply_source_edit(path, placed.row, placed.lines_to_insert, { count = 0, dashboard_bufnr = bufnr })
  if not ok then
    return "failed"
  end

  -- 8. A new note is in neither the index nor the reverse index: index it now,
  -- before the caller's rerender re-runs the query.
  pcall(function()
    local index = require("obsidian-tasks.index")
    index.invalidate(path)
    index.refresh_file(path)
  end)

  -- 9. UX (plan D9): the cursor follows the new task after the rerender, and
  -- one message says where it went.
  local where = shown .. ((created_note or placed.created_heading) and " (created)" or "")
  local src_line = nil
  if built.first_task then
    local offset = 0
    for i, l in ipairs(placed.lines_to_insert) do
      if l == built.lines[1] then
        offset = i - 1
        break
      end
    end
    src_line = placed.row + offset + built.first_task
    require("obsidian-tasks.render.cursor").follow_next(bufnr, { src_path = path, src_line = src_line })
  end
  local hidden = src_line and hidden_reason(blk, prefix, path, src_line) or nil
  if hidden then
    log.warn("added to " .. where .. ", but this query hides it (" .. hidden .. ")")
  else
    log.info("added to " .. where)
  end
  if built.root_description then
    log.warn("a description bullet at the top of a group does not show in the dashboard")
  end
  return "written"
end

return M
