-- tests/integration_real/test_harden_group_sync_real.lua
-- HARDENING (dimension: group_sync) — grouping / duplicates / live-sync /
-- filtering interactions, driven through REAL keypresses (child nvim +
-- type_keys), mirroring test_real_dup_group_sync / test_real_tree_group_attr.
--
-- Every case here boots a file-backed dashboard whose source is re-read on each
-- index.tasks_in call, so a post-edit refresh re-queries / re-groups against the
-- updated source.  Assertions run WITHOUT :w (the has_mutate_applied gate must
-- fire a canonical rerender on InsertLeave / normal-mode flush).

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── shared child helpers ───────────────────────────────────────────────────────

local function buflines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")
end

--- Count dashboard rows whose text contains *needle* (substring match).
local function count_rows(child, needle)
  return child.lua_get(string.format(
    [[(function()
        local n = 0
        for _, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
          if l and l:find(%q, 1, true) then n = n + 1 end
        end
        return n
      end)()]],
    needle
  ))
end

--- 0-indexed dashboard row containing *needle* (first match), or -1.
local function find_row(child, needle)
  return child.lua_get(string.format(
    [[(function()
        local lines = vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)
        for i, l in ipairs(lines) do
          if l and l:find(%q, 1, true) then return i - 1 end
        end
        return -1
      end)()]],
    needle
  ))
end

--- Distinct group_name strings present in the dashboard's managed line_map.
local function distinct_groups(child)
  return child.lua_get([[(function()
    local bs = require("obsidian-tasks.render.init")._buffer_state[_G._b]
    local seen, out = {}, {}
    for _, blk in ipairs(bs or {}) do
      for _, m in pairs(blk.line_map or {}) do
        if m.group_name and not seen[m.group_name] then
          seen[m.group_name] = true
          out[#out + 1] = m.group_name
        end
      end
    end
    table.sort(out)
    return out
  end)()]])
end

--- Count managed rows whose group_name == *group*.
local function rows_in_group(child, group)
  return child.lua_get(string.format(
    [[(function()
      local bs = require("obsidian-tasks.render.init")._buffer_state[_G._b]
      local n = 0
      for _, blk in ipairs(bs or {}) do
        for _, m in pairs(blk.line_map or {}) do
          if m.group_name == %q then n = n + 1 end
        end
      end
      return n
    end)()]],
    group
  ))
end

--- Boot a child nvim with a file-backed grouped (optionally tree) dashboard over
--- the supplied source lines.  `query_lines` is the full fence body; `setup_opts`
--- is passed to obsidian-tasks.setup (e.g. a global_filter).  The source is
--- re-read on every tasks_in call so a post-edit refresh re-groups by the new
--- tag/status set.  Mirrors test_real_dup_group_sync.spawn exactly.
local function spawn(source_lines, query_lines, setup_opts)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[(function(...)
    local cwd, deps_dir, source_lines, query_lines, setup_opts = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    require("obsidian-tasks").setup(setup_opts or {})

    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(source_lines, src)
    local note = vim.fn.tempname() .. ".md"
    local note_lines = { "# Daily" }
    for _, l in ipairs(query_lines) do note_lines[#note_lines + 1] = l end
    vim.fn.writefile(note_lines, note)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local tp = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, d) if d then d() end end
    index.invalidate = function() end
    index.refresh_file = function() end
    index.nodes_for = function(p)
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or source_lines)
      end
      return {}
    end
    -- Re-read source on every call so a post-edit refresh yields updated tasks.
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      lines = ok and lines or source_lines
      local items = {}
      for ln, line in ipairs(lines) do
        local t = tp.parse(line)
        if t then items[#items + 1] = { t = t, ln = ln } end
      end
      local i = 0
      return function()
        i = i + 1
        if items[i] then return items[i].t, src, items[i].ln end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    vim.bo[b].autoindent = false
    -- Let the FIRST render's draw -> save.attach set obsidian_tasks_dashboard.
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._b = b
    _G._note = note
    _G._src = src
  end)(...)]],
    { cwd, deps_dir, source_lines, query_lines, setup_opts }
  )
  return child
