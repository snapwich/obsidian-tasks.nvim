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

-- ── FIX 2 (Phase 6 defense-in-depth): a BULLET rendering a task-looking line ──
-- must NOT be status-flipped by a direct buffer edit ─────────────────────────
--
-- A pathological tree BULLET whose body renders like a canonical checkbox
-- (e.g. a '-' marker bullet whose trimmed body is literally "[ ] foo") would,
-- without the tree_kind guard in classify_and_commit, be recognized as a status
-- edit and flipped through to source — violating the dispatch-by-kind firewall.
--
-- We drive classify_and_commit directly via the snapshot seam: register a meta
-- with tree_kind="bullet" whose rendered_text is a full `- [ ] …` line, flip the
-- checkbox in the buffer, run the revert, and assert the source file is UNTOUCHED.
-- A control case with the same shape but tree_kind="task" must still flip, proving
-- the test would fail if the guard were removed.

T["status edit: a BULLET rendering a task-looking line is NOT flipped (FIX 2)"] = function()
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ "- [ ] looks like a task" })

  -- A managed dashboard buffer whose single managed row is the pathological
  -- bullet line.  We bypass the live render and inject the snapshot directly.
  local bufnr = make_buf({ "- [ ] looks like a task" })
  vim.b[bufnr].obsidian_tasks_dashboard = true
  local row0 = 0
  local rendered = "- [ ] looks like a task"

  -- Attach with a no-op rerender_fn so do_revert's rerender pass is inert
  -- (we only care about the classify_and_commit source-write here).
  revert.attach(bufnr, nil, function() end)
  revert._set_snapshots_for_test(bufnr, { { row0, row0 } }, {
    [row0] = {
      source_file = src_path,
      source_row = 0,
      task_text = "- [ ] looks like a task",
      rendered_text = rendered,
      tree_kind = "bullet",
    },
  })

  -- Flip the checkbox in the buffer ([ ] → [x]) and run the revert.
  set_line(bufnr, row0, (rendered:gsub("%[ %]", "[x]", 1)))
  revert.force_revert(bufnr)

  -- The bullet guard must have skipped the status-flip commit: source untouched.
  eq(read_src_line(src_path, 0), "- [ ] looks like a task", "a bullet must NOT be status-flipped to source")

  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
end

T["status edit: control — same shape with tree_kind='task' DOES flip (FIX 2 guard proof)"] = function()
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ "- [ ] looks like a task" })

  local bufnr = make_buf({ "- [ ] looks like a task" })
  vim.b[bufnr].obsidian_tasks_dashboard = true
  local row0 = 0
  local rendered = "- [ ] looks like a task"

  revert.attach(bufnr, nil, function() end)
  revert._set_snapshots_for_test(bufnr, { { row0, row0 } }, {
    [row0] = {
      source_file = src_path,
      source_row = 0,
      task_text = "- [ ] looks like a task",
      rendered_text = rendered,
      tree_kind = "task",
    },
  })

  set_line(bufnr, row0, (rendered:gsub("%[ %]", "[x]", 1)))
  revert.force_revert(bufnr)

  -- A real task row with the identical edit MUST commit, proving the guard (not
  -- some unrelated condition) is what blocks the bullet case above.
  eq(read_src_line(src_path, 0), "- [x] looks like a task", "a task row must still flip to source")

  revert._cleanup(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
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

-- ── two consecutive status edits on the same row both commit ────────────────
--
-- Regression: prior to the persist+refresh step in classify_and_commit, the
-- first `r x` wrote to the source buffer but never saved to disk or refreshed
-- the index.  meta.task_text on the rerendered row was still the pre-edit
-- text, so the next edit's drift check compared stale meta vs the now-mutated
-- source buffer, fired "source drift detected", and locked the row out.

T["status edit: two consecutive edits both commit (no spurious drift)"] = function()
  -- Set up by hand: use a description filter so the row survives state changes
  -- (the standard "not done" filter would hide the row after edit 1's [x]).
  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ "- [ ] Two edits" })
  local restore_stub = install_file_task_stub(src_path)

  local bufnr = make_buf({ "```tasks", "description includes Two", "```" })
  render.render_buffer(bufnr, nil)

  local task_row = 3

  -- Bypass read_src_line's buffer-preferred path so we exercise the actual
  -- regression: the prior code wrote the source *buffer* but never persisted
  -- to disk or refreshed the index. The drift check on edit 2 then compared
  -- a stale meta.task_text (from disk, via refresh_file) vs the now-mutated
  -- source buffer, failed, and locked the row.
  local function read_disk(path, row0)
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines[row0 + 1] or nil
  end

  -- Sanity: rendered row exists.
  local canonical = get_line(bufnr, task_row)
  eq(canonical and canonical:find("Two edits", 1, true) ~= nil, true, "task must render initially")

  -- Edit 1: [ ] → [x]
  set_line(bufnr, task_row, (canonical:gsub("%[ %]", "[x]", 1)))
  revert._flush_pending(bufnr)
  eq(read_disk(src_path, 0), "- [x] Two edits", "first commit must persist to disk")

  -- Capture warns so a drift-style failure is loud.
  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    notify_calls[#notify_calls + 1] = { msg = msg, level = level }
  end

  -- Edit 2: [x] → [ ] on the rerendered row.
  local row2 = get_line(bufnr, task_row)
  eq(row2 and row2:find("%[x%]") ~= nil, true, "rerendered row must reflect [x] from edit 1")
  set_line(bufnr, task_row, (row2:gsub("%[x%]", "[ ]", 1)))
  revert._flush_pending(bufnr)

  vim.notify = orig_notify

  eq(read_disk(src_path, 0), "- [ ] Two edits", "second commit must persist to disk")

  -- No drift warnings — a drift here is the regression.
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and tostring(c.msg):find("drift", 1, true) then
      eq(true, false, "unexpected drift warning: " .. tostring(c.msg))
    end
  end

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

-- ── rapid status cycle: invalidate must bypass mtime no-op ────────────────
--
-- Regression: classify_and_commit's persist block calls index.refresh_file,
-- which has an mtime no-op (skip parse if mtime unchanged).  When the user
-- cycles statuses rapidly (e.g. obsidian.nvim's <CR> smart_action firing
-- 4 times in < 1 second), successive writefile calls land in the same
-- mtime second.  Without an explicit invalidate, refresh_file no-ops on
-- the second cycle and the index keeps the first cycle's symbol — so the
-- third press's drift check (meta.task_text from stale index vs source
-- buffer) fails and locks the row.
--
-- This test asserts _index[src_path] reflects each commit, bypassing the
-- stub that the other tests rely on.

