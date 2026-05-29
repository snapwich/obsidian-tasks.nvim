-- tests/integration_real/test_hidden_source_cursor.lua
-- Regression test for BUG: when a source buffer is loaded but hidden (no
-- window) and a dashboard mutation (e.g. <leader>tt) edits a row via
-- nvim_buf_set_lines, the user's window-saved cursor for that buffer is
-- clobbered.  Returning to the source buffer drops the cursor at row 4 col 0
-- instead of restoring the user's pre-switch position.
--
-- Failing precondition (red): after mutate-and-return, cursor.row != saved row.
--
-- Post-fix expectation (green): cursor.row matches where the user left off.

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

T["hidden source buffer cursor survives a dashboard-driven source mutation"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")
  local cmd = require("obsidian-tasks.cmd")

  local source_path = fixture_vault .. "/personal/health.md"
  local dash_path = fixture_vault .. "/qa_hidden_cursor_dash.md"

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
        "# Hidden cursor dash",
        "",
        "```tasks",
        "not done",
        "tag includes #health",
        "```",
        "",
      }, "\n")
    )

    -- Open source first; cursor at known position.
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(source_path))
    local src_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = src_buf
    local saved_row, saved_col = 5, 3
    vim.api.nvim_win_set_cursor(0, { saved_row, saved_col })

    -- Switch the window to the dashboard.  Source is now loaded but hidden.
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = dash_buf
    eq(vim.api.nvim_buf_is_loaded(src_buf), true)
    eq(#vim.fn.win_findbuf(src_buf), 0)

    render.render_buffer(dash_buf, require("fixture_ws")())

    local target
    for i, l in ipairs(vim.api.nvim_buf_get_lines(dash_buf, 0, -1, false)) do
      if l:find("Morning stretch", 1, true) then
        target = i
        break
      end
    end
    assert(target, "Morning stretch row not in dashboard render")
    vim.api.nvim_set_current_buf(dash_buf)
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    cmd.dispatch({ fargs = { "toggle" }, line1 = target, line2 = target })

    -- Switch back to source in the same window.
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(source_path))
    local cursor_after = vim.api.nvim_win_get_cursor(0)

    -- The mutated row 5 didn't shrink; saved (5, 3) must be preserved.
    eq(cursor_after[1], saved_row)
  end)

  restore()
  if not ok then
    error(err)
  end
end

return T
