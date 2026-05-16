-- tests/integration_real/test_auto_render_and_universal_keymaps.lua
-- Real-deps regression tests for two UX gaps:
--
--   (1) Universal keymap attach: every .md buffer in a workspace gets
--       <leader>t* on BufReadPost (and BufNewFile), so <leader>tt works on
--       any task line — not just rendered dashboard rows.
--
--   (2) Auto-render on first BufWritePost: when the user writes a new file
--       (or adds a ```tasks block to an existing one), BufReadPost has
--       already fired (or hasn't fired at all for new files), so the
--       buffer has no render state.  BufWritePost must do the initial
--       render when has_tasks_block(bufnr) is true.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

--- Find a buffer-local normal-mode keymap by lhs.  Handles <leader> expansion.
local function find_nmap(bufnr, lhs)
  local leader = vim.g.mapleader or "\\"
  local expanded = lhs:gsub("<[Ll]eader>", leader)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs or m.lhs == expanded then
      return m
    end
  end
  return nil
end

-- ── Universal keymap attach ──────────────────────────────────────────────────

T["BufReadPost on a vault md installs <leader>tt even with no tasks block"] = function()
  -- tasks_a.md is a regular note in the fixture vault — no ```tasks block.
  local path = fixture_vault .. "/tasks_a.md"

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  -- BufReadPost has already fired during :edit; keymaps should be in place.

  eq(find_nmap(bufnr, "<leader>tt") ~= nil, true)
  eq(find_nmap(bufnr, "<leader>tp") ~= nil, true)
  eq(find_nmap(bufnr, "<leader>tD") ~= nil, true)

  -- Dashboard-only keymaps must NOT be on a non-dashboard buffer.
  eq(find_nmap(bufnr, "<leader>tr"), nil)

  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["BufNewFile on a new md in the vault installs <leader>tt"] = function()
  local path = fixture_vault .. "/_tmp_new_file.md"
  -- Ensure it doesn't exist (so BufNewFile fires, not BufReadPost).
  pcall(vim.fn.delete, path)

  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"

  eq(find_nmap(bufnr, "<leader>tt") ~= nil, true)

  vim.api.nvim_buf_delete(bufnr, { force = true })
  pcall(vim.fn.delete, path)
end

-- ── Auto-render on first BufWritePost ────────────────────────────────────────

T["BufWritePost on a buffer that newly contains a tasks block triggers render"] = function()
  local path = fixture_vault .. "/_tmp_new_dashboard.md"
  pcall(vim.fn.delete, path)

  -- Open the new buffer (BufNewFile fires; no _buffer_state yet).
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"

  local render = require("obsidian-tasks.render")
  eq(render._buffer_state[bufnr], nil) -- precondition: no render yet

  -- Add content with a tasks block.
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "# Test dashboard",
    "",
    "```tasks",
    "not done",
    "```",
  })

  -- Save: should fire BufWritePost, which (per the fix) initiates render_buffer
  -- because has_tasks_block(bufnr) is true and no state exists yet.
  vim.cmd("write")

  -- BufWritePost ran synchronously; render state must now exist.
  eq(type(render._buffer_state[bufnr]), "table")
  eq(#render._buffer_state[bufnr] > 0, true, "at least one rendered block")

  -- Dashboard-only keymaps now installed.
  eq(find_nmap(bufnr, "<leader>tr") ~= nil, true)
  eq(find_nmap(bufnr, "u") ~= nil, true)

  -- Cleanup.
  render.clear_buffer(bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  pcall(vim.fn.delete, path)
end

return T
