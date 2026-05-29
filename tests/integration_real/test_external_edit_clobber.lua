-- tests/integration_real/test_external_edit_clobber.lua
-- Regression test for BUG: when a source buffer is loaded (even hidden), an
-- external disk edit to that file gets silently clobbered by the next
-- dashboard mutation (e.g. <leader>tt). cmd.apply_source_edit reads from the
-- loaded buffer (stale w.r.t. disk) and writefile()s its contents back,
-- overwriting whatever the external editor wrote.
--
-- Failing precondition (red): without the fix, the externally-written line
-- disappears from disk after the dashboard toggle.
--
-- Post-fix expectation (green): apply_source_edit either reloads the buffer
-- from disk before mutating, or refuses with a notification when disk has
-- changed under a loaded buffer.

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

T["external disk edit is preserved when dashboard toggles a task (loaded source buffer)"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")
  local cmd = require("obsidian-tasks.cmd")

  local source_path = fixture_vault .. "/personal/health.md"
  local dash_path = fixture_vault .. "/qa_clobber_dash.md"

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
    -- Seed index for source.  Invalidate first so mtime no-op doesn't keep
    -- stale entries from a prior test in the same nvim session.
    index.invalidate(source_path)
    index.refresh_file(source_path)

    write_file(
      dash_path,
      table.concat({
        "# Clobber dash",
        "",
        "```tasks",
        "not done",
        "tag includes #health",
        "```",
        "",
      }, "\n")
    )

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = dash_buf
    render.render_buffer(dash_buf, require("fixture_ws")())

    -- Load source buffer (hidden) so apply_source_edit hits its loaded-buf branch.
    local src_buf = vim.fn.bufadd(source_path)
    vim.fn.bufload(src_buf)
    opened_bufs[#opened_bufs + 1] = src_buf

    -- External writer modifies a non-task line of the source file.
    local marker = "# Health — EXTERNAL EDIT MARKER"
    write_file(source_path, original_source:gsub("# Health\n", marker .. "\n"))

    local target
    local all_lines = vim.api.nvim_buf_get_lines(dash_buf, 0, -1, false)
    for i, l in ipairs(all_lines) do
      if l:find("Morning stretch", 1, true) then
        target = i
        break
      end
    end
    assert(target, "Morning stretch not in dashboard render: " .. vim.inspect(all_lines))

    vim.api.nvim_set_current_buf(dash_buf)
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    cmd.dispatch({ fargs = { "toggle" }, line1 = target, line2 = target })

    local disk_after = read_file(source_path)

    eq(disk_after:find(marker, 1, true) ~= nil, true)
    -- Valid post-fix outcomes:
    --   (a) toggle applied AND external preserved (reload-then-merge), OR
    --   (b) toggle refused AND external preserved (detect-and-refuse).
    local toggled = disk_after:find("- %[x%] Morning stretch") ~= nil
    local untoggled = disk_after:find("- %[ %] Morning stretch") ~= nil
    eq(toggled or untoggled, true)
  end)

  restore()
  if not ok then
    error(err)
  end
end

return T
