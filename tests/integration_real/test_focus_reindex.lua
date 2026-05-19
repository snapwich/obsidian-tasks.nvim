-- tests/integration_real/test_focus_reindex.lua
-- Task 10: FocusGained re-indexes loaded files from disk.
--
-- An external edit (Obsidian desktop app, `git pull`, syncthing) to a file
-- that is in the index but not necessarily open should be picked up the next
-- time Neovim regains focus — no manual `<leader>tr` required.
--
-- HARD REQUIREMENT: the focus refresh must NOT clear linger state.  Clearing
-- lingers is reserved for the manual `<leader>tr` / :ObsidianTask refresh path
-- (render.refresh_with_clear_lingers).  FocusGained must rerender via
-- rerender_buffer (lingers intact).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

--- True if any line of *bufnr* contains *substr*.
local function buf_has(bufnr, substr)
  for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    if l:find(substr, 1, true) then
      return true
    end
  end
  return false
end

T["FocusGained re-indexes external edits and preserves lingers"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")

  local source_path = fixture_vault .. "/qa_focus_source.md"
  local dash_path = fixture_vault .. "/qa_focus_dash.md"

  local opened_bufs = {}
  local orig_clear = render.refresh_with_clear_lingers
  local cleared = false

  local function restore()
    render.refresh_with_clear_lingers = orig_clear
    for _, b in ipairs(opened_bufs) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
    os.remove(source_path)
    os.remove(dash_path)
    index.invalidate(source_path)
  end

  local ok, err = pcall(function()
    -- ── 1. Source file with a single matching task; seed the index. ─────────
    write_file(
      source_path,
      table.concat({
        "# Focus source",
        "",
        "- [ ] Focus task one #task",
        "",
      }, "\n")
    )
    index.invalidate(source_path) -- drop any stale entry from a prior run
    index.refresh_file(source_path)

    -- ── 2. Dashboard querying that source file; render it (visible). ────────
    write_file(
      dash_path,
      table.concat({
        "# Focus dash",
        "",
        "```tasks",
        "not done",
        "path includes qa_focus_source",
        "```",
        "",
      }, "\n")
    )

    vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
    local dash_buf = vim.api.nvim_get_current_buf()
    opened_bufs[#opened_bufs + 1] = dash_buf
    vim.bo[dash_buf].filetype = "markdown"
    render.render_buffer(dash_buf, Obsidian.workspace)

    -- Drain any async lazy-init vault walk so it can't race the external edit.
    vim.wait(300, function()
      return false
    end)

    -- Sanity: the dashboard shows task one and not task two yet.
    eq(buf_has(dash_buf, "Focus task one"), true)
    eq(buf_has(dash_buf, "Focus task two"), false)

    -- ── 3. Spy: FocusGained must NEVER clear lingers. ───────────────────────
    render.refresh_with_clear_lingers = function(...)
      cleared = true
      return orig_clear(...)
    end

    -- ── 4. External edit: a new matching task appears on disk. ──────────────
    write_file(
      source_path,
      table.concat({
        "# Focus source",
        "",
        "- [ ] Focus task one #task",
        "- [ ] Focus task two #task",
        "",
      }, "\n")
    )
    -- fs_stat mtime has 1s resolution; the seed parse above may share this
    -- wall-clock second.  Push the file's mtime forward so the mtime gate
    -- inside refresh_file sees a change (mirrors a real edit seconds later).
    local future = os.time() + 10
    assert(vim.uv.fs_utime(source_path, future, future))

    -- ── 5. Regain focus. ────────────────────────────────────────────────────
    vim.api.nvim_exec_autocmds("FocusGained", { pattern = "*" })

    -- ── 6. The index was refreshed from disk (deterministic). ───────────────
    local entry = index._raw()[source_path]
    eq(type(entry), "table")
    eq(#entry.tasks, 2)

    -- ── 7. The visible dashboard rerendered with the fresh task. ────────────
    eq(buf_has(dash_buf, "Focus task two"), true)

    -- ── 8. Lingers were NOT cleared by the focus refresh. ───────────────────
    eq(cleared, false)
  end)

  restore()
  if not ok then
    error(err)
  end
end

return T
