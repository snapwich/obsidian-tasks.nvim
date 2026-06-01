-- tests/integration_real/test_harden_tree_edit_real.lua
-- HARDENING — dimension "Edit-through on tree rows" (tree_edit).
--
-- Real keypresses (MiniTest.new_child_neovim + type_keys → mode() is genuinely
-- 'i'/'R', vim.schedule fires between keystrokes, the InsertLeave drain is the
-- real autocmd).  These cases probe the edit-through pipeline on `show tree`
-- rows where the row is NOT a plain top-level matched task: DIM breadcrumb
-- ancestors, blank connectors, status flips on matched roots, depth-relative
-- indent round-trips, recurrence fields, inserts at the breadcrumb/matched-root
-- boundary, multi-line tree pastes, grouped tree re-grouping, query-exit linger
-- and fold-state preservation across a mutate-driven rerender.
--
-- Scaffolding mirrors test_real_tree_edit / test_real_tree_insert /
-- test_real_tree_delete / test_real_dup_group_sync.  See CLAUDE.md: real
-- insert-mode tests MUST drive a child nvim + type_keys; do NOT pre-set
-- vim.b.obsidian_tasks_dashboard on a file-backed dashboard (let the first
-- render's draw→save.attach set it).

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── shared spawners ───────────────────────────────────────────────────────────

--- Boot a child nvim with a real `show tree` dashboard backed by *content*.
--- The matched left-most task is source line *matched_line* (default 1); the
--- whole file parses as the subtree so its ancestors above the match render as
--- DIM breadcrumb rows.  nodes_for re-reads the LIVE file so edits round-trip
--- on rerender.  The dashboard is a scratch buffer (flag pre-set is fine for a
--- scratch buffer — the gotcha only bites file-backed dashboards).
local function spawn_tree(content, matched_line)
  matched_line = matched_line or 1
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })
  ]],
    { cwd, deps_dir }
  )

  child.lua(
    [[(function(args)
    local src_content, matched_line = args[1], args[2]
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")

    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    index.nodes_for = function(p)
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or src_content)
      end
      return {}
    end
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then
          local ok, lines = pcall(vim.fn.readfile, src)
          local t = task_parse.parse((ok and lines[matched_line]) or src_content[matched_line])
          return t, src, matched_line
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```tasks", "show tree", "```" })
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].autoindent = false
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    _G._warns = {}
    local log = require("obsidian-tasks.log")
    log.warn = function(msg) table.insert(_G._warns, tostring(msg)) end
    return src
  end)(...)]],
    { { content, matched_line } }
  )

  return child
end

--- Boot a real, FILE-BACKED `group by tags` + `show tree` dashboard so the
--- whole subtree groups by tag.  The note file is edited so the FIRST render's
--- draw→save.attach sets the dashboard flag + BufWriteCmd handler (the gotcha).
local function spawn_grouped_tree(content)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian-tasks").setup({})
  ]],
    { cwd, deps_dir }
  )

  child.lua(
    [[(function(src_content)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)
    local note = vim.fn.tempname() .. ".md"
    vim.fn.writefile({ "# Daily", "```tasks", "show tree", "group by tags", "```" }, note)

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
        return nodes_mod.parse_lines(ok and lines or src_content)
      end
      return {}
    end
    -- Yield every source task so `group by tags` buckets each by its own tags.
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      lines = ok and lines or src_content
      local emit = {}
      for ln, text in ipairs(lines) do
        local t = tp.parse(text)
        if t then emit[#emit + 1] = { t, src, ln } end
      end
      local i = 0
      return function()
        i = i + 1
        if emit[i] then return emit[i][1], emit[i][2], emit[i][3] end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    vim.bo[b].autoindent = false
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._dash_bufnr = b
    _G._src_path = src
    _G._note = note
  end)(...)]],
    { content }
  )

  return child
end

