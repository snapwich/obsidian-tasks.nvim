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

  -- ── BufReadPre ──────────────────────────────────────────────────────────────
  -- A :edit / :edit! reloads the buffer from disk: Neovim replaces buffer
  -- content but our extmarks survive at clamped positions, and the side tables
  -- in render/draw + managed still describe the pre-reload render.  Without
  -- clearing here, the BufReadPost re-render would call clear_buffer which
  -- trusts the stale region extmarks and deletes the wrong rows from the
  -- freshly-loaded buffer (eating queries 2..N).
  --
  -- clear_state drops state + extmarks WITHOUT touching buffer lines (the
  -- reload is about to replace them anyway).
  vim.api.nvim_create_autocmd("BufReadPre", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local render = require("obsidian-tasks.render")
      -- Defensive against test stubs that don't model _buffer_state.
      if type(render._buffer_state) == "table" and render._buffer_state[ev.buf] ~= nil then
        if type(render.clear_state) == "function" then
          render.clear_state(ev.buf)
        end
      end
    end,
  })

  -- ── BufReadPost ─────────────────────────────────────────────────────────────
  -- For every .md file in a configured vault:
  --   (a) install the universal task-editing leader keymaps so <leader>t*
  --       works on any task line, not just rendered dashboard rows;
  --   (b) auto-render the buffer if it contains a ```tasks block.
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      local path = vim.api.nvim_buf_get_name(bufnr)

      -- Skip files not in any configured vault.
      local ws = safe_workspace_for_path(path)
      if ws == nil then
        return
      end

      -- (a) Universal keymap attach: every md in a workspace gets <leader>t*
      -- so users can act on task lines anywhere, not just on dashboards.
      -- The attach itself respects opts.setup_keymaps internally.
      pcall(function()
        require("obsidian-tasks.render.keymap").attach_universal(bufnr)
      end)

      -- (b) Source-row diagnostics — every md in a workspace gets diagnostics
      -- for malformed task fields (invalid dates, bad priority levels, etc.)
      -- on the source rows where the user actually types.  Refresh the index
      -- first so the diagnostic walk reflects the current disk content.
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        pcall(function()
          local idx = require("obsidian-tasks.index")
          idx.invalidate(path)
          idx.refresh_file(path)
          require("obsidian-tasks.render").refresh_source_diagnostics(bufnr, path)
        end)
      end)

      -- (c) Auto-render — gated by opts.auto_render.
      if not opts.auto_render then
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

  -- ── BufNewFile ──────────────────────────────────────────────────────────────
  -- Newly-created md buffers (path doesn't exist on disk yet) don't trigger
  -- BufReadPost.  Attach the universal keymaps here so <leader>t* is wired
  -- before the user even saves; auto-render lands on the first BufWritePost
  -- (handled in the BufWritePost callback below).
  vim.api.nvim_create_autocmd("BufNewFile", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      local path = vim.api.nvim_buf_get_name(bufnr)
      if safe_workspace_for_path(path) == nil then
        return
      end
      pcall(function()
        require("obsidian-tasks.render.keymap").attach_universal(bufnr)
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
  -- Two responsibilities on every .md write in a workspace:
  --
  --  1. Refresh the index entry for the written file from disk and re-render
  --     every other buffer that references that file (via reverse_index).
  --     This is the only path that propagates source-file edits to query
  --     buffers — external edits (made outside nvim) are not auto-detected;
  --     the user must `<leader>tr` to pick them up.
  --
  --  2. Re-render *this* buffer if it has an active render (i.e. contains
  --     tasks blocks).  Uses rerender_buffer to preserve fold state and
  --     implement block lifecycle (new/deleted blocks).
  --
  -- For dashboard buffers, this event is fired manually by the BufWriteCmd
  -- handler in render/save.lua after writefile succeeds (BufWriteCmd
  -- replaces Neovim's writer, so BufWritePost is not auto-emitted).
  -- For regular .md buffers written via the normal Neovim path, this fires
  -- automatically after the file is saved on disk.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      local render = require("obsidian-tasks.render")

      local path = vim.api.nvim_buf_get_name(bufnr)
      local ws = safe_workspace_for_path(path)
      if ws == nil then
        return
      end

      -- (1) Render this buffer.  Two cases:
      --   • Active render exists → rerender_buffer (preserves fold state +
      --     handles block lifecycle).
      --   • No state yet but the buffer now contains a ```tasks block →
      --     render_buffer (initial draw).  Covers the case where the user
      --     wrote a new note that includes a query block: BufReadPost fired
      --     when the file didn't exist yet, so there was nothing to render
      --     at read time.
      -- Ordered first so a broken index call below cannot block the visible refresh.
      if render._buffer_state[bufnr] ~= nil then
        render.rerender_buffer(bufnr, ws)
      elseif opts.auto_render and render.has_tasks_block(bufnr) then
        render.render_buffer(bufnr, ws)
      end

      -- (2) Refresh the index entry for the written file, then propagate
      -- the change to any other buffers whose renders reference this file,
      -- and refresh source-row diagnostics for this buffer.
      -- Wrapped in pcall so a misbehaving adapter (or files that fail to
      -- read mid-flush) never breaks the autocmd chain.
      pcall(function()
        local index = require("obsidian-tasks.index")
        index.invalidate(path) -- bypass mtime no-op: nvim writes may share a second
        index.refresh_file(path)
        -- Source-row diagnostics for the just-written buffer.
        render.refresh_source_diagnostics(bufnr, path)
        for _, other_bufnr in ipairs(index.reverse_index(path)) do
          if other_bufnr ~= bufnr and vim.api.nvim_buf_is_valid(other_bufnr) then
            -- rerender_buffer preserves cursor + fold state for *visible*
            -- buffers via win_findbuf-based save/restore.  Hidden buffers we
            -- intentionally skip: clear+render on a buffer with no window in
            -- scope mutates the buffer's stored cursor (it gets carried by
            -- line removals during clear and never properly restored), so
            -- when the user later switches back, neovim restores them to a
            -- fold line instead of where they were.
            --
            -- The index has already been refreshed for `path` above, so the
            -- next time the user enters the buffer they can `<leader>tr` to
            -- pick up the fresh data without losing their cursor position.
            if #vim.fn.win_findbuf(other_bufnr) > 0 then
              render.rerender_buffer(other_bufnr, ws)
            end
          end
        end
      end)
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
      -- clear_buffer intentionally preserves linger state (it's called inside
      -- render_buffer/rerender_buffer, where lingers must survive); BufDelete
      -- is a hard buffer-lifecycle boundary, so drop them explicitly.
      render._lingers[bufnr] = nil
      render._pending_lingers[bufnr] = nil
      -- Drop the per-dashboard undo/redo history too.
      local ok, cmd = pcall(require, "obsidian-tasks.cmd")
      if ok and type(cmd.clear_dashboard_undo) == "function" then
        cmd.clear_dashboard_undo(bufnr)
      end
      -- Drop any lingering invalid-field diagnostics.
      if render._diag_ns then
        pcall(vim.diagnostic.reset, render._diag_ns, bufnr)
      end
      if render._source_diag_ns then
        pcall(vim.diagnostic.reset, render._source_diag_ns, bufnr)
      end
      require("obsidian-tasks.render.hygiene")._cleanup(bufnr)
    end,
  })
end

return M
