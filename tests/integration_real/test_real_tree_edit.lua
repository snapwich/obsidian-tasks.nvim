-- tests/integration_real/test_real_tree_edit.lua
-- Real-mode `show tree` edit tests using MiniTest.new_child_neovim.
--
-- Phase 4 + 5a acceptance via genuine keypresses (nvim_input → mode() is really
-- 'i', vim.schedule fires between keystrokes, the InsertLeave drain is real):
--   • A nested TASK row edit-in-place writes through to its OWN source line.
--   • Phase 5a — a description BULLET row is EDITABLE in place: a body edit writes
--     back preserving the ORIGINAL marker ('*') and the raw 4-space source indent
--     byte-for-byte, changing only the body.
--   • Phase 5a — a bullet edited to add '[ ]' becomes a child TASK after refresh.
--   • Phase 5a — deleting a bullet row deletes its source line (literal delete).
--   • A BLANK row is still read-only: editing it reverts, no source write.
--
-- See CLAUDE.md: real insert-mode tests must drive a child nvim + type_keys.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- Source subtree written to disk.  The child + bullets are indented with FOUR
-- spaces (NOT the dashboard's 2-space depth indent) so the test exercises the
-- indent-separation invariant: write-back must preserve the original 4-space
-- source indent rather than overwrite it with the rendered depth-relative
-- 2-space indent.  The description bullet uses a '*' marker (NOT '-') so the
-- Phase-5a marker round-trip is exercised; a blank line and a trailing bullet
-- ride along so the blank-read-only path can be checked too.
--   1  - [ ] Root task #task
--   2      - [ ] Child task #task     (4-space source indent)
--   3      * a description bullet      (4-space source indent, '*' marker)
--   4                                  (blank, interior)
--   5      + trailing bullet           (4-space source indent, '+' marker)
local SRC_CONTENT = {
  "- [ ] Root task #task",
  "    - [ ] Child task #task",
  "    * a description bullet",
  "",
  "    + trailing bullet",
}

--- Boot a child nvim with a real `show tree` dashboard backed by *content*
--- (defaults to SRC_CONTENT).  The index is stubbed to return the root as the
--- matched task and nodes_for to return the parsed subtree, exercising the real
--- run→layout→draw→fold path.
local function spawn_tree_dashboard(content)
  content = content or SRC_CONTENT
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
    [[(function(src_content)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_content, src)

    local index = require("obsidian-tasks.index")
    local nodes_mod = require("obsidian-tasks.index.nodes")
    local task_parse = require("obsidian-tasks.task.parse")

    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.refresh_all = function(_, on_done) if on_done then on_done() end end
    -- nodes_for: parse the LIVE source file so edits round-trip on rerender.
    index.nodes_for = function(p)
      if p == src then
        local ok, lines = pcall(vim.fn.readfile, src)
        return nodes_mod.parse_lines(ok and lines or src_content)
      end
      return {}
    end
    -- tasks_in: the matched left-most task is the root (line 1).
    index.tasks_in = function()
      local i = 0
      return function()
        i = i + 1
        if i == 1 then
          local ok, lines = pcall(vim.fn.readfile, src)
          local t = task_parse.parse((ok and lines[1]) or src_content[1])
          return t, src, 1
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
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src
    return src
  end)(...)]],
    { content }
  )

  return child
end

local function child_line(child, row0)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row0 .. ", " .. row0 + 1 .. ", false)[1]")
end

local function child_src(child)
  return child.lua_get("vim.fn.readfile(_G._src_path)")
end

-- Buffer rows (0-indexed): 0 fence, 1 query, 2 fence,
--   3 root task, 4 child task, 5 '*' description bullet, 6 blank,
--   7 '+' trailing bullet.
local ROOT_ROW = 3
local CHILD_ROW = 4
local BULLET_ROW = 5
local BLANK_ROW = 6

-- ── nested TASK row edit-in-place → writes to its own source line ─────────────

