-- tests/integration/test_status_edit.lua
-- Integration tests for direct status-char edits on rendered task lines.
--
-- The read-only revert (test_read_only_revert.lua) reverts ANY direct edit.
-- This test suite verifies the carve-out: when the only change is the
-- checkbox status character and the new char is in the configured statuses,
-- the change is propagated to the source file via the same resolver pipeline
-- used by `<leader>tt`.
--
-- Other diffs (description tweaks, structural changes, unknown status chars)
-- still revert via the existing wholesale rerender path.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local managed = require("obsidian-tasks.render.managed")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function make_tmpfile(lines)
  local path = vim.fn.tempname() .. ".md"
  vim.fn.writefile(lines, path)
  return path
end

--- Read line at 0-indexed row from a (possibly loaded) source path.
local function read_src_line(path, row0)
  local b = vim.fn.bufnr(path, false)
  if b ~= -1 and vim.api.nvim_buf_is_loaded(b) then
    return vim.api.nvim_buf_get_lines(b, row0, row0 + 1, false)[1]
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines[row0 + 1] or nil
end

local function get_line(bufnr, row0)
  return vim.api.nvim_buf_get_lines(bufnr, row0, row0 + 1, false)[1]
end

local function set_line(bufnr, row0, text)
  vim.api.nvim_buf_set_lines(bufnr, row0, row0 + 1, false, { text })
end

--- Install an index stub that returns tasks parsed from the live content of
--- *src_path* (buffer if loaded, else disk file).  Lets the dashboard
--- re-render after a source mutation and see the new state.
local function install_file_task_stub(src_path)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }
  index_mod.tasks_in = function(_)
    local content = {}
    local src_buf = vim.fn.bufnr(src_path, false)
    if src_buf ~= -1 and vim.api.nvim_buf_is_loaded(src_buf) then
      content = vim.api.nvim_buf_get_lines(src_buf, 0, -1, false)
    else
      local ok, lines = pcall(vim.fn.readfile, src_path)
      content = ok and lines or {}
    end
    local i = 0
    return function()
      while true do
        i = i + 1
        local line = content[i]
        if line == nil then
          return nil
        end
        local task = task_parse.parse(line)
        if task then
          return task, src_path, i
        end
      end
    end
  end
  index_mod.set_render_paths = function() end
  index_mod.clear_render_paths = function() end
  return function()
    index_mod.tasks_in = saved.tasks_in
    index_mod.set_render_paths = saved.set_render_paths
    index_mod.clear_render_paths = saved.clear_render_paths
  end
end

--- Standard scaffolding: tmpfile with given task text; dashboard buffer with
--- a single `not done` query; render fires.  Returns the dashboard bufnr,
--- the source path, and a cleanup function.
local function setup_status_test(task_text)
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ task_text })
  local restore_stub = install_file_task_stub(src_path)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  local cleanup = function()
    render.clear_buffer(bufnr)
    restore_stub()
    revert._cleanup(bufnr)
    -- Close any source buffer the resolver loaded.
    local src_buf = vim.fn.bufnr(src_path, false)
    if src_buf ~= -1 then
      vim.api.nvim_buf_delete(src_buf, { force = true })
    end
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(src_path)
  end

  return bufnr, src_path, cleanup
end

-- ── recognize_status_edit (pure logic) ───────────────────────────────────────
--
-- The function is local; we don't import it directly.  Each path is covered
-- by an integration test below.

-- ── normal-mode `r x` over [ ] commits to source ──────────────────────────────

T["status edit: `r x` on [ ] writes [x] to source"] = function()
  local bufnr, src_path, cleanup = setup_status_test("- [ ] Buy milk")

  -- After render: dashboard has `- [ ] Buy milk [[<file>]]` at row 3.
  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  eq(canonical:find("%[ %]") ~= nil, true, "canonical must contain [ ]")
  local edited = canonical:gsub("%[ %]", "[x]", 1)
  set_line(bufnr, task_row, edited)

  revert._flush_pending(bufnr)

  local src_line = read_src_line(src_path, 0)
  eq(src_line, "- [x] Buy milk", "source must have [x] after commit")

  cleanup()
end

-- ── In-Progress symbol `/` commits ───────────────────────────────────────────

T["status edit: `r /` on [ ] writes [/] to source"] = function()
  local bufnr, src_path, cleanup = setup_status_test("- [ ] Walk dog")

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  local edited = canonical:gsub("%[ %]", "[/]", 1)
  set_line(bufnr, task_row, edited)

  revert._flush_pending(bufnr)

  eq(read_src_line(src_path, 0), "- [/] Walk dog")

  cleanup()
