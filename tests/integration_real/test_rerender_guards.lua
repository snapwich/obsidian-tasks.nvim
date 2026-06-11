-- tests/integration_real/test_rerender_guards.lua
-- Behavioral guards written AHEAD of the render refactor/perf work. Both
-- tests pin user-visible contracts that internal changes must preserve:
--
--   1. Query-text edits take effect on the next rerender. Today nothing is
--      cached so this is trivially true; once a per-block (query_text → AST)
--      cache exists, this test is the stale-cache regression guard.
--
--   2. A VISIBLE dashboard reflects a source-file write once the user is
--      back in its window. Deliberately semantics-agnostic: it passes with
--      today's immediate rerender-on-BufWritePost AND with a future
--      dirty-flag + deferred-sync design, as long as re-entering the
--      dashboard window leaves it up to date.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

local function read_file(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- Does any line of *bufnr* contain *needle*?
local function buf_has(bufnr, needle)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(needle, 1, true) then
      return true
    end
  end
  return false
end

--- Replace the first buffer line equal to *old* with *new*; error if absent.
local function replace_line(bufnr, old, new)
  for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l == old then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { new })
      return
    end
  end
  error(("line %q not found in buffer %d"):format(old, bufnr))
end

T["editing query text then rerendering reflects the new query"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")

  local dash_path = fixture_vault .. "/qa_guard_query_edit.md"
  local opened_bufs = {}

  local function cleanup()
    os.remove(dash_path)
    for _, b in ipairs(opened_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end

  local ok, err = pcall(function()
    index.refresh_file(fixture_vault .. "/personal/health.md")
    index.refresh_file(fixture_vault .. "/work/sprint.md")

    write_file(
      dash_path,
      table.concat({
        "# Query edit guard dash",
        "",
        "```tasks",
        "tag includes #health",
        "```",
        "",
      }, "\n")
    )

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = dash_buf
    vim.bo[dash_buf].filetype = "markdown"
    render.render_buffer(dash_buf, require("fixture_ws")())

    -- Initial render matches the #health query only.
    eq(buf_has(dash_buf, "Morning stretch routine"), true)
    eq(buf_has(dash_buf, "Ship auth refactor"), false)

    -- User edits the query line (real buffer text above the render region).
    replace_line(dash_buf, "tag includes #health", "tag includes #work")
    render.rerender_buffer(dash_buf, require("fixture_ws")())

    -- Rerender must evaluate the NEW query text — no stale results.
    eq(buf_has(dash_buf, "Ship auth refactor"), true)
    eq(buf_has(dash_buf, "Morning stretch routine"), false)
  end)

  cleanup()
  if not ok then
    error(err)
  end
end

T["visible dashboard is up to date after returning to its window post source write"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")

  local source_path = fixture_vault .. "/personal/health.md"
  local dash_path = fixture_vault .. "/qa_guard_visible_sync.md"
  local sentinel = "Visible sync guard sentinel"

  local original_source = read_file(source_path)
  local opened_bufs = {}

  local function cleanup()
    pcall(write_file, source_path, original_source)
    os.remove(dash_path)
    for _, b in ipairs(opened_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    index.invalidate(source_path)
    index.refresh_file(source_path)
    vim.cmd("only")
  end

  local ok, err = pcall(function()
    index.invalidate(source_path)
    index.refresh_file(source_path)

    write_file(
      dash_path,
      table.concat({
        "# Visible sync guard dash",
        "",
        "```tasks",
        "tag includes #health",
        "```",
        "",
      }, "\n")
    )

    -- ── 1. Dashboard rendered in one window… ────────────────────────────────
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    local dash_win = vim.api.nvim_get_current_win()
    opened_bufs[#opened_bufs + 1] = dash_buf
    vim.bo[dash_buf].filetype = "markdown"
    render.render_buffer(dash_buf, require("fixture_ws")())
    eq(buf_has(dash_buf, sentinel), false)

    -- ── 2. …source opened in a split, so BOTH stay visible. ────────────────
    vim.cmd("noswapfile split " .. vim.fn.fnameescape(source_path))
    local src_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = src_buf
    eq(#vim.fn.win_findbuf(dash_buf) > 0, true)

    -- ── 3. Append a matching task and :write (real BufWritePost path). ──────
    vim.api.nvim_buf_set_lines(src_buf, -1, -1, false, {
      "- [ ] " .. sentinel .. " #task #health 📅 2026-07-11",
    })
    vim.cmd("silent write")

    -- ── 4. Return to the dashboard window (fires BufEnter for dash_buf). ────
    -- The contract: by the time the user is looking at the dashboard again,
    -- it shows the new task. Whether the rerender ran at write time or was
    -- deferred to this re-entry is an implementation detail.
    vim.api.nvim_set_current_win(dash_win)
    vim.cmd("doautocmd BufEnter") -- belt-and-braces: some paths key off BufEnter

    eq(buf_has(dash_buf, sentinel), true)
  end)

  cleanup()
  if not ok then
    error(err)
  end
end

return T
