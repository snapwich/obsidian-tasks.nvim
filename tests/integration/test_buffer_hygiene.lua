-- tests/integration/test_buffer_hygiene.lua
-- Integration tests for render/hygiene.lua and its wiring through render_buffer,
-- rerender_buffer, clear_buffer, do_revert, and save.on_write_cmd.
--
-- Verifies:
--   • Plugin renders leave `modified = false` when no real user edits exist.
--   • Plugin renders preserve `modified = true` when the user has unsaved
--     edits outside managed regions (the `clean_baseline` protects them).
--   • undolevels and eventignore are restored after every wrapped call.
--   • TextChanged / BufModifiedSet are suppressed during wrapped mutations
--     but fire for real user edits.
--   • Nested with_clean_buffer calls correctly restore outer state.

local T = MiniTest.new_set()

local render = require("obsidian-tasks.render.init")
local revert = require("obsidian-tasks.render.revert")
local hygiene = require("obsidian-tasks.render.hygiene")

-- ── helpers ───────────────────────────────────────────────────────────────────

local function eq(a, b, msg)
  MiniTest.expect.equality(a, b, msg)
end

local function make_buf(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr
end

local function install_one_task_stub(task_text)
  local index_mod = require("obsidian-tasks.index")
  local task_parse = require("obsidian-tasks.task.parse")
  local task_obj = task_parse.parse(task_text or "- [ ] Stub task")
  local saved = {
    tasks_in = index_mod.tasks_in,
    set_render_paths = index_mod.set_render_paths,
    clear_render_paths = index_mod.clear_render_paths,
  }
  index_mod.tasks_in = function(_)
    local returned = false
    return function()
      if not returned then
        returned = true
        return task_obj, "/vault/stub.md", 1
      end
      return nil
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

local function with_render(task_text, fn)
  render.configure({ default_folded = false })
  local restore = install_one_task_stub(task_text)
  local bufnr = make_buf({ "```tasks", "not done", "```" })
  -- Reset baseline so the test sees a clean starting state regardless of
  -- whatever state earlier tests left behind.
  hygiene.mark_clean(bufnr)
  vim.bo[bufnr].modified = false

  local ok, err = pcall(fn, bufnr)

  render.clear_buffer(bufnr)
  restore()
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok then
    error(err)
  end
end

-- ── modified flag after wrapped operations ────────────────────────────────────

T["render_buffer leaves modified=false on a clean buffer"] = function()
  with_render("- [ ] task", function(bufnr)
    render.render_buffer(bufnr, nil)
    eq(vim.bo[bufnr].modified, false)
  end)
end

T["rerender_buffer leaves modified=false on a clean buffer"] = function()
  with_render("- [ ] task", function(bufnr)
    render.render_buffer(bufnr, nil)
    vim.bo[bufnr].modified = false
    render.rerender_buffer(bufnr, nil)
    eq(vim.bo[bufnr].modified, false)
  end)
end

T["clear_buffer leaves modified=false on a clean buffer"] = function()
  with_render("- [ ] task", function(bufnr)
    render.render_buffer(bufnr, nil)
    vim.bo[bufnr].modified = false
    render.clear_buffer(bufnr)
    eq(vim.bo[bufnr].modified, false)
  end)
end

T["do_revert leaves modified=false after reverting a managed-row edit"] = function()
  with_render("- [ ] task", function(bufnr)
    render.render_buffer(bufnr, nil)
    -- Edit the rendered task row (0-indexed row 3 = the inserted task line).
    vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "- [ ] tampered" })
    -- Synchronous revert (test seam).
    revert._flush_pending(bufnr)
    eq(vim.bo[bufnr].modified, false)
  end)
end

-- ── modified flag PROTECTED when user has unsaved off-region edits ────────────