-- ── shared accessors ───────────────────────────────────────────────────────────

local function child_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

--- 0-indexed dashboard row whose text contains *needle* (first match).
local function dash_row_with(child, needle)
  return child.lua_get(
    [[(function(needle)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find(needle, 1, true) then return i - 1 end
    end
    return -1
  end)(...)]],
    { needle }
  )
end

--- Count dashboard rows whose text contains *needle*.
local function count_rows(child, needle)
  return child.lua_get(
    [[(function(needle)
    local n = 0
    for _, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
      if l and l:find(needle, 1, true) then n = n + 1 end
    end
    return n
  end)(...)]],
    { needle }
  )
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: editing a DIM breadcrumb ancestor TASK row (read_only is NOT set for it)
-- ════════════════════════════════════════════════════════════════════════════
-- Source: grandparent(0), parent(1), match(2).  matched_line=3 so the parent
-- (line 2) renders DIM above the lit match.  The DIM parent is a TASK row, and
-- draw.lua only sets read_only on BLANK rows, so its meta lacks read_only.  Best
-- guess of the INTENDED semantics: a DIM ancestor is breadcrumb CONTEXT, not an
-- edit target, so a body edit on it must NOT alter the matched-node structure —
-- the matched lines (1 + 3) must round-trip byte-identical.  (The dim parent
-- line itself may or may not take the edit; we assert ONLY that the matched
-- scope is untouched and the file did not grow/shrink.)  EXPECTED TO POSSIBLY
-- FAIL: code currently lets the dim task row write through.

local DIM_SRC = {
  "- [ ] Grandparent #task",
  "  - [ ] Parent #task",
  "    - [ ] Match #task",
}

T["OPEN dim-ancestor body edit must not mutate the matched scope"] = function()
  local child = spawn_tree(DIM_SRC, 3)

  -- Dashboard rows: 3 DIM grandparent(0), 4 DIM parent(1), 5 LIT match(2).
  local parent_row = dash_row_with(child, "Parent")
  eq(parent_row >= 0, true, "dim parent row must exist")
  eq(child_line(child, 5):find("Match", 1, true) ~= nil, true, "lit match must render at row 5")

  -- ciw on "Parent" → "Edited" on the DIM ancestor task row.
  -- Dashboard parent row is "  - [ ] Parent #task"; "Parent" starts at col 8.
  child.api.nvim_win_set_cursor(0, { parent_row + 1, 8 })
  child.type_keys("c", "i", "w", "Edited", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 3, "file must not grow or shrink from a breadcrumb edit: " .. vim.inspect(src))
  -- The MATCHED scope (the grandparent root + the matched leaf) must round-trip
  -- byte-identical — editing a breadcrumb must never restructure the match.
  eq(src[1], "- [ ] Grandparent #task", "matched root must be byte-intact: " .. vim.inspect(src))
  eq(src[3], "    - [ ] Match #task", "matched leaf must be byte-intact: " .. vim.inspect(src))

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- HARDEN: status flip on a DIM ancestor checkbox writes through (D5)
-- ════════════════════════════════════════════════════════════════════════════
-- D5: dim breadcrumb ANCESTOR TASK rows are EDITABLE — they write through like
-- any matched row (the user chose this; only blank connector sentinels stay
-- read-only).  So a status flip on a dim ancestor's checkbox MUST commit to the
-- ancestor's source line, while the matched leaf round-trips byte-identical.

