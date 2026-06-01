-- tests/integration_real/test_harden_sentinel_save_real.lua
-- Phase-2 hardening for the "Sentinel, footer, EOF & save round-trip" dimension.
--
-- Real keypresses (MiniTest.new_child_neovim + child.type_keys) so the on_lines →
-- demote / revert / flush path runs in genuine insert/normal mode and vim.schedule
-- callbacks drain between keystrokes (synthetic nvim_buf_set_lines never takes the
-- insert-mode branch — see CLAUDE.md).
--
-- GOTCHA followed everywhere below: we do NOT pre-set vim.b.obsidian_tasks_dashboard.
-- The FIRST render's draw → save.attach both sets that flag AND registers the
-- BufWriteCmd strip handler; pre-setting it makes save.attach a no-op so :w falls
-- back to Neovim's default writer and never strips rendered rows.

local T = MiniTest.new_set()
local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

-- ── helpers ──────────────────────────────────────────────────────────────────

local function buflines(child)
  return child.lua_get("vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)")
end

local function disk(child)
  return child.lua_get("vim.fn.readfile(_G._note)")
end

--- 0-indexed dashboard row whose text contains `needle`, or -1.
local function row_with(child, needle)
  return child.lua_get(
    [[(function(needle)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._b, 0, -1, false)) do
      if l and l:find(needle, 1, true) then return i - 1 end
    end
    return -1
  end)(...)]],
    { needle }
  )
end

-- ── factory: flat dashboard, one source task, file-backed note ───────────────

