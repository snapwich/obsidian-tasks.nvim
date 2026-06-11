-- tests/integration/test_query_ast_cache.lua
-- Per-block query AST cache (render/init.lua M._query_cache).
--
-- Verifies, by spying on query_parse.parse:
--   • First render parses each block's query text.
--   • Re-rendering with unchanged query text does NOT re-parse (cache hit).
--   • Editing the query text invalidates the cache → re-parse.
--   • Per-block: only the edited block re-parses in a multi-block buffer.
--   • A thrown parse is never cached, so fixing the query text re-parses
--     instead of replaying a stale failure.
--
-- The user-visible stale-results contract is separately guarded by
-- tests/integration_real/test_rerender_guards.lua ("editing query text then
-- rerendering reflects the new query").

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local query_parse = require("obsidian-tasks.query.parse")
local task_parse = require("obsidian-tasks.task.parse")

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Install an index stub so render runs without a real vault.
--- Returns a restore function.
local function install_index_stub()
  local index_mod = require("obsidian-tasks.index")
  local saved_tasks_in = index_mod.tasks_in
  local saved_set = index_mod.set_render_paths
  local saved_clear = index_mod.clear_render_paths
  local saved_reverse = index_mod.reverse_index

  local t = task_parse.parse("- [ ] cached task A")
  local rows = { { task = t, path = "/vault/a.md", line_nr = 1 } }
  index_mod.tasks_in = function(_)
    local i = 0
    return function()
      i = i + 1
      local row = rows[i]
      if not row then
        return nil
      end
      return row.task, row.path, row.line_nr
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  index_mod.reverse_index = function()
    return {}
  end

  return function()
    index_mod.tasks_in = saved_tasks_in
    index_mod.set_render_paths = saved_set
    index_mod.clear_render_paths = saved_clear
    index_mod.reverse_index = saved_reverse
  end
end

--- Install a counting spy on query_parse.parse.  Queries containing the
--- string "FORCE_PARSE_ERROR" throw (simulates an exception escaping parse).
--- Returns (counts table, restore function); counts.n is the call count.
local function install_parse_spy()
  local real_parse = query_parse.parse
  local counts = { n = 0 }
  query_parse.parse = function(text)
    counts.n = counts.n + 1
    if text:find("FORCE_PARSE_ERROR", 1, true) then
      error("forced parse failure for test")
    end
    return real_parse(text)
  end
  return counts, function()
    query_parse.parse = real_parse
  end
end

--- Replace the query line (buffer row 2, 0-indexed 1) of a single-block
--- dashboard.  Suppress the on_lines revert listener — this is a stand-in
--- for a user edit, not a plugin mutation we want classified.
local function set_query_line(bufnr, row0, text)
  require("obsidian-tasks.render.revert").with_suppressed(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { text })
  end)
end

local function buf_has(bufnr, needle)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Error/header/footer rows are rendered as virt_lines extmarks (not buffer
--- text) — scan the draw namespace's virt_lines chunks for *needle*.
local function virt_has(bufnr, needle)
  local ns = require("obsidian-tasks.util.extmark").NS
  local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })
  for _, mark in ipairs(marks) do
    for _, vl in ipairs((mark[4] and mark[4].virt_lines) or {}) do
      for _, chunk in ipairs(vl) do
        if type(chunk[1]) == "string" and chunk[1]:find(needle, 1, true) then
          return true
        end
      end
    end
  end
  return false
end

local function cleanup(bufnr, ...)
  render._lingers[bufnr] = nil
  render._pending_lingers[bufnr] = nil
  render._query_cache[bufnr] = nil
  vim.api.nvim_buf_delete(bufnr, { force = true })
  for _, restore in ipairs({ ... }) do
    restore()
  end
end

render.configure({ default_folded = true })

-- ── Tests ─────────────────────────────────────────────────────────────────────

