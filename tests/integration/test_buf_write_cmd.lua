-- tests/integration/test_buf_write_cmd.lua
-- Integration tests for the BufWriteCmd save handler (T3).
--
-- Verifies that on_write_cmd:
--   • writes ONLY source lines (queries + prose) — managed task rows dropped
--   • never mutates the buffer (no visual change, no undo pollution)
--   • leaves vim.bo[bufnr].modified = false after a successful write
--   • fires BufWritePost so external plugins (LSP, formatters) still run
--   • preserves modified prose alongside absence of rendered tasks
--   • drops garbage typed into a managed row (acceptable — T6 makes them R/O)
--   • handles the no-managed-regions case: all lines written as-is
--
-- Also verifies that draw.draw() registers the BufWriteCmd handler on first
-- render and marks the buffer with vim.b.obsidian_tasks_dashboard so :w
-- routes through the plugin's filtered-write handler.
--
-- Tests call save.on_write_cmd() directly rather than triggering :w so they
-- stay synchronous and do not depend on autocmd plumbing from init.setup().

local T = MiniTest.new_set()

local save = require("obsidian-tasks.render.save")
local managed = require("obsidian-tasks.render.managed")
local draw_mod = require("obsidian-tasks.render.draw")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

--- Create a scratch buffer pre-populated with lines and return its bufnr.
--- @param lines string[]
--- @return integer
local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

--- Build a minimal single-task layout_lines list.
--- @param task_text string
--- @param src_path  string|nil
--- @param src_line  integer|nil
--- @return table[]
local function simple_layout(task_text, src_path, src_line)
  local hash = vim.fn.sha256(task_text):sub(1, 16)
  return {
    {
      kind = "task",
      text = task_text,
      src_path = src_path or "/vault/note.md",
      src_line = src_line or 1,
      src_hash = hash,
    },
    { kind = "footer", text = "─ 1 result ─" },
  }
end

-- ── on_write_cmd: source-only write ─────────────────────────────────────────

T["on_write_cmd: managed task rows dropped, source lines written"] = function()
  -- Buffer layout (0-indexed rows):
  --   0  "# Dashboard"        prose (kept)
  --   1  "```tasks"           fence open (kept)
  --   2  "not done"           query (kept)
  --   3  "```"                fence close (kept)
  --   4  "- [ ] Task A"       rendered, managed (dropped)
  --   5  "- [ ] Task B"       rendered, managed (dropped)
  --   6  "End prose"          prose (kept)
  local bufnr = make_buf({
    "# Dashboard",
    "```tasks",
    "not done",
    "```",
    "- [ ] Task A",
    "- [ ] Task B",
    "End prose",
  })

  managed.add_block(bufnr, 1, 3) -- fence rows 1-3
  managed.add_region(bufnr, 4, 5) -- managed region rows 4-5

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local written = vim.fn.readfile(tmpfile)
  vim.fn.delete(tmpfile)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#written, 5)
  eq(written[1], "# Dashboard")
  eq(written[2], "```tasks")
  eq(written[3], "not done")
  eq(written[4], "```")
  eq(written[5], "End prose")
end

-- ── on_write_cmd: prose modification persisted ───────────────────────────────

T["on_write_cmd: modified prose persisted, task rows still dropped"] = function()
  -- Only row 3 (the rendered task) is managed; row 4 (new prose) is kept.
  local bufnr = make_buf({
    "```tasks", -- 0
    "not done", -- 1
    "```", -- 2
    "- [ ] Rendered Task", -- 3 (managed)
    "New prose paragraph", -- 4 (not managed, must be kept)
  })

  managed.add_block(bufnr, 0, 2)
  managed.add_region(bufnr, 3, 3)

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local written = vim.fn.readfile(tmpfile)
  vim.fn.delete(tmpfile)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#written, 4)
  eq(written[1], "```tasks")
  eq(written[2], "not done")
  eq(written[3], "```")
  eq(written[4], "New prose paragraph")
end

-- ── on_write_cmd: garbage typed in managed row dropped ───────────────────────

T["on_write_cmd: garbage in managed row is dropped"] = function()
  -- User typed into row 3 which is inside the managed range.
  -- The row is dropped regardless of its content (T6 enforces read-only later).
  local bufnr = make_buf({
    "```tasks", -- 0
    "not done", -- 1
    "```", -- 2
    "GARBAGE TYPED HERE", -- 3 (managed range, dropped)
  })

  managed.add_block(bufnr, 0, 2)
  managed.add_region(bufnr, 3, 3)

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local written = vim.fn.readfile(tmpfile)
  vim.fn.delete(tmpfile)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#written, 3)
  eq(written[1], "```tasks")
  eq(written[2], "not done")
  eq(written[3], "```")
end

-- ── on_write_cmd: BufWritePost fires ────────────────────────────────────────

T["on_write_cmd: BufWritePost fires after successful write"] = function()
  local bufnr = make_buf({ "# Note", "Some prose" })

  local bwp_fired = false
  local aucmd_id = vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function()
      bwp_fired = true
    end,
  })

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  vim.fn.delete(tmpfile)
  vim.api.nvim_del_autocmd(aucmd_id)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(bwp_fired, true)
