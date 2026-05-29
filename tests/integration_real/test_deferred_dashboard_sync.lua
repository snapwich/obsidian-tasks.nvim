-- tests/integration_real/test_deferred_dashboard_sync.lua
-- Task 11: a source .md write must sync a windowless (hidden) dashboard.
--
-- Previously the reverse_index propagation SKIPPED any referencing buffer
-- with no window — a hidden dashboard stayed stale until the user entered it
-- AND ran <leader>tr.  The fix marks the windowless buffer dirty and defers
-- its rerender to the next BufEnter, preserving the cursor on the way back.
--
-- Real autocmd path: programmatic buffer edits don't fire BufWritePost the
-- way :write does, and the BufEnter hook needs a genuine buffer switch — so
-- this drives :write / :buffer rather than nvim_buf_set_lines alone.

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

T["windowless dashboard syncs on its next BufEnter, cursor preserved"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")

  local source_path = fixture_vault .. "/personal/health.md"
  local dash_path = fixture_vault .. "/qa_deferred_sync_dash.md"
  local sentinel = "Deferred sync sentinel"

  local original_source = read_file(source_path)
  local opened_bufs = {}

  local function restore()
    pcall(write_file, source_path, original_source)
    os.remove(dash_path)
    for _, b in ipairs(opened_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    index.invalidate(source_path)
    index.refresh_file(source_path)
  end

  local ok, err = pcall(function()
    index.invalidate(source_path)
    index.refresh_file(source_path)

    write_file(
      dash_path,
      table.concat({
        "# Deferred sync dash",
        "",
        "```tasks",
        "tag includes #health",
        "```",
        "",
      }, "\n")
    )

    -- ── 1. Open + render the dashboard; park the cursor in the render. ──────
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = dash_buf
    vim.bo[dash_buf].filetype = "markdown"
    render.render_buffer(dash_buf, require("fixture_ws")())

    -- reverse_index must reference the dashboard, else nothing to propagate.
    local rev = {}
    for _, b in ipairs(index.reverse_index(source_path)) do
      rev[b] = true
    end
    eq(rev[dash_buf], true)

    local cursor_row = 4 -- a row inside the rendered task block
    assert(vim.api.nvim_buf_line_count(dash_buf) >= cursor_row, "render too short")
    vim.api.nvim_win_set_cursor(0, { cursor_row, 2 })
    eq(buf_has(dash_buf, sentinel), false)

    -- ── 2. Switch the window away → dashboard is now windowless. ───────────
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(source_path))
    local src_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = src_buf
    eq(#vim.fn.win_findbuf(dash_buf), 0)

    -- ── 3. Append a matching task to the source + :write. ──────────────────
    vim.api.nvim_buf_set_lines(src_buf, -1, -1, false, {
      "- [ ] " .. sentinel .. " #task #health 📅 2026-07-04",
    })
    vim.cmd("silent write")

    -- ── 4. Propagation marked the hidden dashboard dirty — not yet synced. ─
    eq(vim.b[dash_buf].obsidian_tasks_sync_dirty, true)
    eq(buf_has(dash_buf, sentinel), false)

    -- ── 5. Enter the dashboard → deferred BufEnter rerender fires. ─────────
    vim.cmd("buffer " .. dash_buf)

    -- ── 6. Synced, dirty flag cleared, cursor preserved. ──────────────────
    eq(vim.b[dash_buf].obsidian_tasks_sync_dirty, nil)
    eq(buf_has(dash_buf, sentinel), true)
    eq(vim.api.nvim_win_get_cursor(0)[1], cursor_row)
  end)

  restore()
  if not ok then
    error(err)
  end
end

return T
