-- tests/integration_real/test_bufwritepost_propagates.lua
-- Regression test: writing a source .md from inside nvim must refresh the
-- index entry for that file AND re-render every other buffer whose
-- reverse_index references it.
--
-- This is the only path that propagates source-file edits to query buffers
-- (external edits aren't auto-detected; the user must `<leader>tr`).

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

--- Read the entire file as a string.
--- @param path string
--- @return string
local function read_file(path)
  local f = assert(io.open(path, "r"))
  local s = f:read("*a")
  f:close()
  return s
end

--- Write *content* to *path* without going through Neovim.
--- @param path string
--- @param content string
local function write_file(path, content)
  local f = assert(io.open(path, "w"))
  f:write(content)
  f:close()
end

T["BufWritePost on source file triggers cross-buffer refresh via reverse_index"] = function()
  local index = require("obsidian-tasks.index")
  local render = require("obsidian-tasks.render")

  local health_path = fixture_vault .. "/personal/health.md"
  local by_tag_path = fixture_vault .. "/queries/by-tag.md"

  local original_health = read_file(health_path)
  local restored = false
  local function restore_file()
    if restored then
      return
    end
    restored = true
    pcall(write_file, health_path, original_health)
  end

  -- ── 1. Synchronously seed the index for the files the test depends on. ────
  -- We skip refresh_all (which is async and triggers a vim.wait loop that
  -- interacts badly with mini.test's runner).
  index.refresh_file(health_path)

  -- ── 2. Render by-tag.md so reverse_index[health.md] ⊇ {by_tag_bufnr}. ─────
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(by_tag_path))
  local by_tag_bufnr = vim.api.nvim_get_current_buf()
  vim.bo[by_tag_bufnr].filetype = "markdown"
  render.render_buffer(by_tag_bufnr, require("fixture_ws")())

  -- Sanity-check: at least one query block in by-tag.md matched a health task.
  local rev_set = {}
  for _, b in ipairs(index.reverse_index(health_path)) do
    rev_set[b] = true
  end
  eq(rev_set[by_tag_bufnr], true)

  -- ── 3. Open health.md in a *split* so by-tag.md stays visible. ──────────
  -- BufWritePost only propagates rerenders to buffers with a live window;
  -- hidden buffers are intentionally skipped to avoid clear+render moving
  -- the buffer's internal cursor to a fold line.  The split keeps by-tag.md
  -- visible so the propagation path is exercised.
  vim.cmd("noswapfile split " .. vim.fn.fnameescape(health_path))
  local health_bufnr = vim.api.nvim_get_current_buf()

  -- ── 4. Spy on render.rerender_buffer — the function our BufWritePost path
  --       uses for cross-buffer propagation. ─────────────────────────────────
  local refreshed = {}
  local orig_refresh = render.rerender_buffer
  render.rerender_buffer = function(bufnr, ws)
    refreshed[#refreshed + 1] = bufnr
    return orig_refresh(bufnr, ws)
  end

  -- ── 5. Mutate the loaded buffer and :write — same path a user takes. ────
  vim.api.nvim_buf_set_lines(health_bufnr, -1, -1, false, { "" })
  vim.cmd("silent write")

  render.rerender_buffer = orig_refresh

  -- ── 6. Assert by-tag.md got a refresh call. ─────────────────────────────
  local saw_by_tag = false
  for _, b in ipairs(refreshed) do
    if b == by_tag_bufnr then
      saw_by_tag = true
    end
  end
  eq(saw_by_tag, true)

  -- Clean up.
  vim.api.nvim_buf_delete(health_bufnr, { force = true })
  vim.api.nvim_buf_delete(by_tag_bufnr, { force = true })
  restore_file()
end

return T