end

-- ── on_write_cmd: modified = false ──────────────────────────────────────────
--
-- NOTE: must use a real listed buffer (nvim_create_buf(true, false), buftype="").
-- Scratch buffers (buftype=nofile) silently ignore `vim.bo.modified = true`, so
-- the pre-condition assertion would always be false and the test would be a tautology.

T["on_write_cmd: modified transitions true→false after successful write"] = function()
  -- Real listed buffer so that `modified` is properly tracked.
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# Note", "some text" })
  -- nvim_buf_set_lines on a real listed buffer sets modified=true automatically;
  -- set explicitly as well so the pre-condition is clear.
  vim.bo[bufnr].modified = true

  -- Pre-condition: must be modified before the write.
  MiniTest.expect.equality(vim.bo[bufnr].modified, true)

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local modified_after = vim.bo[bufnr].modified
  vim.fn.delete(tmpfile)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Post-condition: handler must have cleared the flag.
  eq(modified_after, false)
end

-- ── on_write_cmd: no managed regions → all lines written ─────────────────────

T["on_write_cmd: no managed regions → all lines written unchanged"] = function()
  local bufnr = make_buf({ "# Title", "prose line A", "prose line B" })

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local written = vim.fn.readfile(tmpfile)
  vim.fn.delete(tmpfile)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#written, 3)
  eq(written[1], "# Title")
  eq(written[2], "prose line A")
  eq(written[3], "prose line B")
end

-- ── on_write_cmd: buffer NOT mutated during write ────────────────────────────