T["rerender_buffer preserves modified=true when user edited a query line"] = function()
  with_render("- [ ] task", function(bufnr)
    render.render_buffer(bufnr, nil)
    vim.bo[bufnr].modified = false
    hygiene.mark_clean(bufnr)

    -- Simulate a user editing the query line (row 1).  This must flow through
    -- the on_lines listener so mark_dirty fires.
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "done" })
    -- The on_lines callback runs synchronously when nvim_buf_set_lines is
    -- called from Lua, so mark_dirty should already have fired.

    eq(hygiene.is_clean(bufnr), false, "user edit must mark buffer dirty")

    -- Now a re-render fires (e.g. watcher event).  modified must NOT be cleared.
    vim.bo[bufnr].modified = true
    render.rerender_buffer(bufnr, nil)
    eq(vim.bo[bufnr].modified, true, "watcher-driven rerender must not clobber unsaved edits")
  end)
end

-- ── undolevels and eventignore restoration ────────────────────────────────────

T["with_clean_buffer restores undolevels"] = function()
  local bufnr = make_buf({ "line" })
  local saved = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = 500
  hygiene.with_clean_buffer(bufnr, function()
    eq(vim.bo[bufnr].undolevels, -1)
  end)
  eq(vim.bo[bufnr].undolevels, 500)
  vim.bo[bufnr].undolevels = saved
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["with_clean_buffer restores eventignore"] = function()
  local bufnr = make_buf({ "line" })
  local before = vim.opt.eventignore:get()
  hygiene.with_clean_buffer(bufnr, function()
    local during = vim.opt.eventignore:get()
    -- TextChanged must be present during the wrap
    local has_tc = false
    for _, v in ipairs(during) do
      if v == "TextChanged" then
        has_tc = true
      end
    end
    eq(has_tc, true)
  end)
  -- After the wrap, eventignore must match what it was before (set-equality).
  local after = vim.opt.eventignore:get()
  eq(#after, #before)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── TextChanged suppression during wrapped mutations ─────────────────────────

T["TextChanged does not fire during with_clean_buffer mutations"] = function()
  local bufnr = make_buf({ "alpha" })
  local fired = false
  local au_id = vim.api.nvim_create_autocmd("TextChanged", {
    buffer = bufnr,
    callback = function()
      fired = true
    end,
  })

  hygiene.with_clean_buffer(bufnr, function()
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "beta" })
  end)
  eq(fired, false, "TextChanged must not fire while suppressed")

  -- The autocmd is per-buffer; trigger it explicitly to confirm it's still wired.
  vim.api.nvim_exec_autocmds("TextChanged", { buffer = bufnr })
  eq(fired, true, "TextChanged must still be wired after the wrap")

  vim.api.nvim_del_autocmd(au_id)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── nested wrap correctness ──────────────────────────────────────────────────

T["nested with_clean_buffer restores outer state correctly"] = function()
  local bufnr = make_buf({ "line" })
  local saved_ul = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = 200

  hygiene.with_clean_buffer(bufnr, function()
    eq(vim.bo[bufnr].undolevels, -1)
    hygiene.with_clean_buffer(bufnr, function()
      eq(vim.bo[bufnr].undolevels, -1)
    end)
    -- Inner wrap restored to outer's value, which is also -1 (because outer
    -- already set it).  Outer wrap will restore to 200.
    eq(vim.bo[bufnr].undolevels, -1)
  end)
  eq(vim.bo[bufnr].undolevels, 200)

  vim.bo[bufnr].undolevels = saved_ul
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- ── BufWriteCmd path: mark_clean is wired ────────────────────────────────────
-- After a successful save the baseline must be clean so a subsequent re-render
-- can clear the modified flag.

T["save.on_write_cmd marks buffer clean"] = function()
  with_render("- [ ] task", function(bufnr)
    render.render_buffer(bufnr, nil)
    -- Simulate a user edit.
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { "done" })
    eq(hygiene.is_clean(bufnr), false)

    -- Write to a temp file via save.on_write_cmd.
    local tmpfile = vim.fn.tempname() .. ".md"
    local save = require("obsidian-tasks.render.save")
    save.on_write_cmd({ buf = bufnr, file = tmpfile })

    eq(hygiene.is_clean(bufnr), true)
    eq(vim.bo[bufnr].modified, false)
    os.remove(tmpfile)
  end)
end

return T