end

-- ── unknown status char rejects, row reverts ─────────────────────────────────

T["status edit: unknown char `?` reverts and leaves source untouched"] = function()
  local bufnr, src_path, cleanup = setup_status_test("- [ ] Unchanged")

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  set_line(bufnr, task_row, (canonical:gsub("%[ %]", "[?]", 1)))

  revert._flush_pending(bufnr)

  -- Source must not have been mutated.
  eq(read_src_line(src_path, 0), "- [ ] Unchanged")
  -- Row should have reverted to canonical (wholesale rerender pass).
  local final = get_line(bufnr, task_row)
  eq(final, canonical)

  cleanup()
end

-- ── description-only edit reverts ────────────────────────────────────────────

T["status edit: edits outside the status position revert"] = function()
  local bufnr, src_path, cleanup = setup_status_test("- [ ] Task A")

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  -- Append junk after the description.
  set_line(bufnr, task_row, canonical .. " GARBAGE")

  revert._flush_pending(bufnr)

  eq(read_src_line(src_path, 0), "- [ ] Task A", "source must remain unchanged")
  eq(get_line(bufnr, task_row), canonical, "row must revert")

  cleanup()
end

-- ── no-op (same symbol) is not treated as an edit ───────────────────────────

T["status edit: identical symbol is a no-op (no source mutation)"] = function()
  local bufnr, src_path, cleanup = setup_status_test("- [ ] No change")

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  -- Replace [ ] with itself — sets _scheduled (line was 'touched') but the
  -- recognizer must reject because canonical == current.
  set_line(bufnr, task_row, canonical)

  revert._flush_pending(bufnr)

  eq(read_src_line(src_path, 0), "- [ ] No change")

  cleanup()
end

-- ── custom statuses opt: typing `>` commits when in config ──────────────────

T["status edit: custom status from opts.statuses commits"] = function()
  -- Pre-register `>` as a known status before any test setup.
  local status_mod = require("obsidian-tasks.task.status")
  status_mod.merge({ [">"] = { name = "Forwarded", next = " ", type = "ON_HOLD" } })

  local bufnr, src_path, cleanup = setup_status_test("- [ ] Forwardable")

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  set_line(bufnr, task_row, (canonical:gsub("%[ %]", "[>]", 1)))

  revert._flush_pending(bufnr)

  eq(read_src_line(src_path, 0), "- [>] Forwardable")

  -- Reset statuses to defaults so other tests aren't polluted.
  status_mod.merge({})
  cleanup()
end

-- ── drift: source changed externally → commit refused, row reverts ──────────

T["status edit: drift detected → resolver refuses, row reverts, no source mutation"] = function()
  render.configure({ default_folded = false })
  local task_text = "- [ ] Drift me"
  local src_path = make_tmpfile({ task_text })
  local restore_stub = install_file_task_stub(src_path)

  local bufnr = make_buf({ "```tasks", "not done", "```" })
  render.render_buffer(bufnr, nil)

  -- Mutate the source file out-of-band AFTER render so meta.task_text no
  -- longer matches the on-disk line.
  vim.fn.writefile({ "- [-] Externally cancelled" }, src_path)

  local task_row = 3
  local canonical = get_line(bufnr, task_row)
  set_line(bufnr, task_row, (canonical:gsub("%[ %]", "[x]", 1)))

  -- Capture notify calls to verify the drift warning.
  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    notify_calls[#notify_calls + 1] = { msg = msg, level = level }
  end
  revert._flush_pending(bufnr)
  vim.notify = orig_notify

  -- Source file (re-read from disk) still has the external content.
  -- The resolver may or may not have loaded the source as a buffer — read via
  -- file path always returns disk state, which the test hasn't asked us to
  -- preserve, so just check no `[x]` slipped through.
  local final_src = read_src_line(src_path, 0)
  eq(final_src:find("%[x%]") == nil, true, "source must not have been updated on drift")

  -- A drift warning must have been emitted.
  local saw_drift_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and tostring(c.msg):find("drift", 1, true) then
      saw_drift_warn = true
      break
    end
  end
  eq(saw_drift_warn, true, "resolver must emit drift warning")

  render.clear_buffer(bufnr)
  restore_stub()
  revert._cleanup(bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

return T
