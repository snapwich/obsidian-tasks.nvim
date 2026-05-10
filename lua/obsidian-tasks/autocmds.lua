-- lua/obsidian-tasks/autocmds.lua
-- Auto-render wiring: BufReadPost, FocusGained, BufWritePost, BufDelete.
-- F4 edit-through wiring: User:ObsidianNoteWritePre (diff + patch + strip).
-- Called from init.setup() after opts are merged and validated.
--
-- No autocmds are registered unless setup() is called.

local M = {}

-- ── Pending re-render tracking ────────────────────────────────────────────────
-- Populated by User:ObsidianNoteWritePre when a render was stripped and
-- auto_render is enabled.  Consumed by BufWritePost to re-render after write.
-- Reset on each M.setup() call to avoid stale entries across re-registrations.
local _pending_rerender = {} -- [bufnr] = workspace

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

--- Register all render autocmds under the `obsidian_tasks_render` augroup and
--- all edit-through autocmds under the `obsidian_tasks_edit` augroup.
--- Must be called after opts are available (i.e. from init.setup()).
--- Re-calling this clears and re-registers both augroups.
---
--- @param opts table  merged plugin opts (see config.lua)
function M.setup(opts)
  -- Reset pending re-render state on each setup call.
  _pending_rerender = {}

  local group = vim.api.nvim_create_augroup("obsidian_tasks_render", { clear = true })
  local edit_group = vim.api.nvim_create_augroup("obsidian_tasks_edit", { clear = true })

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
              render.refresh_buffer(bufnr, ws)
            end
          end
        end
      end
    end,
  })

  -- ── User:ObsidianNoteWritePre: diff + patch + strip ──────────────────────────
  -- Fires AFTER obsidian.nvim has updated frontmatter, making it the last
  -- buffer mutation before the actual disk write.
  --
  -- For every rendered block in the buffer:
  --   1. Diff current render lines against the draw-time snapshot.
  --   2. Apply patches / deletions / inserts to source files.
  --   3. Strip all render regions so the disk write contains only fences.
  --
  -- If opts.auto_render is enabled, record the buffer for re-render in
  -- BufWritePost once the write completes.
  vim.api.nvim_create_autocmd("User", {
    group = edit_group,
    pattern = "ObsidianNoteWritePre",
    callback = function(ev)
      -- In production, obsidian.nvim fires this event while the note buffer is
      -- current, so ev.buf is the buffer being written.  Tests (and any caller
      -- that wants to target a specific buffer) may pass ev.data.buf instead.
      local bufnr = (type(ev.data) == "table" and type(ev.data.buf) == "number" and ev.data.buf) or ev.buf
      local draw = require("obsidian-tasks.render.draw")
      local edit = require("obsidian-tasks.render.edit")
      local render = require("obsidian-tasks.render")

      -- No active render → nothing to strip.
      local state = draw.render_state(bufnr)
      if state == nil then
        return
      end

      -- Run diff and apply source-file changes for each rendered block.
      -- Pass block.em_map to scope diff to this block only; this prevents
      -- spurious deletions of tasks that belong to other blocks in the buffer.
      -- Block iteration order does not matter: diff reads the render buffer
      -- but writes only to separate source files.
      for _, block in pairs(state) do
        if block.inserted_range ~= nil then
          local result = edit.diff(bufnr, block.inserted_range, block.em_map)
          for _, patch in ipairs(result.patches) do
            edit.apply_patch(patch)
          end
          for _, deletion in ipairs(result.deletions) do
            edit.apply_deletion(deletion)
          end
          for _, ins in ipairs(result.inserts) do
            edit.apply_insert(ins)
          end
        end
      end

      -- Strip all render regions from the buffer and clear state so the
      -- disk write contains only fence lines.
      render.clear_buffer(bufnr)

      -- Schedule re-render for BufWritePost when auto_render is enabled.
      -- Workspace lookup is deferred to here to avoid the pcall overhead
      -- when auto_render is off.
      if opts.auto_render then
        local path = vim.api.nvim_buf_get_name(bufnr)
        local ws = safe_workspace_for_path(path)
        if ws ~= nil then
          _pending_rerender[bufnr] = ws
        end
      end
    end,
  })

  -- ── BufWritePost ────────────────────────────────────────────────────────────
  -- Re-render the saved buffer after a write.
  --
  -- Two paths:
  --   • F4 path: ObsidianNoteWritePre stripped the render; re-render using the
  --     workspace recorded in _pending_rerender (only when auto_render=true).
  --   • F3 path: no strip happened (render was active but unchanged); refresh
  --     using the existing active render state.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = "*.md",
    callback = function(ev)
      local bufnr = ev.buf
      local render = require("obsidian-tasks.render")

      -- F4 path: re-render after ObsidianNoteWritePre strip.
      local pending_ws = _pending_rerender[bufnr]
      if pending_ws then
        _pending_rerender[bufnr] = nil
        render.render_buffer(bufnr, pending_ws)
        return
      end

      -- F3 path: refresh if an active render exists (no strip occurred).
      if render._buffer_state[bufnr] == nil then
        return
      end

      local path = vim.api.nvim_buf_get_name(bufnr)
      local ws = safe_workspace_for_path(path)
      if ws == nil then
        return
      end

      render.refresh_buffer(bufnr, ws)
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
      -- Also clear any pending re-render for this buffer.
      _pending_rerender[bufnr] = nil
    end,
  })
end

return M