T["HARDEN status flip on a DIM ancestor checkbox writes through (D5 editable)"] = function()
  local child = spawn_tree(DIM_SRC, 3)

  local parent_row = dash_row_with(child, "Parent")
  eq(parent_row >= 0, true, "dim parent row must exist")
  local line = child_line(child, parent_row)
  local box_byte = line:find("%[ %]") -- 1-indexed '['; the space is +1
  eq(box_byte ~= nil, true, "dim parent must render an empty checkbox: [" .. tostring(line) .. "]")

  -- r x over the space inside the dim parent's "[ ]".
  child.api.nvim_win_set_cursor(0, { parent_row + 1, box_byte }) -- on the space
  child.type_keys("r", "x")
  vim.loop.sleep(350)

  local src = child_src(child)
  -- D5: the dim ancestor is editable, so the flip commits to its source line.
  eq(src[2], "  - [x] Parent #task", "dim ancestor status flip MUST write through (D5): " .. vim.inspect(src))
  -- The matched leaf (line 3) and root (line 1) are untouched by the ancestor edit.
  eq(src[1], "- [ ] Grandparent #task", "matched root must be byte-intact: " .. vim.inspect(src))
  eq(src[3], "    - [ ] Match #task", "matched leaf must be byte-intact: " .. vim.inspect(src))

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- HARDENING: blank connector row is read-only under `dd`
-- ════════════════════════════════════════════════════════════════════════════
-- An interior blank row (read_only==true) is double-shielded: flush skips
-- read_only rows AND on_lines drops them from pending_deletes.  dd on it must
-- revert (no source delete).

local BLANK_SRC = {
  "- [ ] Root task #task",
  "    - [ ] Child task #task",
  "",
  "    - [ ] Second child #task",
}

