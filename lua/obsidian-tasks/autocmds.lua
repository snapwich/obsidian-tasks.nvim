-- lua/obsidian-tasks/autocmds.lua
-- Auto-render wiring: BufReadPost, FocusGained, BufWritePost, BufDelete.
-- F4 edit-through (User:ObsidianNoteWritePre diff+patch+strip) has been removed.
-- Called from init.setup() after opts are merged and validated.
--
-- No autocmds are registered unless setup() is called.

local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Return true if *bufnr* is a valid, loaded markdown buffer.
--- @param bufnr integer
--- @return boolean
local function is_md_buf(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:match("%.md$") ~= nil
end

--- Try workspace_for_path; return nil on any error (obsidian not ready, etc.).
--- Protects against obsidian.nvim not being set up when autocmds fire early.
--- @param path string
--- @return table|nil  workspace or nil
local function safe_workspace_for_path(path)
  local ok, result = pcall(function()
    return require("obsidian-tasks.util.obsidian").workspace_for_path(path)
  end)
  if not ok then
    return nil
  end
  return result
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Register all render autocmds under the `obsidian_tasks_render` augroup.
--- Must be called after opts are available (i.e. from init.setup()).
--- Re-calling this clears and re-registers the augroup.
---
--- @param opts table  merged plugin opts (see config.lua)
function M.setup(opts)
  local group = vim.api.nvim_create_augroup("obsidian_tasks_render", { clear = true })

  -- ── BufReadPost ─────────────────────────────────────────────────────────────
  -- Auto-render vault md files that contain ```tasks blocks.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      -- Respect auto_render = false.
      if not opts.auto_render then
        return
      end

      local bufnr = ev.buf
      local path = vim.api.nvim_buf_get_name(bufnr)

      -- Skip files not in any configured vault.
      local ws = safe_workspace_for_path(path)
      if ws == nil then
        return
      end

      -- Skip buffers that have no ```tasks block.
      local render = require("obsidian-tasks.render")
      if not render.has_tasks_block(bufnr) then
        return
      end

      -- Defer past the BufReadPost lock so we don't modify the buffer mid-read.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(bufnr) then
          render.render_buffer(bufnr, ws)
        end
      end)
    end,
  })

  -- ── FocusGained ─────────────────────────────────────────────────────────────
  -- Refresh all visible vault md buffers that have an active render.
  -- Uses rerender_buffer to preserve existing fold states across the re-render.
  vim.api.nvim_create_autocmd("FocusGained", {
    group = group,
    callback = function()
      local render = require("obsidian-tasks.render")

      -- Enumerate all visible buffers (one per window, de-duped).
      local seen = {}
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) then
          local bufnr = vim.api.nvim_win_get_buf(win)
          if not seen[bufnr] and is_md_buf(bufnr) and render._buffer_state[bufnr] ~= nil then
            local path = vim.api.nvim_buf_get_name(bufnr)
            local ws = safe_workspace_for_path(path)
            if ws ~= nil then
              seen[bufnr] = true
              render.rerender_buffer(bufnr, ws)
            end
          end
        end
      end
    end,
  })

  -- ── BufWritePost ────────────────────────────────────────────────────────────
  -- Re-render the buffer after a write when an active render exists.
  -- Uses rerender_buffer to implement block lifecycle:
  --   • Existing blocks: re-rendered in place, fold state preserved.
  --   • New blocks: rendered + folded per default_folded.
  --   • Deleted blocks: cleaned up by clear_buffer inside rerender_buffer.
  --
  -- For dashboard buffers (acwrite), this event is fired manually by the
  -- BufWriteCmd handler in render/save.lua after writefile succeeds.
  -- For regular .md buffers written via the normal Neovim path, this fires
  -- automatically after the file is saved on disk.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      local render = require("obsidian-tasks.render")

      -- Skip buffers with no active render.
      if render._buffer_state[bufnr] == nil then
        return
      end

      local path = vim.api.nvim_buf_get_name(bufnr)
      local ws = safe_workspace_for_path(path)
      if ws == nil then
        return
      end

      render.rerender_buffer(bufnr, ws)
    end,
  })

  -- ── BufDelete ───────────────────────────────────────────────────────────────
  -- Clear render state when a buffer is removed to avoid stale entries.
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      local bufnr = ev.buf
      local render = require("obsidian-tasks.render")
      render.clear_buffer(bufnr)
      require("obsidian-tasks.render.hygiene")._cleanup(bufnr)
    end,
  })
end

return M