end

local function teardown(child)
  local src = child.lua_get("_G._src")
  local note = child.lua_get("_G._note")
  child.stop()
  pcall(vim.fn.delete, src)
  pcall(vim.fn.delete, note)
end

--- Type " <tag>" right before the ' [[' wikilink suffix (or at EOL) of the row
--- containing *needle*, then leave insert mode and let the flush drain.
local function append_tag_on_row(child, needle, tag)
  local row = find_row(child, needle)
  eq(row >= 0, true, "row for '" .. needle .. "' must exist: " .. vim.inspect(buflines(child)))
  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._b, " .. row .. ", " .. row + 1 .. ", false)[1]")
  local suffix_byte = line:find(" %[%[")
  local insert_col = suffix_byte and (suffix_byte - 1) or #line
  child.api.nvim_win_set_cursor(0, { row + 1, insert_col })
  child.type_keys("i", " " .. tag, "<Esc>")
  vim.loop.sleep(400)
end

local STD_GROUP = { "```tasks", "group by tags", "```" }
local STD_TREE_GROUP = { "```tasks", "show tree", "group by tags", "```" }

-- ── remove-tag-empty-group (INTUITIVE / hardening) ─────────────────────────────
-- Edit a task to REMOVE the tag that groups it; the now-empty group (header +
-- any rows) must vanish live, not linger as a header with no tasks.

T["remove-tag-empty-group: deleting the only tag of a group removes that group LIVE"] = function()
  -- Two source tasks: one only-#alpha, one only-#beta.  Two singleton groups.
  local child = spawn({
    "- [ ] alpha solo #alpha",
    "- [ ] beta solo #beta",
  }, STD_GROUP)

  eq(count_rows(child, "alpha solo"), 1, "alpha task starts in #alpha: " .. vim.inspect(buflines(child)))
  local groups0 = distinct_groups(child)
  eq(vim.tbl_contains(groups0, "#alpha"), true, "#alpha group exists initially: " .. vim.inspect(groups0))
  eq(vim.tbl_contains(groups0, "#beta"), true, "#beta group exists initially: " .. vim.inspect(groups0))

  -- Remove ' #alpha' from the alpha task: position on the tag and delete the word
  -- plus its leading space.  Use a find + change to be robust to suffixes.
  local row = find_row(child, "alpha solo")
  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._b, " .. row .. ", " .. row + 1 .. ", false)[1]")
  local tag_byte = line:find(" #alpha")
  eq(tag_byte ~= nil, true, "alpha row must carry ' #alpha': [" .. (line or "nil") .. "]")
  -- Cursor on the SPACE before '#alpha' (0-indexed tag_byte-1), delete 7 chars
  -- (" #alpha").  type_keys "x" * 7 removes the run in normal mode (one flush).
  child.api.nvim_win_set_cursor(0, { row + 1, tag_byte - 1 })
  child.type_keys("7x")
  vim.loop.sleep(400)

  -- Source committed the removal.
  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("#alpha") == nil, true, "source lost #alpha: [" .. (disk[1] or "nil") .. "]")

  -- The #alpha group must be GONE; the alpha task now has no tags so it falls into
  -- the "No tags" group (group by tags), and #beta is untouched.
  local groups1 = distinct_groups(child)
  eq(vim.tbl_contains(groups1, "#alpha"), false, "empty #alpha group must vanish: " .. vim.inspect(groups1))
  eq(rows_in_group(child, "#alpha"), 0, "no managed rows may remain in #alpha")
  eq(vim.tbl_contains(groups1, "#beta"), true, "#beta sibling group is unaffected: " .. vim.inspect(groups1))

  teardown(child)
end

-- ── dup-instance-tree-consistency (INTUITIVE / hardening) ──────────────────────
-- A 2-tag task renders under both tag groups; editing one instance's DESCRIPTION
-- must update BOTH instances live.

