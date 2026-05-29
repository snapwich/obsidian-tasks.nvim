-- lua/obsidian-tasks/cmd/quickfix.lua
-- :ObsidianTask quickfix — build a Neovim quickfix list from the rendered task
-- block under the cursor.
--
-- Resolves the rendered region the cursor sits in (managed.region_for_row),
-- collects its LIVE tasks (managed.tasks_in_range), and populates the quickfix
-- list with one entry per task pointing at its source file/row.  Lingering
-- (fading post-action) rows are skipped via meta.linger.  Emits an info notice
-- and leaves the current quickfix list untouched when invoked outside a block
-- or when the block has no live tasks.

local M = {}

local log = require("obsidian-tasks.log")

--- Run the quickfix subcommand.
--- @param _args table   ignored
--- @param range table   { line1, line2 } 1-indexed; uses line1 (falls back to cursor)
function M.run(_args, range)
  local bufnr = vim.api.nvim_get_current_buf()
  local lnum0 = ((range and range.line1) or vim.api.nvim_win_get_cursor(0)[1]) - 1 -- 0-indexed

  local managed = require("obsidian-tasks.render.managed")
  local region = managed.region_for_row(bufnr, lnum0)
  if not region then
    log.info("obsidian-tasks: cursor is not in a rendered task block")
    return
  end

  local metas = managed.tasks_in_range(bufnr, region.range[1], region.range[2])

  local items = {}
  for _, meta in ipairs(metas) do
    if not meta.linger and meta.source_file then
      local text = vim.trim(meta.task_text or meta.rendered_text or "")
      items[#items + 1] = {
        filename = meta.source_file,
        lnum = meta.source_row + 1,
        col = 1,
        text = text,
      }
    end
  end

  if #items == 0 then
    log.info("obsidian-tasks: no tasks in this block")
    return
  end

  vim.fn.setqflist({}, " ", { title = "ObsidianTasks", items = items })

  -- Open the quickfix window without stealing focus from the dashboard.
  -- `botright` forces it full-width at the bottom of the screen rather than
  -- docked under the current window's column (which, with a vertical split
  -- like a file-explorer sidebar open, yields a cramped partial-width window).
  local cur = vim.api.nvim_get_current_win()
  vim.cmd("botright copen")
  if vim.api.nvim_win_is_valid(cur) then
    vim.api.nvim_set_current_win(cur)
  end
end

return M
