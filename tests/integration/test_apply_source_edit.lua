-- tests/integration/test_apply_source_edit.lua
-- Regression tests for cmd.apply_source_edit — the disk-write primitive used
-- by query-buffer mutations.
--
-- Bug history: an earlier version auto-loaded the source file via bufadd +
-- bufload before writing.  When a stale swap file existed (from a crashed
-- nvim session), bufload could leave the buffer effectively empty; the
-- subsequent nvim_buf_set_lines clamped to the empty buffer's range and
-- writefile truncated the file to a single line.  apply_source_edit avoids
-- bufload entirely when the file isn't already loaded, eliminating the
-- truncation hazard.

local T = MiniTest.new_set()

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

-- ── Bufferless write path ─────────────────────────────────────────────────────

T["apply_source_edit: replace one row in a file that is NOT loaded"] = function()
  local path = make_tmpfile({
    "# Header",
    "intro paragraph",
    "- [ ] Task A",
    "- [ ] Task B",
    "trailing paragraph",
  })

  -- File must not be loaded as a buffer before the call.
  eq(vim.fn.bufnr(path, false), -1, "precondition: file should not be loaded")

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 2, { "- [x] Task A" }) -- row 2 = "Task A"
  eq(ok, true)

  -- All other lines must survive.
  local lines = read_file(path)
  eq(#lines, 5, "file must keep all 5 lines (no truncation)")
  eq(lines[1], "# Header")
  eq(lines[2], "intro paragraph")
  eq(lines[3], "- [x] Task A")
  eq(lines[4], "- [ ] Task B")
  eq(lines[5], "trailing paragraph")

  -- No buffer should have been created.
  eq(vim.fn.bufnr(path, false), -1, "no buffer should have been auto-loaded")

  vim.fn.delete(path)
end

T["apply_source_edit: bufferless write does not trigger swap-file detection"] = function()
  -- Create a stale .swp file alongside a real source file.  If apply_source_edit
  -- were calling bufload, this would surface as a SwapExists autocmd / message.
  local path = make_tmpfile({ "- [ ] Task" })

  local sentinel = false
  local id = vim.api.nvim_create_autocmd("SwapExists", {
    pattern = path,
    callback = function()
      sentinel = true
      vim.v.swapchoice = "e" -- edit-anyway, just in case
    end,
  })

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 0, { "- [x] Task" })
  eq(ok, true)
  eq(sentinel, false, "no SwapExists should fire when bufferless writes are used")
  eq(read_file(path)[1], "- [x] Task")

  vim.api.nvim_del_autocmd(id)
  vim.fn.delete(path)
end

-- ── Loaded-buffer write path ─────────────────────────────────────────────────

T["apply_source_edit: replace one row in a file that IS already loaded"] = function()
  local path = make_tmpfile({ "alpha", "beta", "gamma" })

  -- Pre-load the file as a buffer (simulates the user having it open).
  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  eq(vim.api.nvim_buf_is_loaded(b), true)

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 1, { "BETA" })
  eq(ok, true)

  -- Loaded buffer must stay in sync with disk.
  local buf_lines = vim.api.nvim_buf_get_lines(b, 0, -1, false)
  local disk_lines = read_file(path)
  eq(buf_lines, { "alpha", "BETA", "gamma" })
  eq(disk_lines, { "alpha", "BETA", "gamma" })
  eq(vim.bo[b].modified, false, "buffer should not be left modified after write")

  vim.api.nvim_buf_delete(b, { force = true })
  vim.fn.delete(path)
end

T["apply_source_edit: refuses to write when loaded buffer has unsaved edits"] = function()
  local path = make_tmpfile({ "- [ ] Task", "scratch" })

  local b = vim.fn.bufadd(path)
  vim.fn.bufload(b)
  -- Dirty the buffer at a row OTHER than the one we're going to edit.
  vim.api.nvim_buf_set_lines(b, 1, 2, false, { "user's pending edit" })
  eq(vim.bo[b].modified, true)

  local warned = false
  local log = require("obsidian-tasks.log")
  local orig = log.warn
  log.warn = function(_)
    warned = true
  end

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 0, { "- [x] Task" })

  log.warn = orig

  eq(ok, false, "must refuse to write while buffer is dirty")
  eq(warned, true, "must emit a warning")
  -- Disk must be untouched.
  eq(read_file(path), { "- [ ] Task", "scratch" })

  vim.api.nvim_buf_delete(b, { force = true })
  vim.fn.delete(path)
end

-- ── Range safety ─────────────────────────────────────────────────────────────

T["apply_source_edit: out-of-range row fails loudly, does not truncate"] = function()
  -- This is the precise regression: previously, an out-of-range row would
  -- silently clamp under strict_indexing=false and writefile would shrink
  -- the file to a 1-2 line buffer.  Now we must refuse the write outright.
  local path = make_tmpfile({ "line 1", "line 2", "line 3" })

  local warned = false
  local log = require("obsidian-tasks.log")
  local orig = log.warn
  log.warn = function(_)
    warned = true
  end

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 99, { "OUT OF RANGE" })

  log.warn = orig

  eq(ok, false, "must refuse out-of-range edit")
  eq(warned, true)
  -- File must be intact.
  eq(read_file(path), { "line 1", "line 2", "line 3" })

  vim.fn.delete(path)
end

T["apply_source_edit: delete row (empty replacement) shrinks the file by one"] = function()
  local path = make_tmpfile({ "keep me", "delete me", "also keep" })

  local cmd = require("obsidian-tasks.cmd")
  local ok = cmd.apply_source_edit(path, 1, {})
  eq(ok, true)
  eq(read_file(path), { "keep me", "also keep" })

  vim.fn.delete(path)
end

return T