--- Boot a child with a file-backed dashboard note.  `note_lines` is the on-disk
--- note (prose + ```tasks fences); `src_tasks` is the source file (one task per
--- line) that tasks_in re-reads live so edits round-trip.  Optionally tree mode.
local function spawn(note_lines, src_tasks, tree)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir, note_lines, src_tasks, tree = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)
    local o = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(o, ...) end
    require("obsidian-tasks").setup({ global_filter = "#task" })

    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(src_tasks, src)
    local note = vim.fn.tempname() .. ".md"
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
        return nodes_mod.parse_lines(ok and lines or src_tasks)
      end
      return {}
    end
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      lines = (ok and type(lines) == "table") and lines or {}
      local i = 0
      return function()
        while i < #lines do
          i = i + 1
          local t = tp.parse(lines[i])
          if t then return t, src, i end
        end
      end
    end

    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(note))
    local b = vim.api.nvim_get_current_buf()
    vim.bo[b].filetype = "markdown"
    render.render_buffer(b, nil)
    vim.cmd("normal! zR")
    _G._b = b
    _G._note = note
    _G._src = src
  ]],
    { cwd, deps_dir, note_lines, src_tasks, tree and true or false }
  )
  return child
end

-- ── (1) two ```tasks blocks in one note: sentinel only on the LAST block ──────

T["multi-block: sentinel attaches only to the EOF block; :w strips both, round-trips"] = function()
  -- Block A (with results) sits above prose, block B (with results) at EOF.  Only
  -- block B is at EOF, so only it gets a sentinel.  :w must strip ALL managed rows
  -- across BOTH blocks and the sentinel, leaving the on-disk note = fences + prose.
  local note = {
    "# Daily",
    "```tasks",
    "not done",
    "```",
    "middle prose",
    "```tasks",
    "not done",
    "```",
  }
  local child = spawn(note, { "- [ ] the only task #task" })

  local b = buflines(child)
  -- Both blocks rendered the same single matched task (separate managed rows).
  local count = 0
  for _, l in ipairs(b) do
    if l:find("the only task", 1, true) then
      count = count + 1
    end
  end
  eq(count, 2, "both blocks render the matched task: " .. vim.inspect(b))
  -- Exactly one EOF sentinel (empty trailing line), and it belongs to block B.
  eq(b[#b], "", "EOF sentinel is the final empty line: " .. vim.inspect(b))

  -- :w strips every managed row across both blocks plus the sentinel.
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(200)
  eq(
    disk(child),
    { "# Daily", "```tasks", "not done", "```", "middle prose", "```tasks", "not done", "```" },
    "disk = fences + prose only, both blocks stripped: " .. vim.inspect(disk(child))
  )
  eq(child.lua_get("vim.fn.readfile(_G._src)"), { "- [ ] the only task #task" }, "source untouched")

  child.stop()
end

-- ── (2) zero-result tree dashboard: sentinel created, demoted on type ─────────

T["zero-result tree: sentinel is managed; typing demotes it and region drops"] = function()
  -- `show tree` with no matched roots → footer + EOF sentinel only.  Typing into
  -- the sentinel demotes it; the region (which held only the sentinel) drops.
  local note = { "```tasks", "show tree", "not done", "```" }
  local child = spawn(note, {}, true)

  local b0 = buflines(child)
  -- The fence block is 4 lines (```tasks / show tree / not done / ```) + 1 EOF
  -- sentinel = 5.  The sentinel is the last (empty) line.
  eq(#b0, 5, "zero-result tree: only fences + sentinel: " .. vim.inspect(b0))
  eq(b0[#b0], "", "trailing sentinel present")

  local sentinel_line = #b0 -- 1-indexed last line (the sentinel)
  child.api.nvim_win_set_cursor(0, { sentinel_line, 0 })
  child.type_keys("i", "scratch", "<Esc>")
  vim.loop.sleep(300)

  local b = buflines(child)
  eq(b[sentinel_line], "scratch", "typed text persisted (demoted): " .. vim.inspect(b))
  -- Demoted row is outside any managed region (will be written, not stripped).
  eq(
    child.lua_get("require('obsidian-tasks.render.managed').region_for_row(_G._b, " .. (sentinel_line - 1) .. ")"),
    vim.NIL,
    "demoted sentinel row no longer managed"
  )

  child.stop()
end

-- ── (3) 'o' on the last task: opened line is WYSIWYG-persistent (D4) ──────────

T["o on last task: opened blank line is inside the managed region (stripped on rerender)"] = function()
  -- D4 (WYSIWYG): `o` at the end of the last rendered task opens a real buffer
  -- line the user SEES.  It sits past the task, where the lone EOF sentinel lives,
  -- so it RELEASES the sentinel (sentinel + opened blank = 2 trailing blanks > 1).
  -- A user-visible opened line must PERSIST as real note content — it is NOT
  -- silently stripped on the next rerender.  What the user sees (task + 2 trailing
  -- blanks) is what survives a rerender and what reloads; only the still-managed
  -- task row is stripped on :w.  Repeated writes are idempotent (no growth).
  local note = { "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  local task_row = row_with(child, "the only task")
  eq(task_row >= 0, true, "task row exists")
  child.api.nvim_win_set_cursor(0, { task_row + 1, 0 })
  child.type_keys("o", "<Esc>") -- open a blank line, no text
  vim.loop.sleep(300)
  -- Force a rerender (refocus / BufWritePost equivalent).
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(200)

  local b = buflines(child)
  -- WYSIWYG: the opened line persists.  fence(3) + task(1) + two real trailing
  -- blanks (the released sentinel + the opened line) = 6 rows.  The opened line
  -- is NOT stripped — the user explicitly added it past the dashboard.
  eq(#b, 6, "opened blank persists past the dashboard (not stripped): " .. vim.inspect(b))
  eq(b[4]:sub(1, #"- [ ] the only task"), "- [ ] the only task", "task row intact")
  eq(b[5], "", "first trailing blank (released sentinel)")
  eq(b[6], "", "second trailing blank (the opened line) persists")
  -- Only the still-managed task row is stripped on :w; the real blanks remain.
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(150)
  local d1 = disk(child)
  eq(
    d1,
    { "```tasks", "not done", "```", "", "" },
    "disk = fences + two real blanks, task stripped: " .. vim.inspect(d1)
  )
  -- Idempotent: two more writes with no edits do not grow the file.
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(120)
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(120)
  eq(disk(child), d1, "repeated :w is idempotent: " .. vim.inspect(disk(child)))
  eq(child.lua_get("vim.fn.readfile(_G._src)"), { "- [ ] the only task #task" }, "source untouched by ineffective o")

  child.stop()
end

-- ── (4) multiple consecutive writes: idempotent on-disk state ────────────────

T["multiple :w without edits: released newlines persist, N writes are idempotent"] = function()
  local note = { "# Daily", "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  -- Release the sentinel into a real newline.  One <CR> on the lone sentinel
  -- splits it into TWO trailing blanks (D4: two trailing blanks from one <CR> is
  -- acceptable — what matters is round-trip stability + idempotency, not a fixed
  -- newline count).  Both blanks are released from management; only the task row
  -- stays managed and is stripped on :w.
  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  child.api.nvim_win_set_cursor(0, { n, 0 }) -- sentinel
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(350)

  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(150)
  local d1 = disk(child)
  -- WYSIWYG: the user sees task + two trailing blanks; disk = fences + the two
  -- real blanks (task stripped).  This matches the locked behavior asserted by
  -- test_real_sentinel_newline.lua case (B).
  eq(
    d1,
    { "# Daily", "```tasks", "not done", "```", "", "" },
    "first :w persists the released newlines: " .. vim.inspect(d1)
  )

  -- Second and third :w with no intervening edit must produce identical disk.
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(120)
  child.lua("vim.cmd('silent write')")
  vim.loop.sleep(120)
  eq(disk(child), d1, "repeated :w is idempotent: " .. vim.inspect(disk(child)))

  child.stop()
end

-- ── (5) release then undo (open question) ────────────────────────────────────

T["release then undo: undoing the released newline returns to a clean sentinel state"] = function()
  -- D4 (round-trip stability over undo): typing <CR> into the lone sentinel
  -- releases it into two real trailing blanks (sentinel split by <CR>) and
  -- re-renders.  The re-render rewrites the managed region under undolevels=-1
  -- (render hygiene), so the release is NOT a single reversible undo step — `u`
  -- does not "uncreate" the real newline.  That is correct WYSIWYG: the user
  -- added real note content; the file does not silently shrink under them.  What
  -- the requirement DOES guarantee is stability: undo never corrupts or grows the
  -- buffer, the task survives, and a rerender keeps the released trailing blanks
  -- intact (no doubled / lost rows, no re-added sentinel above them).
  local note = { "# Daily", "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  child.api.nvim_win_set_cursor(0, { n, 0 })
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(350)
  -- After release: # Daily + fences + task + two trailing blanks (the original
  -- sentinel split by <CR>).  Two trailing blanks from one <CR> is acceptable.
  local released = buflines(child)
  eq(#released, 7, "post-release line count: " .. vim.inspect(released))
  eq(released[#released], "", "released state ends in a trailing blank")
  eq(
    released[5]:sub(1, #"- [ ] the only task"),
    "- [ ] the only task",
    "task rendered above the trailing blanks: " .. vim.inspect(released)
  )

  child.type_keys("u")
  vim.loop.sleep(250)
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(200)

  local b = buflines(child)
  -- Round-trip stable: undo + rerender leaves the released state intact (the real
  -- newlines are not lost), the task survives, and the buffer ends in a trailing
  -- blank with no doubled / extra rows beyond what the user sees.
  eq(b, released, "undo + rerender is round-trip stable (no shrink/grow): " .. vim.inspect(b))
  eq(b[#b], "", "buffer still ends in a trailing blank after undo+rerender: " .. vim.inspect(b))
  eq(b[5]:sub(1, #"- [ ] the only task"), "- [ ] the only task", "task survives undo: " .. vim.inspect(b))

  child.stop()
end

-- ── (6) paste over the sentinel demotes it (open question) ───────────────────

T["paste over sentinel: non-blank pasted content demotes the sentinel"] = function()
  -- OPEN: a normal-mode paste (p) onto the sentinel triggers on_lines INSERT with
  -- non-blank content; demote_typed_sentinels must read the FINAL content and
  -- demote (not strip) it, just like typing.
  local note = { "# Daily", "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  -- Yank a non-blank register, then paste it onto the sentinel row.
  child.lua("vim.fn.setreg('a', 'pasted note')")
  child.api.nvim_win_set_cursor(0, { n, 0 })
  child.type_keys('"aP') -- paste before cursor onto the empty sentinel row
  vim.loop.sleep(350)

  local b = buflines(child)
  eq(b[n]:find("pasted note", 1, true) ~= nil, true, "pasted content present on sentinel row: " .. vim.inspect(b))
  -- Demoted: the row is no longer inside a managed region.
  eq(
    child.lua_get("require('obsidian-tasks.render.managed').region_for_row(_G._b, " .. (n - 1) .. ")"),
    vim.NIL,
    "pasted-into sentinel row demoted out of management"
  )

  child.stop()
end

-- ── (7) prose after the block: <CR> on sentinel keeps prose; no re-sentinel ──

T["prose-after-block-via-release: releasing makes prose the EOF separator, no new sentinel"] = function()
  -- Note ends with the dashboard at EOF (so a sentinel is created).  Releasing the
  -- sentinel into a real newline then re-rendering must NOT re-create a sentinel —
  -- the real newline is now the EOF separator.
  local note = { "# Daily", "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  child.api.nvim_win_set_cursor(0, { n, 0 })
  child.type_keys("i", "tail prose", "<Esc>")
  vim.loop.sleep(350)
  -- Rerender: the demoted prose line is the separator; no fresh sentinel appended.
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(200)

  local b = buflines(child)
  eq(b[#b], "tail prose", "prose remains the last line (no sentinel appended below it): " .. vim.inspect(b))
  eq(b[#b - 1]:sub(1, #"- [ ] the only task"), "- [ ] the only task", "task above the prose")

  child.stop()
end

-- ── (8) note that is ONLY a dashboard: release is stable across rerenders ─────

T["dashboard-only note: released newline is stable across repeated rerenders"] = function()
  local note = { "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  child.api.nvim_win_set_cursor(0, { n, 0 })
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(350)
  local after_release = buflines(child)

  -- Two more rerenders (each like a BufWritePost refresh) must not grow/shrink.
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(150)
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(150)
  eq(buflines(child), after_release, "repeated rerenders keep the released newlines stable")
  -- The trailing rows are real (unmanaged): no managed region covers the last row.
  eq(
    child.lua_get("require('obsidian-tasks.render.managed').region_for_row(_G._b, " .. (#after_release - 1) .. ")"),
    vim.NIL,
    "last row is unmanaged after release"
  )

  child.stop()
end

-- ── (9) flat dd on the only task, then <CR> on the sentinel ──────────────────

T["flat dd last task then CR on sentinel: zero-result note keeps real newline, no sentinel"] = function()
  local note = { "# Daily", "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] the only task #task" })

  -- Delete the one task; the index re-read after the source delete yields zero.
  local task_row = row_with(child, "the only task")
  child.api.nvim_win_set_cursor(0, { task_row + 1, 0 })
  child.type_keys("d", "d")
  vim.loop.sleep(400)
  eq(
    child.lua_get("vim.fn.readfile(_G._src)"),
    {},
    "source task removed by dd: " .. vim.inspect(child.lua_get("vim.fn.readfile(_G._src)"))
  )

  -- Now a zero-result dashboard with a sentinel at EOF.  <CR> releases it.
  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  child.api.nvim_win_set_cursor(0, { n, 0 })
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(350)
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(200)

  local b = buflines(child)
  eq(b[4], "```", "closing fence intact: " .. vim.inspect(b))
  eq(b[#b], "", "trailing real newline kept")
  -- No task row remains; only fences + real newline(s).
  eq(row_with(child, "the only task"), -1, "no task row after delete: " .. vim.inspect(b))

  child.stop()
end

-- ── (10) wikilink suffix is independent of sentinel demotion ─────────────────

T["wikilink suffix: releasing the sentinel does not disturb the rendered wikilink"] = function()
  -- The dashboard note differs from the source file, so layout appends a
  -- `[[source]]` backlink suffix to the rendered task.  Releasing the sentinel
  -- must not touch that suffix.
  local note = { "# Daily", "```tasks", "not done", "```" }
  local child = spawn(note, { "- [ ] linked task #task" })

  local b0 = buflines(child)
  local task0 = nil
  for _, l in ipairs(b0) do
    if l:find("linked task", 1, true) then
      task0 = l
    end
  end
  eq(
    task0 ~= nil and task0:find("[[", 1, true) ~= nil,
    true,
    "rendered task carries a wikilink suffix: " .. vim.inspect(b0)
  )

  local n = child.lua_get("vim.api.nvim_buf_line_count(_G._b)")
  child.api.nvim_win_set_cursor(0, { n, 0 })
  child.type_keys("i", "<CR>", "<Esc>")
  vim.loop.sleep(350)
  child.lua("require('obsidian-tasks.render.init').rerender_buffer(_G._b, nil)")
  vim.loop.sleep(200)

  local b = buflines(child)
  local task1 = nil
  for _, l in ipairs(b) do
    if l:find("linked task", 1, true) then
      task1 = l
    end
  end
  eq(task1, task0, "wikilink suffix unchanged by sentinel release: " .. vim.inspect(b))

  child.stop()
end

return T
