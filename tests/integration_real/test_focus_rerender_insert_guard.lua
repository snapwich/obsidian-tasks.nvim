-- tests/integration_real/test_focus_rerender_insert_guard.lua
-- Regression test for BUG: FocusGained while the user is typing in a dashboard
-- wipes the in-flight insert-mode input.
--
-- The FocusGained handler rerenders every visible rendered buffer.  A rerender
-- is a clear+render from the index, and insert-mode lines exist only in the
-- buffer until edit.flush drains them to source at InsertLeave — so a refocus
-- mid-insert destroyed the user's typing.
--
-- Post-fix expectation: rerender_buffer bails when the target buffer is the
-- current buffer in insert/replace mode and defers the rerender to a one-shot
-- InsertLeave autocmd, so:
--   (a) in-flight typed lines survive the refocus, and
--   (b) the focus refresh (external edits picked up by the handler's re-index)
--       still lands once the user leaves insert mode.
--
-- Real keypresses are required: vim.fn.mode() returns 'n' during programmatic
-- edits, so the gate never fires under nvim_buf_set_lines-style simulation.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"
local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

-- ── Child Neovim factory ─────────────────────────────────────────────────────

--- Boot a child nvim against the real fixture vault: write a one-task source
--- file and a dashboard querying it, open the dashboard, render it, unfold.
--- The FocusGained handler only targets visible vault .md buffers with an
--- active render, so the dashboard must be a real file inside the vault.
--- Returns child, src_path, dash_path.
local function spawn_child_with_vault_dashboard()
  local src_path = fixture_vault .. "/qa_insert_guard_source.md"
  local dash_path = fixture_vault .. "/qa_insert_guard_dash.md"

  write_file(src_path, "# Insert guard source\n\n- [ ] Walk dog #task\n")
  write_file(
    dash_path,
    table.concat({
      "# Insert guard dash",
      "",
      "```tasks",
      "not done",
      "path includes qa_insert_guard_source",
      "```",
      "",
    }, "\n")
  )

  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })

  child.lua(
    [[
    local cwd, deps_dir, src_path, dash_path = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(cwd)

    -- Treesitter parsers may not be installed; swallow errors so .md bufload works.
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end

    -- auto_render=false: render explicitly below so no scheduled BufReadPost
    -- render races the test's keystrokes.
    require("obsidian-tasks").setup({ global_filter = "#task", auto_render = false })

    local index = require("obsidian-tasks.index")
    index.invalidate(src_path)
    index.refresh_file(src_path)

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].filetype = "markdown"

    local render = require("obsidian-tasks.render.init")
    local ws = require("obsidian-tasks.util.obsidian").workspace_for_path(dash_path)
    render.render_buffer(bufnr, ws)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src_path = src_path
  ]],
    { cwd, deps_dir, src_path, dash_path }
  )

  return child, src_path, dash_path
end

local function cleanup(child, src_path, dash_path)
  child.stop()
  os.remove(src_path)
  os.remove(dash_path)
end

--- True if any line of the child's dashboard buffer contains *substr*.
local function child_buf_has(child, substr)
  local lines = child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
  for _, l in ipairs(lines) do
    if l:find(substr, 1, true) then
      return true
    end
  end
  return false
end

--- 1-indexed row of the first dashboard line containing *substr*.
local function child_row_of(child, substr)
  local lines = child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)")
  for i, l in ipairs(lines) do
    if l:find(substr, 1, true) then
      return i
    end
  end
  error(substr .. " not found in dashboard render: " .. vim.inspect(lines))
end

-- ── (a) FocusGained mid-insert must not wipe in-flight typing ────────────────

T["FocusGained during insert preserves typed task; flush commits it on <Esc>"] = function()
  local child, src_path, dash_path = spawn_child_with_vault_dashboard()

  local ok, err = pcall(function()
    local row = child_row_of(child, "Walk dog")
    child.api.nvim_win_set_cursor(0, { row, 0 })

    -- Open a line below the rendered task and type a new task — stay in insert.
    child.type_keys("o", "- [ ] Brand new task #task")
    eq(child.lua_get("vim.fn.mode()"), "i")

    -- Refocus the terminal while still typing.
    child.lua([[vim.api.nvim_exec_autocmds("FocusGained", { pattern = "*" })]])

    -- The in-flight line must survive, and we must still be in insert mode.
    eq(child_buf_has(child, "Brand new task"), true, "refocus mid-insert wiped the in-flight typed task")
    eq(child.lua_get("vim.fn.mode()"), "i")

    -- Leave insert: InsertLeave flush propagates the new task to source.
    child.type_keys("<Esc>")
    vim.loop.sleep(300)

    local src_after = table.concat(child.lua_get("vim.fn.readfile(_G._src_path)"), "\n")
    eq(src_after:find("Brand new task", 1, true) ~= nil, true, "typed task must reach source after <Esc>")
    eq(child_buf_has(child, "Brand new task"), true, "typed task must survive the post-flush rerender")
  end)

  cleanup(child, src_path, dash_path)
  if not ok then
    error(err)
  end
end

-- ── (b) Deferred rerender lands on InsertLeave ───────────────────────────────
-- The focus handler's re-index runs even mid-insert (it only mutates the
-- index); the rerender it skipped must drain on InsertLeave so external edits
-- still show up — even when the insert session itself queued no edits.

T["external edit during insert appears after InsertLeave (deferred rerender)"] = function()
  local child, src_path, dash_path = spawn_child_with_vault_dashboard()

  local ok, err = pcall(function()
    local row = child_row_of(child, "Walk dog")
    child.api.nvim_win_set_cursor(0, { row, 0 })

    -- Enter insert mode but type nothing: the InsertLeave flush will have an
    -- empty queue, so only the deferred rerender can surface the external edit.
    child.type_keys("i")
    eq(child.lua_get("vim.fn.mode()"), "i")

    -- External writer adds a second matching task; push mtime forward so the
    -- 1s-resolution mtime gate in refresh_file sees a change.
    write_file(src_path, "# Insert guard source\n\n- [ ] Walk dog #task\n- [ ] Task two #task\n")
    child.lua([[
      local future = os.time() + 10
      assert(vim.uv.fs_utime(_G._src_path, future, future))
      vim.api.nvim_exec_autocmds("FocusGained", { pattern = "*" })
    ]])

    -- Mid-insert: rerender deferred, so the new task is not drawn yet.
    eq(child_buf_has(child, "Task two"), false, "rerender must be deferred while in insert mode")

    child.type_keys("<Esc>")
    vim.loop.sleep(300)

    eq(child_buf_has(child, "Task two"), true, "deferred rerender must land on InsertLeave")
  end)

  cleanup(child, src_path, dash_path)
  if not ok then
    error(err)
  end
end

return T
