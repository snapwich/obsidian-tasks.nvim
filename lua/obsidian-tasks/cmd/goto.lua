-- lua/obsidian-tasks/cmd/goto.lua
-- :ObsidianTask goto — jump to the source file of the task at the cursor.
--
-- Only meaningful on rendered task lines (managed.task_meta_for_row).  Emits
-- an info notice and returns without jumping when invoked elsewhere.  Drift
-- (source line differs from recorded task_text) emits an info notice but
-- still jumps — the extmark position is trusted.

local M = {}

local log = require("obsidian-tasks.log")

--- Read a single line (0-indexed row) from a file/buffer.
--- Prefers a loaded buffer; falls back to readfile.
--- @param file_path string
--- @param row       integer  0-indexed
--- @return string|nil
local function read_source_line(file_path, row)
  local src_bufnr = vim.fn.bufnr(file_path, false)
  if src_bufnr > -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(src_bufnr, row, row + 1, false)
    return lines[1]
  end
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if ok and type(lines) == "table" then
    return lines[row + 1]
  end
  return nil
end

--- Run the goto subcommand.
--- @param _args table   ignored
--- @param range table   { line1, line2 } 1-indexed; uses line1
function M.run(_args, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum = (range and range.line1 or 1) - 1 -- 0-indexed

  local managed = require("obsidian-tasks.render.managed")
  local meta = managed.task_meta_for_row(bufnr, lnum)
  if not (meta and meta.source_file) then
    log.info("obsidian-tasks: no rendered task on this line")
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(meta.source_file))

  local current = read_source_line(meta.source_file, meta.source_row)
  if current ~= nil and current ~= meta.task_text then
    log.info("obsidian-tasks: source position may be stale — run <leader>tr to refresh")
  end

  vim.api.nvim_win_set_cursor(0, { meta.source_row + 1, 0 })
end

return M