T["nested child task: ciw edit writes through to the child's source line"] = function()
  local child = spawn_tree_dashboard()

  -- Confirm the child task rendered nested with the dashboard's depth-relative
  -- 2-space indent (NOT the 4-space source indent).
  local child_row_text = child_line(child, CHILD_ROW)
  eq(child_row_text:sub(1, #"  - [ ] Child"), "  - [ ] Child")

  -- Cursor on the 'C' of "Child" — "  - [ ] " is 8 chars in the dashboard.
  child.api.nvim_win_set_cursor(0, { CHILD_ROW + 1, 8 })
  child.type_keys("c", "i", "w", "Walk", "<Esc>")
  vim.loop.sleep(250)

  local src = child_src(child)
  -- The CHILD's source line (line 2) must reflect the edit; root (line 1) intact.
  eq(src[1], "- [ ] Root task #task", "root source line must be untouched")
  eq(src[2]:find("Walk") ~= nil, true, "child source line must reflect the edit: " .. tostring(src[2]))
  -- MAJOR-3: the child's ORIGINAL 4-space source indent must be byte-identical
  -- after the body edit — the dashboard's 2-space render indent must NOT leak in.
  eq(src[2]:sub(1, 4), "    ", "child must keep its 4-space source indent: [" .. tostring(src[2]) .. "]")
  eq(src[2]:sub(1, #"    - [ ] "), "    - [ ] ", "child must keep its full source prefix")
  eq(src[2]:sub(1, 5) ~= "  - [", true, "child must NOT be rewritten with the dashboard's 2-space indent")

  child.stop()
end

-- ── structural repair on a 4-space nested child → marker after the indent ─────

T["nested child task: deleting '- ' triggers repair that preserves the 4-space source indent"] = function()
  local child = spawn_tree_dashboard()

  -- The child renders with the dashboard's depth-relative 2-space indent:
  --   "  - [ ] Child task #task"
  local child_row_text = child_line(child, CHILD_ROW)
  eq(child_row_text:sub(1, #"  - [ ] Child"), "  - [ ] Child")

  -- Delete the "- " structural marker from the dashboard child row in ONE atomic
  -- normal-mode command (2x).  After the 2-space depth indent, "- " occupies
  -- cols 2-3; removing both leaves "  [ ] Child task #task" (checkbox present,
  -- bullet missing → REPAIR_AND_MUTATE).  A single 2x is required because each
  -- normal-mode edit flushes immediately: two separate `x` keystrokes would let
  -- the first one's repair re-splice + shift the cursor before the second fires.
  child.api.nvim_win_set_cursor(0, { CHILD_ROW + 1, 2 })
  child.type_keys("2", "x", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  -- (1) SOURCE: repaired to a well-formed task with the 4-space indent preserved
  -- byte-for-byte — the marker MUST land AFTER the indent, never before it.
  eq(src[1], "- [ ] Root task #task", "root source line must be untouched")
  eq(
    src[2]:sub(1, #"    - [ ] "),
    "    - [ ] ",
    "child must be repaired with marker AFTER its 4-space indent: [" .. tostring(src[2]) .. "]"
  )
  eq(src[2]:find("Child task") ~= nil, true, "child body must survive the repair: " .. tostring(src[2]))
  eq(src[2]:sub(1, 1) ~= "-", true, "marker must NOT precede the indent (no '-     [ ] ...'): " .. tostring(src[2]))

  -- (2) DASHBOARD: the child row must NOT be empty/garbled; it shows the repaired
  -- task at its depth indent ("  - [ ] Child ...").
  local child_after = child_line(child, CHILD_ROW)
  eq(child_after ~= nil and child_after ~= "", true, "dashboard child row must not be empty: " .. tostring(child_after))
  eq(
    child_after:sub(1, #"  - [ ] Child"),
    "  - [ ] Child",
    "dashboard child row must show the repaired task at depth indent: [" .. tostring(child_after) .. "]"
  )

  child.stop()
end

-- ── Phase 5a: editable BULLET — body edit preserves marker + 4-space indent ──

T["bullet: ciw body edit writes back, preserving '*' marker and 4-space indent"] = function()
  local child = spawn_tree_dashboard()

  -- The bullet renders with its ORIGINAL '*' marker at the dashboard's
  -- depth-relative 2-space indent (NOT a synthesized '-', NOT the 4-space src).
  local canonical_bullet = child_line(child, BULLET_ROW)
  eq(
    canonical_bullet:sub(1, #"  * a description"),
    "  * a description",
    "bullet must render its '*' marker at depth indent: [" .. tostring(canonical_bullet) .. "]"
  )

  -- Edit the bullet row: ciw to replace "description" with "HACKED".
  -- "  * a " is 6 chars; "description" starts at col 6.
  child.api.nvim_win_set_cursor(0, { BULLET_ROW + 1, 6 })
  child.type_keys("c", "i", "w", "HACKED", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 5, "source line count must not change (in-place edit)")
  eq(src[1], "- [ ] Root task #task", "root source line must be untouched")
  eq(src[2], "    - [ ] Child task #task", "child source line must be untouched")
  -- The bullet's source line reflects ONLY the body edit: original '*' marker and
  -- 4-space indent are byte-identical; "description" is now "HACKED".
  eq(src[3]:find("HACKED") ~= nil, true, "bullet source must reflect the edit: " .. tostring(src[3]))
  eq(src[3]:find("description") == nil, true, "old body word must be gone: " .. tostring(src[3]))
  eq(src[3], "    * a HACKED bullet", "bullet must round-trip marker + 4-space indent: [" .. tostring(src[3]) .. "]")

  child.stop()
end

-- ── Phase 5a: bullet edited to add '[ ]' becomes a child TASK after refresh ───

T["bullet → checkbox: adding '[ ]' writes raw and reclassifies as a task"] = function()
  local child = spawn_tree_dashboard()

  -- Insert "[ ] " right after the "* " marker so the line becomes "* [ ] ...".
  -- Dashboard row: "  * a description bullet"; after the marker+space (col 4) we
  -- insert a checkbox.  We replace the whole body to keep the edit deterministic.
  child.api.nvim_win_set_cursor(0, { BULLET_ROW + 1, 0 })
  -- cc to clear the line, then type the full checkbox-bullet form at depth indent.
  child.type_keys("c", "c", "  * [ ] now a task", "<Esc>")
  vim.loop.sleep(350)

  local src = child_src(child)
  -- The raw write lands a '* [ ]' line at the original 4-space source indent.
  eq(
    src[3],
    "    * [ ] now a task",
    "bullet→checkbox must write raw with 4-space indent: [" .. tostring(src[3]) .. "]"
  )

  -- After re-index/parse, the line classifies as a TASK (has a checkbox).
  local kind = child.lua_get([[(function()
    local nodes = require("obsidian-tasks.index.nodes")
    local lines = vim.fn.readfile(_G._src_path)
    local ns = nodes.parse_lines(lines)
    for _, n in ipairs(ns) do
      if n.line_num == 3 then return n.kind end
    end
    return "?"
  end)()]])
  eq(kind, "task", "the edited line must reclassify as a child task")

  child.stop()
end

-- ── Phase 5a: deleting a bullet row deletes its source line ───────────────────

T["bullet delete: dd on the bullet row deletes its source line"] = function()
  local child = spawn_tree_dashboard()

  local src_before = child_src(child)
  eq(#src_before, 5)
  eq(src_before[3], "    * a description bullet")

  -- dd on the bullet dashboard row → literal source-line delete.
  child.api.nvim_win_set_cursor(0, { BULLET_ROW + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(350)

  local src_after = child_src(child)
  -- The bullet's source line is gone; surrounding lines intact.
  eq(#src_after, 4, "exactly one source line must be deleted: " .. vim.inspect(src_after))
  eq(src_after[1], "- [ ] Root task #task", "root must survive")
  eq(src_after[2], "    - [ ] Child task #task", "child must survive")
  -- The '*' description bullet line must no longer be present anywhere.
  local found = false
  for _, l in ipairs(src_after) do
    if l == "    * a description bullet" then
      found = true
    end
  end
  eq(found, false, "deleted bullet line must be gone from source")

  child.stop()
end

-- ── MAJOR-1: non-canonical on-disk bullet spacing must NOT silently drop ──────
--
-- The dashboard renders a bullet canonically (marker + single space) regardless
-- of the on-disk spacing, so the cursor math is identical to the canonical case.
-- But the on-disk line carries either trailing spaces or multiple post-marker
-- spaces.  Before the fix, layout used a TRIMMED reconstruction
-- (indent..marker.." "..body) as the locate target, so M.locate's exact match
-- failed against the real disk line → locate_miss → the edit/delete was dropped
-- with no write and no warning.  With node.source_line threaded through as the
-- verbatim locate target, the edit now writes through.

-- Disk has TRAILING spaces after the bullet body.
local SRC_TRAILING = {
  "- [ ] Root task #task",
  "    - [ ] Child task #task",
  "    * a description bullet   ", -- trailing spaces on disk
  "",
  "    + trailing bullet",
}

-- Disk has MULTIPLE spaces between marker and body.
local SRC_MULTISPACE = {
  "- [ ] Root task #task",
  "    - [ ] Child task #task",
  "    *   a description bullet", -- three spaces after '*'
  "",
  "    + trailing bullet",
}

T["bullet with TRAILING spaces on disk: body edit writes through (not dropped)"] = function()
  local child = spawn_tree_dashboard(SRC_TRAILING)

  -- Dashboard still renders canonically: "  * a description bullet".
  local canonical_bullet = child_line(child, BULLET_ROW)
  eq(
    canonical_bullet:sub(1, #"  * a description"),
    "  * a description",
    "bullet must render canonically despite disk trailing spaces: [" .. tostring(canonical_bullet) .. "]"
  )

  -- ciw to replace "description" with "HACKED" (col 6 as in the canonical test).
  child.api.nvim_win_set_cursor(0, { BULLET_ROW + 1, 6 })
  child.type_keys("c", "i", "w", "HACKED", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 5, "source line count must not change (in-place edit)")
  eq(src[1], "- [ ] Root task #task", "root source line must be untouched")
  eq(src[2], "    - [ ] Child task #task", "child source line must be untouched")
  -- The edit MUST have written through (not silently dropped on locate_miss).
  eq(src[3]:find("HACKED") ~= nil, true, "bullet edit must write through, not be dropped: " .. tostring(src[3]))
  eq(src[3]:find("description") == nil, true, "old body word must be gone: " .. tostring(src[3]))
  -- Write-back canonicalizes marker-to-body spacing (acceptable); body changed.
  eq(src[3], "    * a HACKED bullet", "bullet must write through with 4-space indent: [" .. tostring(src[3]) .. "]")

  child.stop()
end

T["bullet with MULTIPLE post-marker spaces on disk: body edit writes through"] = function()
  local child = spawn_tree_dashboard(SRC_MULTISPACE)

  local canonical_bullet = child_line(child, BULLET_ROW)
  eq(
    canonical_bullet:sub(1, #"  * a description"),
    "  * a description",
    "bullet must render canonically despite multiple disk spaces: [" .. tostring(canonical_bullet) .. "]"
  )

  child.api.nvim_win_set_cursor(0, { BULLET_ROW + 1, 6 })
  child.type_keys("c", "i", "w", "HACKED", "<Esc>")
  vim.loop.sleep(300)

  local src = child_src(child)
  eq(#src, 5, "source line count must not change (in-place edit)")
  eq(src[3]:find("HACKED") ~= nil, true, "bullet edit must write through, not be dropped: " .. tostring(src[3]))
  eq(src[3]:find("description") == nil, true, "old body word must be gone: " .. tostring(src[3]))
  eq(src[3], "    * a HACKED bullet", "bullet must write through with canonical spacing: [" .. tostring(src[3]) .. "]")

  child.stop()
end

T["bullet with TRAILING spaces on disk: dd deletes its source line (not dropped)"] = function()
  local child = spawn_tree_dashboard(SRC_TRAILING)

  local src_before = child_src(child)
  eq(#src_before, 5)
  eq(src_before[3], "    * a description bullet   ", "disk line carries trailing spaces")

  child.api.nvim_win_set_cursor(0, { BULLET_ROW + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(350)

  local src_after = child_src(child)
  -- The delete MUST have applied (locate matched the verbatim disk line).
  eq(#src_after, 4, "exactly one source line must be deleted (delete not dropped): " .. vim.inspect(src_after))
  eq(src_after[1], "- [ ] Root task #task", "root must survive")
  eq(src_after[2], "    - [ ] Child task #task", "child must survive")
  -- The bullet line (with its trailing spaces) must be gone from source.
  local found = false
  for _, l in ipairs(src_after) do
    if l:find("a description bullet") then
      found = true
    end
  end
  eq(found, false, "deleted bullet line must be gone from source")

  child.stop()
end

-- ── BLANK row stays read-only: editing it reverts, no source write ────────────

T["read-only blank: editing a blank row reverts and never writes to source"] = function()
  local child = spawn_tree_dashboard()

  -- The blank row renders empty.
  local canonical_blank = child_line(child, BLANK_ROW)
  eq(canonical_blank, "", "blank row must render empty: [" .. tostring(canonical_blank) .. "]")

  local src_before = child_src(child)
  eq(#src_before, 5)

  -- Type into the blank row.
  child.api.nvim_win_set_cursor(0, { BLANK_ROW + 1, 0 })
  child.type_keys("c", "c", "INTRUDER", "<Esc>")
  vim.loop.sleep(350)

  -- Source must be COMPLETELY untouched (blank rows are read-only).
  local src_after = child_src(child)
  eq(#src_after, 5, "source line count must not change (blank is read-only)")
  eq(src_after[1], "- [ ] Root task #task")
  eq(src_after[2], "    - [ ] Child task #task")
  eq(src_after[3], "    * a description bullet")
  eq(src_after[4], "", "the source blank line must be untouched")
  eq(src_after[5], "    + trailing bullet")

  -- The dashboard blank row reverted to empty (no stray "INTRUDER").
  local blank_after = child_line(child, BLANK_ROW)
  eq(blank_after, "", "blank row must revert to empty: [" .. tostring(blank_after) .. "]")

  child.stop()
end

return T
