-- lua/obsidian-tasks/render/keymap.lua
-- Buffer-local <CR> and gf mappings for render buffers.
--
-- M.attach(bufnr): install buffer-local normal-mode mappings for <CR> and gf.
--   • On a render task line: jump to source file at recorded line.
--   • On a non-render line: fall through to obsidian.actions.smart_action().
-- M.detach(bufnr): remove the buffer-local mappings.
--
-- attach is called from render/draw.draw on first draw for a buffer;
-- detach is called from render/draw.clear (full-buffer clear only).
--
-- draw is lazy-required inside the handler to avoid a circular dependency:
--   draw.lua → keymap.lua (attach/detach)
--   keymap.lua handler → draw.lua (is_render_line)

local M = {}

--- Build the <CR>/<gf> handler closed over *bufnr*.
--- @param bufnr integer
--- @return fun()
local function make_handler(bufnr)
  return function()
    -- Lazy-require draw to avoid circular dependency at module load time.
    local draw = require("obsidian-tasks.render.draw")

    -- nvim_win_get_cursor returns {row, col} with row 1-indexed.
    -- draw.is_render_line uses 0-indexed row.
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lnum = cursor[1] - 1

    local meta = draw.is_render_line(bufnr, lnum)
    if meta and meta.src_path then
      -- Jump to source.  Use :edit (not :e!) to preserve unsaved changes in
      -- the destination buffer if it is already loaded.
      vim.cmd("edit " .. vim.fn.fnameescape(meta.src_path))
      -- src_line is 1-indexed (ripgrep line_number convention).
      vim.api.nvim_win_set_cursor(0, { meta.src_line, 0 })
    else
      -- Fall through: delegate to obsidian.actions.smart_action().
      local ok, actions = pcall(require, "obsidian.actions")
      if ok and type(actions.smart_action) == "function" then
        local result = actions.smart_action()
        if type(result) == "string" then
          local keys = vim.api.nvim_replace_termcodes(result, true, false, true)
          vim.api.nvim_feedkeys(keys, "n", false)
        end
      end
    end
  end
end

--- Attach buffer-local <CR> and gf mappings to *bufnr*.
--- Safe to call multiple times (idempotent: last definition wins).
--- @param bufnr integer
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local handler = make_handler(bufnr)
  local opts = {
    buffer = bufnr,
    noremap = true,
    silent = true,
    desc = "obsidian-tasks: jump to source or smart action",
  }
  vim.keymap.set("n", "<CR>", handler, opts)
  vim.keymap.set("n", "gf", handler, opts)
end

--- Detach buffer-local <CR> and gf mappings from *bufnr*.
--- Safe to call when no mappings exist (no-op).
--- @param bufnr integer
function M.detach(bufnr)
  pcall(vim.keymap.del, "n", "<CR>", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "gf", { buffer = bufnr })
end

return M
