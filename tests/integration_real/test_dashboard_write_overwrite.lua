-- tests/integration_real/test_dashboard_write_overwrite.lua
-- Regression test for BUG: render/save.lua's BufWriteCmd handler writes the
-- buffer's filtered lines to disk without checking whether the file changed
-- on disk since last read.  An external editor that appends to the dashboard
-- file between buffer load and :w is silently overwritten.
--
-- Failing precondition (red): without the fix, external content is gone after :w.
--
-- Post-fix expectation (green): :w either refuses when disk is newer than
-- the buffer's last-read time, OR merges/preserves the disk content.

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

T["dashboard :w does not silently clobber externally-appended content"] = function()
  local render = require("obsidian-tasks.render")
  local index = require("obsidian-tasks.index")

  local source_path = fixture_vault .. "/personal/health.md"
  local dash_path = fixture_vault .. "/qa_overwrite_dash.md"

  local opened_bufs = {}

  local function restore()
    os.remove(dash_path)
    for _, b in ipairs(opened_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end

  local ok, err = pcall(function()
    index.invalidate(source_path)
    index.refresh_file(source_path)

    local initial = table.concat({
      "# Overwrite dash",
      "",
      "```tasks",
      "not done",
      "tag includes #health",
      "```",
      "",
    }, "\n")
    write_file(dash_path, initial)

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = dash_buf
    render.render_buffer(dash_buf, Obsidian.workspace)

    -- External writer appends to the dashboard file, then bumps the mtime
    -- forward so the on-disk timestamp is strictly newer than the buffer's
    -- read time (avoids relying on sub-second sleep accuracy in headless nvim).
    local external_marker = "## Added by another editor"
    write_file(dash_path, initial .. "\n" .. external_marker .. "\n")
    local now = os.time()
    vim.uv.fs_utime(dash_path, now + 10, now + 10)

    -- User edits a prose line and :w.  Use silent! so any abort from a
    -- refuse-style fix is swallowed (we test outcome, not message).
    vim.api.nvim_buf_set_lines(dash_buf, 0, 1, false, { "# Overwrite dash (edited)" })
    pcall(vim.cmd, "silent! write")

    local disk_after = read_file(dash_path)

    -- Valid outcomes:
    --   • disk still contains the external marker (merge / refuse-then-disk-untouched), OR
    --   • the buffer is still 'modified' (write refused; user must :e! / merge).
    local kept_external = disk_after:find(external_marker, 1, true) ~= nil
    local write_refused = vim.bo[dash_buf].modified == true
    eq(kept_external or write_refused, true)
  end)

  restore()
  if not ok then
    error(err)
  end
end

return T