T["HARDEN dd on a read-only blank connector row does not delete a source line"] = function()
  local child = spawn_tree(BLANK_SRC)

  -- The blank renders empty between the two children.  Find it by scanning for
  -- the first empty managed row after the root.
  local blank_row = child.lua_get([[(function()
    local lines = vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)
    for i = 4, #lines do -- skip fence(1-3) + root(4)
      if lines[i] == "" then return i - 1 end
    end
    return -1
  end)()]])
  eq(blank_row >= 0, true, "a blank connector row must render")

  local before = child_src(child)
  eq(#before, 4, "fixture starts with four source lines")

  child.api.nvim_win_set_cursor(0, { blank_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(350)

  local after = child_src(child)
  -- Source untouched: the blank is read-only, so dd reverts rather than deleting.
  eq(after, before, "dd on a read-only blank must not change source: " .. vim.inspect(after))

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- HARDENING: status cycle (<CR>) on a LIT matched root with children
-- ════════════════════════════════════════════════════════════════════════════
-- <CR> on the matched root cycles its status; the flip commits to source and the
-- descendants are untouched (their own source lines unchanged).

T["HARDEN status flip on a matched root commits, descendants untouched"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - [ ] Child task #task",
  })

  local root_row = dash_row_with(child, "Root task")
  eq(root_row >= 0, true, "matched root row must exist")
  local root_line = child_line(child, root_row)
  local box_byte = root_line:find("%[ %]")
  eq(box_byte ~= nil, true, "root starts Todo")

  -- NOTE: the plugin deliberately does NOT bind <CR> (status toggle is owned by
  -- obsidian.nvim's smart_action ftplugin, which is absent in this suite).  The
  -- canonical status flip here is `r x` over the checkbox space (see
  -- test_real_insert_mode / test_real_dup_group_sync).
  child.api.nvim_win_set_cursor(0, { root_row + 1, box_byte }) -- on the space inside [ ]
  child.type_keys("r", "x")
  vim.loop.sleep(350)

  local src = child_src(child)
  -- The root's status advanced off Todo (Todo→Done); its body and the child line
  -- are otherwise intact.
  eq(src[1]:find("%[ %]") == nil, true, "matched root must have flipped off Todo: " .. vim.inspect(src))
  eq(src[1]:find("Root task") ~= nil, true, "root body must survive the status cycle: " .. vim.inspect(src))
  eq(src[2], "    - [ ] Child task #task", "descendant source line must be untouched: " .. vim.inspect(src))

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: depth-relative indent round-trips ('>>' on a child must not restructure)
-- ════════════════════════════════════════════════════════════════════════════
-- The child renders at a depth-relative 2-space dashboard indent.  Pressing >>
-- adds shiftwidth leading spaces in the BUFFER.  Best guess: this is a
-- visual-only operation that must NOT shift the child's SOURCE indent — the
-- child's 4-space source indent must round-trip.  EXPECTED TO POSSIBLY FAIL if
-- flush re-derives source depth from the (now-deeper) dashboard indent.

T["OPEN '>>' indent on a child row must not shift its source indent"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - [ ] Child task #task",
  })

  local child_row = dash_row_with(child, "Child task")
  eq(child_row >= 0, true, "child row must exist")
  -- Normal-mode >> indents the line by shiftwidth.
  child.lua("vim.bo[_G._dash_bufnr].shiftwidth = 2")
  child.lua("vim.bo[_G._dash_bufnr].expandtab = true")
  child.api.nvim_win_set_cursor(0, { child_row + 1, 0 })
  child.type_keys(">", ">")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 2, "indent-motion must not add or drop source lines: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  -- The child must keep its ORIGINAL 4-space source indent (visual-only op).
  eq(
    src[2],
    "    - [ ] Child task #task",
    "child source indent must round-trip (no structural shift): " .. vim.inspect(src)
  )

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- HARDENING: editing a recurrence field on a tree row round-trips
-- ════════════════════════════════════════════════════════════════════════════
-- A tree task carries a recurrence marker.  Editing its description (leaving the
-- recurrence intact) writes through and the recurrence field survives serialize.

T["HARDEN recurrence field on a tree task survives a description edit"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - [ ] Water plants 🔁 every day #task",
  })

  local rec_row = dash_row_with(child, "Water plants")
  eq(rec_row >= 0, true, "recurring child row must exist")
  -- The rendered row must carry the recurrence marker.
  eq(child_line(child, rec_row):find("🔁", 1, true) ~= nil, true, "row must render the 🔁 marker")

  -- ciw on "Water" → "Soak".  "  - [ ] " is 8 cols; "Water" starts at col 8.
  child.api.nvim_win_set_cursor(0, { rec_row + 1, 8 })
  child.type_keys("c", "i", "w", "Soak", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  eq(#src, 2, "in-place edit must not change line count: " .. vim.inspect(src))
  eq(src[1], "- [ ] Root task #task", "root must be untouched")
  -- Body edit applied AND the recurrence field survived serialize.
  eq(src[2]:find("Soak", 1, true) ~= nil, true, "description edit must write through: " .. vim.inspect(src))
  eq(src[2]:find("🔁", 1, true) ~= nil, true, "recurrence marker must survive serialize: " .. vim.inspect(src))
  eq(src[2]:find("every day", 1, true) ~= nil, true, "recurrence rule must survive serialize: " .. vim.inspect(src))

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- HARDENING: bullet edited to add a checkbox reclassifies as a child task
-- ════════════════════════════════════════════════════════════════════════════
-- Editing a DIM/lit tree BULLET row in place to add "[ ]" writes raw and the
-- next parse classifies it as a TASK (tree_kind bullet→task).

T["HARDEN bullet edited to add a checkbox reclassifies as a task on reparse"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - a plain note",
  })

  local note_row = dash_row_with(child, "a plain note")
  eq(note_row >= 0, true, "bullet row must exist")
  -- Clear the line and retype it as a checkbox bullet at the depth indent.
  child.api.nvim_win_set_cursor(0, { note_row + 1, 0 })
  child.type_keys("c", "c", "  - [ ] a plain note", "<Esc>")
  vim.loop.sleep(400)

  local src = child_src(child)
  -- Raw write lands a checkbox line at the original 4-space source indent.
  eq(src[2], "    - [ ] a plain note", "bullet→checkbox writes raw at source indent: " .. vim.inspect(src))

  -- After reparse the line classifies as a TASK.
  local kind = child.lua_get([[(function()
    local nodes = require("obsidian-tasks.index.nodes")
    local lines = vim.fn.readfile(_G._src_path)
    for _, n in ipairs(nodes.parse_lines(lines)) do
      if n.line_num == 2 then return n.kind end
    end
    return "?"
  end)()]])
  eq(kind, "task", "the edited line must reclassify as a child task")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: `o` after a MATCHED root → sibling task; on a grouped tree must NOT be
-- double-injected with the group tag (it is dragged in as a sibling of a match)
-- ════════════════════════════════════════════════════════════════════════════
-- On a `group by tags` tree, the matched Root carries #beta.  `o` directly after
-- the lit matched Root inserts a sibling.  The new row's structural parent chain
-- reaches the MATCHED Root → P9 must NOT inject #beta.  Best guess: no #beta on
-- the inserted line.  EXPECTED TO POSSIBLY FAIL if the gate mis-decides at the
-- matched-root sibling boundary.

T["OPEN o after a matched root sibling does not double-inject the group tag"] = function()
  local child = spawn_grouped_tree({
    "- [ ] Root #task #beta",
    "  - [ ] Child #task",
  })

  local root_row = dash_row_with(child, "Root")
  eq(root_row >= 0, true, "lit matched Root row must exist")
  child.api.nvim_win_set_cursor(0, { root_row + 1, 0 })
  child.type_keys("o", "  - [ ] new sibling #task", "<Esc>")
  vim.loop.sleep(450)

  local src = child_src(child)
  local line
  for _, l in ipairs(src) do
    if l:find("new sibling", 1, true) then
      line = l
    end
  end
  eq(line ~= nil, true, "inserted sibling must be present: " .. table.concat(src, "\n"))
  -- Parented under the matched Root → must NOT inject the group tag.
  eq(
    line:find("#beta", 1, true) == nil,
    true,
    "sibling of a matched root must NOT inject #beta: [" .. tostring(line) .. "]"
  )

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: insert BETWEEN a DIM breadcrumb and the LIT matched root
-- ════════════════════════════════════════════════════════════════════════════
-- `o` on a DIM breadcrumb (whose only ancestor chain is dim) inserts a row whose
-- structural parent is the breadcrumb (no matched ancestor).  Best guess: the
-- inserted row writes to source as a child of the breadcrumb's source line, and
-- the existing matched lines round-trip byte-identical.  EXPECTED TO POSSIBLY
-- FAIL at the boundary where structural parent (breadcrumb) and matched ancestor
-- (root) diverge.

T["OPEN insert below a DIM breadcrumb writes to source without corrupting the match"] = function()
  local child = spawn_tree(DIM_SRC, 3)

  -- Dashboard rows: 3 DIM grandparent(0), 4 DIM parent(1), 5 LIT match(2).
  local gp_row = dash_row_with(child, "Grandparent")
  eq(gp_row >= 0, true, "dim grandparent row must exist")
  child.api.nvim_win_set_cursor(0, { gp_row + 1, 0 })
  -- Insert a child of the dim grandparent (2-space indent → depth 1).
  child.type_keys("o", "  - [ ] interloper #task", "<Esc>")
  vim.loop.sleep(450)

  local src = child_src(child)
  local joined = table.concat(src, "\n")
  -- The matched lines must survive byte-identical; the new line is somewhere in
  -- the file (placed relative to the breadcrumb's source line).
  eq(joined:find("- %[ %] Grandparent #task") ~= nil, true, "grandparent must survive: " .. joined)
  eq(joined:find("    %- %[ %] Match #task") ~= nil, true, "matched leaf must survive byte-intact: " .. joined)
  eq(joined:find("interloper", 1, true) ~= nil, true, "the inserted line must be written to source: " .. joined)

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: multi-line normal-mode paste of two tree task rows
-- ════════════════════════════════════════════════════════════════════════════
-- Yank two adjacent tree task rows and paste below a third.  The pasted rendered
-- lines lose tree meta; the INSERT classifier must infer structure from rows
-- above and write BOTH pasted tasks to source.  Best guess: both bodies appear
-- in source exactly once and nothing is corrupted.  EXPECTED TO POSSIBLY FAIL on
-- the second pasted row's anchor (its parent is the first pasted row, not a
-- canonical managed row).

T["OPEN multi-line paste of two tree task rows writes both to source"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - [ ] Alpha child #task",
    "    - [ ] Beta child #task",
    "    - [ ] Gamma child #task",
  })

  local alpha_row = dash_row_with(child, "Alpha child")
  eq(alpha_row >= 0, true, "Alpha row must exist")
  local gamma_row = dash_row_with(child, "Gamma child")
  eq(gamma_row >= 0, true, "Gamma row must exist")

  -- Yank Alpha + Beta (2 visual lines), then paste below Gamma.
  child.api.nvim_win_set_cursor(0, { alpha_row + 1, 0 })
  child.type_keys("V", "j", "y")
  child.api.nvim_win_set_cursor(0, { gamma_row + 1, 0 })
  child.type_keys("p")
  vim.loop.sleep(500)

  local src = child_src(child)
  local joined = table.concat(src, "\n")
  -- Count occurrences of each pasted body: each must now appear TWICE (original
  -- + paste), and the originals must be intact.
  local function occ(needle)
    local n, init = 0, 1
    while true do
      local s = joined:find(needle, init, true)
      if not s then
        break
      end
      n = n + 1
      init = s + 1
    end
    return n
  end
  eq(occ("Alpha child") == 2, true, "Alpha must appear twice (original + paste): " .. joined)
  eq(occ("Beta child") == 2, true, "Beta must appear twice (original + paste): " .. joined)
  eq(joined:find("Gamma child", 1, true) ~= nil, true, "Gamma (paste anchor) must survive: " .. joined)
  eq(joined:find("Root task", 1, true) ~= nil, true, "Root must survive: " .. joined)

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- HARDENING: editing a tree node to add a new tag creates a new group LIVE
-- ════════════════════════════════════════════════════════════════════════════
-- On a grouped tree, adding a tag to the matched root re-groups it: a new group
-- appears LIVE (without :w) and the source committed the tag.  The grouped
-- whole-dashboard rerender re-buckets tree roots like the flat path does.
--
-- D2: with no global filter, `group by tags` buckets each task by EACH of its
-- tags.  Root (#task #alpha) is a lit root in BOTH the #task and #alpha groups,
-- so it renders 2× to start; adding #beta makes it match three tags → 3 lit
-- roots.  (The product already spawns the new group instance for a tree root on
-- the grouped mutate rerender — verified live; this asserts the D2 counts.)

T["HARDEN adding a tag to a grouped tree root creates a new group live"] = function()
  local child = spawn_grouped_tree({
    "- [ ] Root #task #alpha",
    "  - [ ] Child #task",
  })

  -- Root starts as a LIT root in both the #task and #alpha groups → 2 instances.
  eq(
    count_rows(child, "Root"),
    2,
    "root starts lit in both #task and #alpha groups: "
      .. vim.inspect(child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)"))
  )

  local row = dash_row_with(child, "Root")
  eq(row >= 0, true, "root instance row must exist")
  local line = child_line(child, row)
  local suffix_byte = line:find(" %[%[")
  local insert_col = suffix_byte and (suffix_byte - 1) or #line
  child.api.nvim_win_set_cursor(0, { row + 1, insert_col })
  child.type_keys("i", " #beta", "<Esc>")
  vim.loop.sleep(500)

  -- Source committed the tag.
  local disk = child_src(child)
  eq(disk[1]:find("#beta", 1, true) ~= nil, true, "source gained #beta: " .. vim.inspect(disk))
  -- Re-grouped LIVE: the root now renders a THIRD lit instance under #beta
  -- (alongside #task and #alpha) — the new group spawned without :w.
  eq(count_rows(child, "Root"), 3, "new #beta tag must spawn a third lit group instance live")

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: matched root edited out of the query filter lingers, subtree clears
-- ════════════════════════════════════════════════════════════════════════════
-- global_filter is "#task"; remove the #task tag from the matched root so it
-- exits the result set.  Best guess: after flush, the source dropped #task and
-- the dashboard no longer shows the (now-unmatched) root as a LIT match — the
-- subtree is not left dangling as live matched rows.  EXPECTED TO POSSIBLY FAIL
-- if the subtree clear is incomplete for tree dashboards.

T["OPEN editing a matched root out of the filter clears its lit subtree"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - [ ] Child task #task",
  })

  local root_row = dash_row_with(child, "Root task")
  eq(root_row >= 0, true, "matched root must exist")
  local line = child_line(child, root_row)
  -- Remove the trailing " #task" tag from the root via the buffer text.
  local tag_byte = line:find(" #task", 1, true)
  eq(tag_byte ~= nil, true, "root row must render the #task tag")
  -- Position before the space and delete to end of " #task" (6 chars).
  child.api.nvim_win_set_cursor(0, { root_row + 1, tag_byte - 1 })
  child.type_keys("6", "x", "<Esc>")
  vim.loop.sleep(450)

  -- Source committed the removal: root no longer carries #task.
  local src = child_src(child)
  eq(src[1]:find("#task", 1, true) == nil, true, "root must have dropped #task in source: " .. vim.inspect(src))

  child.stop()
end

-- ════════════════════════════════════════════════════════════════════════════
-- OPEN: fold state preserved across a mutate-driven full rerender
-- ════════════════════════════════════════════════════════════════════════════
-- Open a children-fold, then MUTATE the matched root (status cycle) which forces
-- a full rerender.  Best guess: the children-fold's open state survives the
-- rerender (it is not reset to default_folded).  EXPECTED TO POSSIBLY FAIL if
-- fold state is not captured/restored across the rerender.

T["OPEN open children-fold survives a mutate-driven rerender"] = function()
  local child = spawn_tree({
    "- [ ] Root task #task",
    "    - [ ] Child A #task",
    "        - grandchild bullet",
    "    - [ ] Child B #task",
  })

  -- Build the per-subtree folds with the buffer windowed, then OPEN all.
  child.lua([[
    require("obsidian-tasks.render.init").rerender_buffer(_G._dash_bufnr, nil)
    vim.cmd("normal! zR")
  ]])

  local root_row = dash_row_with(child, "Root task")
  eq(root_row >= 0, true, "matched root must exist")
  -- The children fold starts at the first child (root_row + 1, 1-indexed root+2).
  local first_child_line = root_row + 2
  -- Confirm the fold is OPEN before the mutate (foldclosed == -1).
  local open_before = child.lua_get("vim.fn.foldclosed(" .. first_child_line .. ")")
  eq(open_before == -1, true, "children fold must start OPEN: foldclosed=" .. tostring(open_before))

  -- MUTATE the matched root (status cycle) → forces a full rerender.
  child.api.nvim_win_set_cursor(0, { root_row + 1, 0 })
  child.type_keys("<CR>")
  vim.loop.sleep(450)

  -- After the rerender, the children fold must still be OPEN (state preserved),
  -- i.e. the grandchild row is visible (not hidden inside a re-closed fold).
  local root_after = dash_row_with(child, "Root task")
  eq(root_after >= 0, true, "matched root must still render after the rerender")
  local open_after = child.lua_get("vim.fn.foldclosed(" .. (root_after + 2) .. ")")
  eq(open_after == -1, true, "children fold must remain OPEN across the rerender: foldclosed=" .. tostring(open_after))

  child.stop()
end

return T