T["dup-instance: editing one instance's description updates BOTH group instances LIVE"] = function()
  local child = spawn({ "- [ ] dup desc #alpha #beta" }, STD_GROUP)
  eq(count_rows(child, "dup desc"), 2, "renders under BOTH tag groups: " .. vim.inspect(buflines(child)))

  -- Append " EDITED" to the description of the FIRST instance (before ' [[').
  append_tag_on_row(child, "dup desc", "EDITED")

  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("EDITED") ~= nil, true, "source gained the edit: [" .. (disk[1] or "nil") .. "]")

  -- BOTH instances now show the edited description.
  eq(
    count_rows(child, "EDITED"),
    2,
    "both instances reflect the new description LIVE: " .. vim.inspect(buflines(child))
  )
  eq(count_rows(child, "dup desc"), 2, "still exactly two instances (no group churn)")

  teardown(child)
end

-- ── dup-in-same-group-via-cartesian (INTUITIVE / hardening) ────────────────────
-- group by tags, status: a 2-tag task produces a cartesian of group names of the
-- form "<tag> / <status>".  Adding a third tag must add the corresponding
-- cartesian instances; all stay in sync.

T["cartesian dup: group by tags+status duplicates per tag; adding a tag adds an instance LIVE"] = function()
  local child = spawn({ "- [ ] cart task #alpha #beta" }, {
    "```tasks",
    "group by tags",
    "group by status",
    "```",
  })

  -- One source task, two tags, one status → two cartesian instances:
  --   "#alpha / <status>", "#beta / <status>".
  eq(count_rows(child, "cart task"), 2, "two cartesian instances (one per tag): " .. vim.inspect(buflines(child)))
  local g0 = distinct_groups(child)
  -- Each group name is the joined "<tag> / <status>" form.
  local has_alpha = false
  local has_beta = false
  for _, name in ipairs(g0) do
    if name:find("#alpha", 1, true) then
      has_alpha = true
    end
    if name:find("#beta", 1, true) then
      has_beta = true
    end
  end
  eq(has_alpha and has_beta, true, "cartesian group names carry both tags: " .. vim.inspect(g0))

  -- Add #gamma → a third cartesian instance appears LIVE.
  append_tag_on_row(child, "cart task", "#gamma")
  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("#gamma") ~= nil, true, "source gained #gamma: [" .. (disk[1] or "nil") .. "]")

  eq(
    count_rows(child, "cart task"),
    3,
    "third tag adds a third cartesian instance LIVE: " .. vim.inspect(buflines(child))
  )

  teardown(child)
end

--- Count managed rows whose text contains *needle* split by their dim flag.
--- Returns { lit_count, dim_count } over the buffer-state line_map.  Matches on
--- the meta's own rendered_text (the line_map key is NOT the buffer line number).
local function dim_split(child, needle)
  return child.lua_get(string.format(
    [[(function()
      local bs = require("obsidian-tasks.render.init")._buffer_state[_G._b]
      local lit, dim = 0, 0
      for _, blk in ipairs(bs or {}) do
        for _, m in pairs(blk.line_map or {}) do
          local txt = m.rendered_text
          if txt and txt:find(%q, 1, true) then
            if m.dim then dim = dim + 1 else lit = lit + 1 end
          end
        end
      end
      return { lit, dim }
    end)()]],
    needle
  ))
end

