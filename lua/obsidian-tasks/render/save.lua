-- lua/obsidian-tasks/render/save.lua
-- BufWriteCmd save handler for dashboard buffers.
--
-- Responsibilities:
--   • set_acwrite(bufnr)   — mark a rendered buffer as acwrite (once) and
--                            register a buffer-local BufWriteCmd handler.
--   • on_write_cmd(args)   — write only non-managed lines to disk; never
--                            mutate the buffer; fire BufWritePost manually.
--
-- The "acwrite" buftype tells Neovim that the buffer is written via a
-- BufWriteCmd handler rather than the built-in file I/O.  This lets the
-- plugin intercept :w, compute which rows to skip (rendered task lines
-- tracked by region extmarks), and write only source content.
--
-- Buffer mutation during save is intentionally absent:
--   Old BufWritePre approach: strip rendered lines → write → re-render.
--     Side-effects: flicker, undo pollution, race conditions.
--   New BufWriteCmd approach: read buffer, filter rows, writefile.
--     The buffer is never touched; BufWritePost re-render is delegated to
--     the autocmds.lua handler that already listens for that event.

local M = {}

local managed = require("obsidian-tasks.render.managed")
local log = require("obsidian-tasks.log")

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Drop buffer lines that fall inside any of the managed ranges.
--- Ranges are 0-indexed inclusive; lines are iterated with 1-indexed ipairs.
---
--- @param lines  string[]  raw buffer lines (1-indexed)
--- @param ranges table[]   list of { start_row, end_row } 0-indexed inclusive
--- @return string[]  kept lines in original order
local function filter_out_managed(lines, ranges)
  if #ranges == 0 then
    return lines
  end
  local kept = {}
  for row_1, line in ipairs(lines) do
    local row = row_1 - 1 -- convert to 0-indexed
    local in_managed = false
    for _, range in ipairs(ranges) do
      if row >= range[1] and row <= range[2] then
        in_managed = true
        break
      end
    end
    if not in_managed then
      kept[#kept + 1] = line
    end
  end
  return kept
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Return a sorted list of managed row ranges for *bufnr* from live extmarks.
--- Delegates to managed.all_regions so the positions reflect any buffer edits
--- since the last render.
---
--- @param bufnr integer
--- @return table[]  list of { start_row, end_row } 0-indexed inclusive
function M.compute_managed_ranges(bufnr)
  return managed.all_regions(bufnr)
end

--- Mark *bufnr* as acwrite and register a buffer-local BufWriteCmd handler.
---
--- acwrite buftype: the buffer behaves like a file but all write operations go
--- through BufWriteCmd rather than Neovim's built-in I/O.  This means :w will
--- call our handler which filters out managed (rendered) rows before writing.
---
--- Idempotent: if the buffer is already acwrite the function returns immediately
--- without registering a duplicate handler.
---
--- @param bufnr integer
function M.set_acwrite(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.bo[bufnr].buftype == "acwrite" then
    return -- handler already registered on first draw
  end
  vim.bo[bufnr].buftype = "acwrite"
  -- Register a buffer-local BufWriteCmd so only this specific buffer is
  -- intercepted; unmanaged .md files are not affected.
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    desc = "obsidian-tasks: write only source content (skip rendered task lines)",
    callback = function(ev)
      M.on_write_cmd(ev)
    end,
  })
end

--- BufWriteCmd handler: write only non-managed lines to disk.
---
--- Steps:
---   1. Read current buffer lines.
---   2. Compute managed row ranges from live region extmarks.
---   3. Drop rows inside any managed range (rendered task lines).
---   4. Write the filtered lines to disk via vim.fn.writefile.
---   5. Clear modified flag.
---   6. Fire BufWritePost so LSP/formatters that hook that event still run.
---
--- On write failure: log an error and leave modified = true so the user can
--- retry.  The buffer is never mutated by this handler.
---
--- @param args table  autocmd args: { buf = integer, file = string, ... }
function M.on_write_cmd(args)
  local bufnr = args.buf
  local filepath = args.file

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ranges = M.compute_managed_ranges(bufnr)
  local kept = filter_out_managed(lines, ranges)

  local ok, result = pcall(vim.fn.writefile, kept, filepath)
  if not ok or (type(result) == "number" and result ~= 0) then
    local errmsg = ok and (vim.v.errmsg ~= "" and vim.v.errmsg or "write failed") or tostring(result)
    log.error("Failed to write " .. filepath .. ": " .. errmsg)
    -- Leave modified = true so the user can retry.
    return
  end

  vim.bo[bufnr].modified = false

  -- Fire BufWritePost manually so external plugins (LSP, formatters, the
  -- render refresh in autocmds.lua) that hook BufWritePost still run.
  vim.api.nvim_exec_autocmds("BufWritePost", { buffer = bufnr })
end

return M