T["on_write_cmd: buffer lines unchanged after write (no mutation)"] = function()
  local bufnr = make_buf({
    "```tasks",
    "not done",
    "```",
    "- [ ] Rendered",
    "prose after",
  })

  managed.add_block(bufnr, 0, 2)
  managed.add_region(bufnr, 3, 3)

  local lines_before = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local lines_after = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.fn.delete(tmpfile)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Buffer must have exactly the same lines as before (no mutation).
  eq(#lines_before, #lines_after)
  for i = 1, #lines_before do
    eq(lines_before[i], lines_after[i])
  end
end

-- ── attach: dashboard sentinel set + BufWriteCmd registered on first draw ────

T["draw: dashboard sentinel set after first draw, buftype unchanged"] = function()
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  local buftype_before = vim.bo[bufnr].buftype

  draw_mod.draw(bufnr, { 0, 2 }, simple_layout("- [ ] T", "/v/note.md", 1))

  local sentinel = vim.b[bufnr].obsidian_tasks_dashboard
  local buftype_after = vim.bo[bufnr].buftype
  local autocmds = vim.api.nvim_get_autocmds({ event = "BufWriteCmd", buffer = bufnr })
  draw_mod.clear(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(sentinel, true)
  -- The previous implementation flipped buftype to "acwrite"; the regression
  -- guard is that buftype stays whatever it was (and is NOT "acwrite").
  eq(buftype_after, buftype_before)
  MiniTest.expect.equality(buftype_after ~= "acwrite", true)
  eq(#autocmds, 1)
end

-- ── compute_managed_ranges reflects live extmark positions ───────────────────

T["compute_managed_ranges: returns live region positions"] = function()
  local bufnr = make_buf({ "l0", "l1", "l2", "l3", "l4" })

  managed.add_region(bufnr, 1, 3) -- rows 1-3

  local ranges = save.compute_managed_ranges(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#ranges, 1)
  eq(ranges[1][1], 1) -- start_row
  eq(ranges[1][2], 3) -- end_row
end

T["compute_managed_ranges: empty when no regions registered"] = function()
  local bufnr = make_buf({ "no managed content" })

  local ranges = save.compute_managed_ranges(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#ranges, 0)
end

T["compute_managed_ranges: multiple regions returned sorted"] = function()
  local bufnr = make_buf({ "l0", "l1", "l2", "l3", "l4", "l5", "l6" })

  -- Add regions out of insertion order to test sorting.
  managed.add_region(bufnr, 4, 5)
  managed.add_region(bufnr, 1, 2)

  local ranges = save.compute_managed_ranges(bufnr)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  eq(#ranges, 2)
  -- First range by start_row.
  eq(ranges[1][1], 1)
  eq(ranges[1][2], 2)
  -- Second range.
  eq(ranges[2][1], 4)
  eq(ranges[2][2], 5)
end

-- ── two-block: both managed regions filtered independently ───────────────────

T["on_write_cmd: two query blocks — both managed regions dropped"] = function()
  -- Buffer:
  --   0  "```tasks"          kept
  --   1  "done"              kept
  --   2  "```"               kept
  --   3  "- [x] Done task"   managed region A (dropped)
  --   4  ""                  prose (kept)
  --   5  "```tasks"          kept
  --   6  "not done"          kept
  --   7  "```"               kept
  --   8  "- [ ] Open task"   managed region B (dropped)
  local bufnr = make_buf({
    "```tasks", -- 0
    "done", -- 1
    "```", -- 2
    "- [x] Done task", -- 3
    "", -- 4
    "```tasks", -- 5
    "not done", -- 6
    "```", -- 7
    "- [ ] Open task", -- 8
  })

  managed.add_block(bufnr, 0, 2)
  managed.add_region(bufnr, 3, 3)
  managed.add_block(bufnr, 5, 7)
  managed.add_region(bufnr, 8, 8)

  local tmpfile = vim.fn.tempname()
  save.on_write_cmd({ buf = bufnr, file = tmpfile })

  local written = vim.fn.readfile(tmpfile)
  vim.fn.delete(tmpfile)
  managed.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- 7 source lines (both task rows dropped).
  eq(#written, 7)
  eq(written[1], "```tasks")
  eq(written[2], "done")
  eq(written[3], "```")
  eq(written[4], "")
  eq(written[5], "```tasks")
  eq(written[6], "not done")
  eq(written[7], "```")
end

-- ── on_write_cmd: write-failure path ─────────────────────────────────────────
--
-- When writefile fails, the handler must:
--   (a) leave vim.bo[bufnr].modified = true so the user can retry
--   (b) NOT fire BufWritePost (render refresh / LSP must not run)
--   (c) call log.error to inform the user
--
-- This corresponds to the explicit task spec requirement:
--   "If the file write fails ... leave modified = true so they can retry."

T["on_write_cmd: write failure leaves modified=true, suppresses BufWritePost, calls log.error"] = function()
  -- Real listed buffer (buftype="") so modified is properly tracked.
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# Note" })
  vim.bo[bufnr].modified = true

  -- Pre-condition: buffer is modified.
  MiniTest.expect.equality(vim.bo[bufnr].modified, true)

  -- Capture BufWritePost firings for this buffer.
  local bwp_fired = false
  local aucmd_id = vim.api.nvim_create_autocmd("BufWritePost", {
    buffer = bufnr,
    callback = function()
      bwp_fired = true
    end,
  })

  -- Capture log.error calls.
  local log = require("obsidian-tasks.log")
  local error_msgs = {}
  local orig_error = log.error
  log.error = function(msg)
    error_msgs[#error_msgs + 1] = msg
  end

  -- Attempt to write to a path whose parent directory does not exist.
  save.on_write_cmd({ buf = bufnr, file = "/no/such/dir/file.md" })

  -- Restore log.error before assertions so any subsequent error is visible.
  log.error = orig_error
  vim.api.nvim_del_autocmd(aucmd_id)
  local modified_after = vim.bo[bufnr].modified
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- (a) modified must still be true — user must be able to retry.
  eq(modified_after, true)
  -- (b) BufWritePost must NOT have fired.
  eq(bwp_fired, false)
  -- (c) log.error must have been called with the file path in the message.
  MiniTest.expect.equality(#error_msgs >= 1, true)
  MiniTest.expect.equality(error_msgs[1]:find("/no/such/dir/file.md", 1, true) ~= nil, true)
end

-- ── attach: idempotency — no duplicate BufWriteCmd handlers ──────────────────
--
-- Calling attach(bufnr) twice must not register a duplicate BufWriteCmd
-- autocmd.  This is reachable in normal usage: render.refresh_buffer clears
-- _state[bufnr] (setting is_first_for_buf = true again on the next draw), so
-- attach can be re-entered for the same buffer.
--
-- A duplicate handler would fire on_write_cmd twice per :w, corrupting the
-- modified flag and double-firing BufWritePost.

T["attach: calling twice registers exactly one BufWriteCmd autocmd"] = function()
  local bufnr = vim.api.nvim_create_buf(false, true)

  save.attach(bufnr)
  save.attach(bufnr) -- second call must be a no-op

  local autocmds = vim.api.nvim_get_autocmds({ event = "BufWriteCmd", buffer = bufnr })
  vim.api.nvim_buf_delete(bufnr, { force = true })

  -- Exactly one BufWriteCmd handler must be registered (not two).
  eq(#autocmds, 1)
end

-- ── BufWritePre does NOT fire on a dashboard :w ──────────────────────────────
--
-- Vim's documented behavior: when BufWriteCmd is registered for a buffer,
-- the entire write pipeline is replaced — BufWritePre/BufWrite/BufWritePost
-- are not auto-emitted.  This is what gives us the "no other plugin mutates
-- the buffer before save" guarantee even though buftype is "".  If this
-- ever regresses, plugins (LSP formatters, prettier-on-save, etc.) could
-- mutate the buffer in BufWritePre and bypass our managed-row filter.

T['attach: BufWritePre is suppressed on :w even with buftype=""'] = function()
  local tmpfile = vim.fn.tempname() .. ".md"
  vim.fn.writefile({ "seed" }, tmpfile)
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(tmpfile))
  local bufnr = vim.api.nvim_get_current_buf()

  save.attach(bufnr)

  local pre_fired = false
  vim.api.nvim_create_autocmd("BufWritePre", {
    buffer = bufnr,
    callback = function()
      pre_fired = true
    end,
  })

  vim.cmd("silent! write")

  local buftype = vim.bo[bufnr].buftype
  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(tmpfile)

  eq(pre_fired, false)
  eq(buftype, "")
end

return T