-- ── dup-root-tree-edit-both-instances (D2) ─────────────────────────────────────
-- A tree-grouped Parent carries #task #beta; its Child carries #task #alpha.  The
-- global-filter tag #task DOES form a group (D2), so three groups exist: #alpha,
-- #beta, #task.  Per D2 (a row is lit only where it INDEPENDENTLY matches the
-- group):
--   #alpha:  Child lit root, Parent DIM breadcrumb above it.
--   #beta:   Parent lit root, Child DIM descendant.
--   #task:   Parent lit root, Child lit descendant.
-- So Parent renders 3× (DIM in #alpha, LIT in #beta, LIT in #task) and Child
-- renders 3× (LIT #alpha, DIM #beta, LIT #task).  Editing the Parent description
-- must sync its text across ALL THREE Parent renderings (lit roots + dim
-- breadcrumb).

T["tree dup root: editing a matched root syncs its text across all group renderings"] = function()
  local child = spawn({
    "- [ ] Parent #task #beta",
    "  - [ ] Child #task #alpha",
  }, STD_TREE_GROUP, { global_filter = "#task" })

  -- Parent appears 3× total: 2 lit roots (#beta, #task) + 1 dim breadcrumb (#alpha).
  eq(count_rows(child, "Parent"), 3, "Parent renders in all 3 groups: " .. vim.inspect(buflines(child)))
  eq(dim_split(child, "Parent"), { 2, 1 }, "Parent: 2 lit roots (#beta,#task) + 1 dim breadcrumb (#alpha)")
  -- Child symmetrically: 2 lit (#alpha root, #task descendant) + 1 dim (#beta descendant).
  eq(count_rows(child, "Child"), 3, "Child renders in all 3 groups: " .. vim.inspect(buflines(child)))
  eq(dim_split(child, "Child"), { 2, 1 }, "Child: 2 lit (#alpha,#task) + 1 dim (#beta)")

  -- Edit the Parent description on its FIRST appearance.
  append_tag_on_row(child, "Parent", "PEDIT")
  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("PEDIT") ~= nil, true, "source Parent gained the edit: [" .. (disk[1] or "nil") .. "]")

  -- ALL THREE Parent renderings (lit #beta + #task roots AND the dim #alpha
  -- breadcrumb) reflect the edit live.
  eq(
    count_rows(child, "PEDIT"),
    3,
    "Parent text syncs across all group renderings incl. the dim breadcrumb: " .. vim.inspect(buflines(child))
  )

  teardown(child)
end

-- ── tree-group-sort-combined (OPEN) ────────────────────────────────────────────
-- show tree, group by priority, sort by description.  A matched root's priority
-- change must move it to the new priority group LIVE, dragging its descendants.

T["tree+group+sort: changing a root's priority re-buckets it into the new group LIVE with its subtree"] = function()
  -- High = ⏫, low = 🔽.  Root starts LOW; flip to HIGH.  Child rides in via drag.
  local child = spawn({
    "- [ ] Root low 🔽 #task",
    "  - [ ] Kid #task",
  }, {
    "```tasks",
    "show tree",
    "group by priority",
    "sort by description",
    "```",
  }, { global_filter = "#task" })

  -- D2 + group by priority: Root (Low) and Kid (None) each form their own
  -- priority group.  In the None group, Kid is the lit root and Root is its DIM
  -- breadcrumb; in the Low group, Root is the lit root and Kid is its DIM
  -- descendant.  So Root renders 2× initially: LIT in Low, DIM (breadcrumb) in
  -- None.
  eq(count_rows(child, "Root low"), 2, "root renders in both Low (lit) + None (dim): " .. vim.inspect(buflines(child)))
  eq(dim_split(child, "Root low"), { 1, 1 }, "Root: 1 lit (Low) + 1 dim breadcrumb (None)")
  local g0 = distinct_groups(child)
  -- The low-priority group must exist initially.
  local saw_low = false
  for _, name in ipairs(g0) do
    if name:lower():find("low", 1, true) then
      saw_low = true
    end
  end
  eq(saw_low, true, "a Low priority group exists initially: " .. vim.inspect(g0))

  -- Change priority: replace 🔽 with ⏫ on the root in ONE edit.  `cl` deletes the
  -- single (multibyte) char under the cursor and enters insert, then we type ⏫.
  -- (Inserting ⏫ alongside 🔽 first would create a transient double-priority that
  -- the serializer canonicalizes — dropping one emoji — so do it as one swap.)
  local row = find_row(child, "Root low")
  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._b, " .. row .. ", " .. row + 1 .. ", false)[1]")
  local lo_byte = line:find("🔽", 1, true)
  eq(lo_byte ~= nil, true, "root must carry the low-priority emoji: [" .. (line or "nil") .. "]")
  child.api.nvim_win_set_cursor(0, { row + 1, lo_byte - 1 })
  child.type_keys("c", "l", "⏫", "<Esc>")
  vim.loop.sleep(450)

  local disk = child.lua_get("vim.fn.readfile(_G._src)")
  eq(disk[1]:find("⏫", 1, true) ~= nil, true, "source gained the high-priority emoji: [" .. (disk[1] or "nil") .. "]")
  eq(
    disk[1]:find("🔽", 1, true) == nil,
    true,
    "low-priority emoji removed from source: [" .. (disk[1] or "nil") .. "]"
  )

  -- The root must now sit in a High priority group, NOT Low, and the Child still
  -- renders under it (subtree dragged into the new group).
  local g1 = distinct_groups(child)
  local saw_high = false
  local saw_low_after = false
  for _, name in ipairs(g1) do
    if name:lower():find("high", 1, true) then
      saw_high = true
    end
    if name:lower():find("low", 1, true) then
      saw_low_after = true
    end
  end
  eq(saw_high, true, "root re-bucketed into a High group LIVE: " .. vim.inspect(g1))
  eq(saw_low_after, false, "the now-empty Low group must vanish: " .. vim.inspect(g1))
  -- D2: Kid (None) is its own group's lit root AND rides into Root's new High
  -- group as a DIM descendant, so it renders 2× (lit in None, dim in High).  The
  -- subtree drag into the new High group is what the second (dim) rendering is.
  eq(
    count_rows(child, "Kid"),
    2,
    "Kid: lit root in None + dim descendant dragged into High: " .. vim.inspect(buflines(child))
  )
  eq(dim_split(child, "Kid"), { 1, 1 }, "Kid: 1 lit (None root) + 1 dim (High descendant)")

  teardown(child)
end

-- ── eof-sentinel-group-interaction (INTUITIVE / hardening) ─────────────────────
-- A grouped tree dashboard's EOF sentinel: <CR> on it adds a real file newline and
-- releases the sentinel; group structure above is unchanged.

T["eof sentinel (grouped tree): <CR> adds a real newline and leaves the groups intact"] = function()
  local child = spawn({
    "- [ ] Parent #task #beta",
    "  - [ ] Child #task",
  }, STD_TREE_GROUP, { global_filter = "#task" })

  local before = buflines(child)
  local n_before = #before
  local groups_before = distinct_groups(child)
  eq(vim.tbl_contains(groups_before, "#beta"), true, "#beta group present before: " .. vim.inspect(groups_before))

  -- Cursor on the LAST buffer line (the EOF sentinel below the virtual footer).
  child.api.nvim_win_set_cursor(0, { n_before, 0 })
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(400)

  -- A real newline was added to the note file (sentinel released → real content).
  local note_disk = child.lua_get("vim.fn.readfile(_G._note)")
  eq(#note_disk >= 1, true, "note file readable after sentinel release")

  -- Group structure above is unchanged.  D2: the global-filter tag #task forms a
  -- group, so Parent (#task #beta) renders LIT in BOTH the #beta and #task groups
  -- → Parent appears 2×.  (Child carries only #task, so it has no #alpha group
  -- here.)  The sentinel <CR> must not change that grouping.
  local groups_after = distinct_groups(child)
  eq(vim.tbl_contains(groups_after, "#beta"), true, "#beta group survives sentinel <CR>: " .. vim.inspect(groups_after))
  eq(
    count_rows(child, "Parent"),
    2,
    "Parent still renders lit in both #beta and #task: " .. vim.inspect(buflines(child))
  )

  teardown(child)
end

return T
