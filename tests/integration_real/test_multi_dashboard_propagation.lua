-- tests/integration_real/test_multi_dashboard_propagation.lua
-- Regression test for BUG: when two dashboards render tasks from the same
-- source file, a dashboard mutation (e.g. <leader>tt) in dashboard A does
-- NOT cause dashboard B to refresh.  The mutation path goes through
-- cmd.apply_source_edit → vim.fn.writefile, which doesn't fire BufWritePost,
-- so the reverse_index propagation in autocmds.lua never runs.
--
-- Failing precondition (red): without the fix, dashboard B still shows the
-- pre-toggle state.
--
-- Post-fix expectation (green): dashboard B either drops the toggled task
-- from the filter, OR shows it lingered as [x].

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

T["dashboard B refreshes when dashboard A toggles a shared source task"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")
  local cmd = require("obsidian-tasks.cmd")

  local source_path = fixture_vault .. "/personal/health.md"
  local dash_a = fixture_vault .. "/qa_dash_a.md"
  local dash_b = fixture_vault .. "/qa_dash_b.md"

  local original_source = read_file(source_path)
  local opened_bufs = {}

  local function restore()
    pcall(write_file, source_path, original_source)
    os.remove(dash_a)
    os.remove(dash_b)
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
      dash_a,
      table.concat({
        "# Dash A",
        "",
        "```tasks",
        "not done",
        "tag includes #health",
        "```",
        "",
      }, "\n")
    )
    write_file(
      dash_b,
      table.concat({
        "# Dash B",
        "",
        "```tasks",
        "not done",
        "tag includes #personal",
        "```",
        "",
      }, "\n")
    )

    -- Open A in current window, B in a split — both visible.  Propagation
    -- intentionally skips hidden buffers, so the split is required to trigger
    -- the bug-under-test.
    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_a))
    local buf_a = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = buf_a
    render.render_buffer(buf_a, Obsidian.workspace)

    vim.cmd("noswapfile split " .. vim.fn.fnameescape(dash_b))
    local buf_b = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = buf_b
    render.render_buffer(buf_b, Obsidian.workspace)

    local function find_ms(bufnr)
      for i, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
        if l:find("Morning stretch", 1, true) then
          return i, l
        end
      end
    end
    local a_row, a_line = find_ms(buf_a)
    local _, b_line = find_ms(buf_b)
    assert(a_line and a_line:find("- %[ %]"), "Dash A precondition: " .. tostring(a_line))
    assert(b_line and b_line:find("- %[ %]"), "Dash B precondition: " .. tostring(b_line))

    -- Toggle from A.
    for _, w in ipairs(vim.fn.win_findbuf(buf_a)) do
      vim.api.nvim_set_current_win(w)
      vim.api.nvim_win_set_cursor(w, { a_row, 0 })
      break
    end
    vim.api.nvim_set_current_buf(buf_a)
    cmd.dispatch({ fargs = { "toggle" }, line1 = a_row, line2 = a_row })

    -- B must reflect: row dropped from filter or shown as [x] linger.
    local _, b_line_after = find_ms(buf_b)
    local b_reflects = (b_line_after == nil) or (b_line_after:find("%[x%]") ~= nil)
    eq(b_reflects, true)
  end)

  restore()
  if not ok then
    error(err)
  end
end

return T