T["status edit: rapid cycle updates the real index entry every commit"] = function()
  local index_mod = require("obsidian-tasks.index")
  index_mod._reset()

  render.configure({ default_folded = false })
  local src_path = make_tmpfile({ "- [ ] Rapid cycle" })
  local restore_stub = install_file_task_stub(src_path)

  local bufnr = make_buf({ "```tasks", "description includes Rapid", "```" })
  render.render_buffer(bufnr, nil)

  local task_row = 3
  local function row_symbol_in_index()
    local raw = index_mod._raw()
    -- Index keys are canonical (vim.fs.normalize); tempname is backslash on Windows.
    local entry = raw[vim.fs.normalize(src_path)]
    if not entry or not entry.tasks or not entry.tasks[1] then
      return nil
    end
    return entry.tasks[1].task.status_symbol
  end

  -- Initial index entry (from the lazy walk on first render).
  index_mod.refresh_file(src_path)
  eq(row_symbol_in_index(), " ")

  -- Capture warns: a drift here is the regression.
  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    notify_calls[#notify_calls + 1] = { msg = msg, level = level }
  end

  local function press_to(sym)
    local cur = get_line(bufnr, task_row)
    set_line(bufnr, task_row, (cur:gsub("%[.%]", "[" .. sym .. "]", 1)))
    revert._flush_pending(bufnr)
  end

  -- Cycle [ ] → x → [-] → [ ] in quick succession.  Each step's commit must
  -- be visible in _index — i.e. invalidate-then-refresh must overcome the
  -- mtime no-op even when writes land in the same wall-clock second.
  press_to("x")
  eq(row_symbol_in_index(), "x", "index must reflect [x] after first cycle")
  press_to("-")
  eq(row_symbol_in_index(), "-", "index must reflect [-] after second cycle")
  press_to(" ")
  eq(row_symbol_in_index(), " ", "index must reflect [ ] after third cycle")

  vim.notify = orig_notify
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and tostring(c.msg):find("drift", 1, true) then
      eq(true, false, "unexpected drift warning: " .. tostring(c.msg))
    end
  end

  render.clear_buffer(bufnr)
  restore_stub()
  revert._cleanup(bufnr)
  local src_buf = vim.fn.bufnr(src_path, false)
  if src_buf ~= -1 then
    vim.api.nvim_buf_delete(src_buf, { force = true })
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(src_path)
  index_mod._reset()
end

-- ── refuse when source buffer has unsaved changes ───────────────────────────
--
-- Disk-truth model: queries reflect disk, edits-from-query persist via
-- writefile.  If the user has unsaved edits in the source buffer, our
-- writefile would silently save them along with the toggle — surprising
-- and potentially destructive of in-progress work.  Instead, refuse the
-- commit and tell the user to :w first.

T["status edit: source buffer has unsaved changes → refuse, no source mutation"] = function()
  local bufnr, src_path, cleanup = setup_status_test("- [ ] Pending save")
  local task_row = 3

  -- Load the source buffer and dirty it WITHOUT writing to disk.  Pick a row
  -- different from the task row so the buffer-side edit doesn't itself
  -- trigger a drift-check failure on the task line.
  local src_buf = vim.fn.bufadd(src_path)
  vim.fn.bufload(src_buf)
  vim.api.nvim_buf_set_lines(src_buf, 1, 1, false, { "an unsaved scratch line" })
  MiniTest.expect.equality(vim.bo[src_buf].modified, true, "fixture must leave source buffer dirty")

  -- Toggle [ ] → [x] from the query.
  local canonical = get_line(bufnr, task_row)
  set_line(bufnr, task_row, (canonical:gsub("%[ %]", "[x]", 1)))

  local notify_calls = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, level)
    notify_calls[#notify_calls + 1] = { msg = msg, level = level }
  end
  revert._flush_pending(bufnr)
  vim.notify = orig_notify

  -- Disk must NOT have been written.
  local function read_disk(path, row0)
    local ok, lines = pcall(vim.fn.readfile, path)
    return ok and lines[row0 + 1] or nil
  end
  eq(read_disk(src_path, 0), "- [ ] Pending save", "disk must not be mutated while buffer is dirty")

  -- A targeted warning must have been emitted.
  local saw_warn = false
  for _, c in ipairs(notify_calls) do
    if c.level == vim.log.levels.WARN and tostring(c.msg):find("unsaved", 1, true) then
      saw_warn = true
      break
    end
  end
  eq(saw_warn, true, "must emit an 'unsaved' warning")

  cleanup()
end

return T