T["unchanged query text is parsed once across renders; edit re-parses"] = function()
  local restore_index = install_index_stub()
  local counts, restore_spy = install_parse_spy()

  local bufnr = make_buf({ "```tasks", "not done", "```" })

  local ok, err = pcall(function()
    -- 1. First render parses.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 1)
    eq(buf_has(bufnr, "cached task A"), true)

    -- 2. Rerender with unchanged text: cache hit, NO new parse — covers
    --    FocusGained / BufWritePost / post-toggle rerender triggers.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 1)
    render.rerender_buffer(bufnr, nil)
    eq(counts.n, 1)
    eq(buf_has(bufnr, "cached task A"), true)

    -- 3. Edit the query text: cache invalidated, parse runs again and the
    --    new query takes effect (done ⇒ stub's Todo task disappears).
    set_query_line(bufnr, 1, "done")
    render.render_buffer(bufnr, nil)
    eq(counts.n, 2)
    eq(buf_has(bufnr, "cached task A"), false)

    -- 4. Rerender of the NEW text is again a cache hit.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 2)
  end)

  cleanup(bufnr, restore_spy, restore_index)
  if not ok then
    error(err)
  end
end

T["cache is per block: editing one block re-parses only that block"] = function()
  local restore_index = install_index_stub()
  local counts, restore_spy = install_parse_spy()

  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "",
    "```tasks",
    "done",
    "```",
  })

  local ok, err = pcall(function()
    render.render_buffer(bufnr, nil)
    eq(counts.n, 2) -- one parse per block

    render.render_buffer(bufnr, nil)
    eq(counts.n, 2) -- both cached

    -- Edit only the FIRST block's query (still at buffer row 2: block 1's
    -- rendered lines are inserted after its closing fence, below row 2).
    set_query_line(bufnr, 1, "due before 2099-01-01")
    render.render_buffer(bufnr, nil)
    eq(counts.n, 3) -- block 1 re-parsed; block 2 cache hit
  end)

  cleanup(bufnr, restore_spy, restore_index)
  if not ok then
    error(err)
  end
end

T["day rollover invalidates the cache (relative dates re-resolve)"] = function()
  local restore_index = install_index_stub()
  local counts, restore_spy = install_parse_spy()

  -- Relative-date query: parse resolves 'tomorrow' to a concrete ISO string,
  -- so a cached AST freezes the resolution day.
  local bufnr = make_buf({ "```tasks", "due before tomorrow", "```" })

  local ok, err = pcall(function()
    render.render_buffer(bufnr, nil)
    eq(counts.n, 1)
    local entry = render._query_cache[bufnr][1]
    eq(entry.day, os.date("%Y-%m-%d"))

    -- Same day, unchanged text: cache hit.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 1)

    -- Simulate the entry having been parsed yesterday (a dashboard left open
    -- across midnight): the day stamp no longer matches → cache miss, parse
    -- runs again and the fresh entry carries today's stamp.
    render._query_cache[bufnr][1].day = "2000-01-01"
    render.render_buffer(bufnr, nil)
    eq(counts.n, 2)
    eq(render._query_cache[bufnr][1].day, os.date("%Y-%m-%d"))

    -- And the refreshed entry is again a same-day cache hit.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 2)
  end)

  cleanup(bufnr, restore_spy, restore_index)
  if not ok then
    error(err)
  end
end

T["thrown parse is not cached; fixing the query text re-parses"] = function()
  local restore_index = install_index_stub()
  local counts, restore_spy = install_parse_spy()

  local bufnr = make_buf({ "```tasks", "FORCE_PARSE_ERROR", "```" })

  local ok, err = pcall(function()
    -- Parse throws → INTERNAL ERROR rendered (as virt_lines), nothing cached.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 1)
    eq(virt_has(bufnr, "INTERNAL ERROR"), true)

    -- Same broken text renders again: failure was NOT cached, so parse is
    -- attempted again (no stale-failure masking).
    render.render_buffer(bufnr, nil)
    eq(counts.n, 2)

    -- Fix the query text → fresh parse succeeds and results render.
    set_query_line(bufnr, 1, "not done")
    render.render_buffer(bufnr, nil)
    eq(counts.n, 3)
    eq(virt_has(bufnr, "INTERNAL ERROR"), false)
    eq(buf_has(bufnr, "cached task A"), true)

    -- And the fixed text is now cached.
    render.render_buffer(bufnr, nil)
    eq(counts.n, 3)
  end)

  cleanup(bufnr, restore_spy, restore_index)
  if not ok then
    error(err)
  end
end

return T
