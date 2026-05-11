-- lua/obsidian-tasks/render/keymap.lua
-- Buffer-local keymaps for rendered dashboard buffers.
--
-- M.attach(bufnr): install buffer-local normal-mode mappings.
--   Installed when setup_keymaps = true (default):
--     <leader>tt — toggle task done/not-done
--     <leader>te — edit task description (vim.ui.input prompt)
--     <leader>tp — cycle priority: none → highest → high → medium → low → lowest → none
--     <leader>td — set due date (vim.ui.input prompt for YYYY-MM-DD)
--     <leader>tT — edit tags (vim.ui.input, comma-separated)
--     <leader>tg — jump to source (from anywhere on a rendered task row)
--     <leader>tD — delete task (vim.fn.confirm, then remove source line)
--     <leader>tr — force re-render all regions in this buffer
--
-- M.detach(bufnr): remove all buffer-local mappings above.
--
-- attach is called from render/draw.lua on first draw for a buffer.
-- detach is called from render/draw.lua clear (full-buffer clear only).
--
-- Note on jumping with <CR>: we deliberately do NOT override <CR> / gf.  In
-- early F9 prototypes we did, but obsidian.nvim's ftplugin re-registers its
-- own smart_action <CR> after our render fires, racing our handler.  Instead,
-- press <CR> with the cursor on the trailing `[[wikilink]]` of a rendered row
-- (obsidian.nvim's smart_action follows the link) or use <leader>tg to jump
-- from anywhere on the row.

local M = {}

local log = require("obsidian-tasks.log")

-- ── Internal helpers ──────────────────────────────────────────────────────────

--- Resolve workspace for a buffer path (nil on any error).
--- @param path string
--- @return table|nil
local function safe_workspace(path)
  local ok, result = pcall(function()
    return require("obsidian-tasks.util.obsidian").workspace_for_path(path)
  end)
  return ok and result or nil
end

--- Read a single source line (0-indexed row).
--- Prefers loaded buffer; falls back to readfile.
--- @param source_file string
--- @param source_row  integer  0-indexed
--- @return string|nil
local function read_source_line(source_file, source_row)
  local src_bufnr = vim.fn.bufnr(source_file, false)
  if src_bufnr > -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(src_bufnr, source_row, source_row + 1, false)
    return lines[1]
  end
  local ok, lines = pcall(vim.fn.readfile, source_file)
  if ok and type(lines) == "table" then
    return lines[source_row + 1]
  end
  return nil
end

--- Get or load source buffer (prefer already-loaded).
--- @param source_file string
--- @return integer  bufnr
local function get_or_load_buf(source_file)
  local src_bufnr = vim.fn.bufnr(source_file, false)
  if src_bufnr == -1 then
    src_bufnr = vim.fn.bufadd(source_file)
    vim.fn.bufload(src_bufnr)
  end
  return src_bufnr
end

--- Check for source drift: if current source line ≠ meta.task_text, warn and
--- return false.  Always returns true when drift cannot be determined (file
--- temporarily unreadable) — the subsequent operation will fail naturally.
--- @param meta table  { source_file, source_row, task_text }
--- @return boolean  true = no drift (safe to mutate)
local function no_drift(meta)
  local current = read_source_line(meta.source_file, meta.source_row)
  if current == nil then
    -- Cannot verify — emit info and proceed (fail-safe).
    log.info("obsidian-tasks: source file temporarily unreadable — run <leader>tr if stale")
    return true
  end
  if current ~= meta.task_text then
    log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
    return false
  end
  return true
end

--- Write source buffer to disk and refresh the task index.
--- @param source_file string
local function persist_source(source_file)
  local src_bufnr = vim.fn.bufnr(source_file, false)
  if src_bufnr > -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(src_bufnr, 0, -1, false)
    vim.fn.writefile(lines, source_file)
    vim.bo[src_bufnr].modified = false
  end
  -- Update the task index so re-render reflects the mutation.
  require("obsidian-tasks.index").refresh_file(source_file)
end

--- Re-render the dashboard buffer.
--- @param bufnr integer
local function do_rerender(bufnr)
  local render = require("obsidian-tasks.render")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ws = safe_workspace(path)
  render.rerender_buffer(bufnr, ws)
end

-- ── Jump handler (<leader>tg) ────────────────────────────────────────────────

--- Build the <leader>tg jump handler closed over *bufnr*.
--- Uses managed.task_meta_for_row — trusts the extmark position.
--- For stale positions the user runs <leader>tr to refresh.
--- Emits an info notice when invoked on a row without task_meta (i.e. not a
--- rendered task line) and stays put — no fall-through to obsidian's
--- smart_action, since the user explicitly chose <leader>tg.
--- @param bufnr integer
--- @return fun()
local function make_jump_handler(bufnr)
  return function()
    local managed = require("obsidian-tasks.render.managed")
    local cursor = vim.api.nvim_win_get_cursor(0)
    local lnum = cursor[1] - 1 -- 0-indexed

    local meta = managed.task_meta_for_row(bufnr, lnum)
    if not (meta and meta.source_file) then
      log.info("obsidian-tasks: no rendered task on this line")
      return
    end

    -- Jump to source.  :edit preserves unsaved changes if already loaded.
    vim.cmd("edit " .. vim.fn.fnameescape(meta.source_file))
    -- source_row is 0-indexed; nvim_win_set_cursor expects 1-indexed.
    local target_row = meta.source_row + 1

    -- Drift notification only (still jump — extmark is trusted).
    local current = read_source_line(meta.source_file, meta.source_row)
    if current ~= nil and current ~= meta.task_text then
      log.info("obsidian-tasks: source position may be stale — run <leader>tr to refresh")
    end

    vim.api.nvim_win_set_cursor(0, { target_row, 0 })
  end
end

-- ── Mutation helpers ──────────────────────────────────────────────────────────

--- Get meta for cursor row; emit "no task" notice and return nil if absent.
--- @param bufnr integer
--- @return table|nil  meta or nil
local function get_meta_at_cursor(bufnr)
  local managed = require("obsidian-tasks.render.managed")
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1
  local meta = managed.task_meta_for_row(bufnr, lnum)
  if not meta then
    log.info("obsidian-tasks: no task on this line")
    return nil
  end
  return meta
end

--- Run an :ObsidianTask subcommand via dispatch, then persist+rerender.
--- The cursor must be positioned on the rendered task line before calling.
--- @param bufnr   integer  dashboard buffer
--- @param fargs   table    e.g. {"toggle"} or {"priority", "cycle"}
--- @param source_file string  path used for persist_source
local function dispatch_and_refresh(bufnr, fargs, source_file)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1 -- 0-indexed
  require("obsidian-tasks.cmd").dispatch({
    fargs = fargs,
    line1 = lnum + 1,
    line2 = lnum + 1,
  })
  persist_source(source_file)
  do_rerender(bufnr)
end

-- ── Leader keymap handlers ────────────────────────────────────────────────────

--- <leader>tt — toggle done/not-done.
--- @param bufnr integer
--- @return fun()
local function make_toggle_handler(bufnr)
  return function()
    local meta = get_meta_at_cursor(bufnr)
    if not meta then
      return
    end
    if not no_drift(meta) then
      return
    end
    dispatch_and_refresh(bufnr, { "toggle" }, meta.source_file)
  end
end

--- <leader>te — edit task description via vim.ui.input.
--- @param bufnr integer
--- @return fun()
local function make_edit_desc_handler(bufnr)
  return function()
    local meta = get_meta_at_cursor(bufnr)
    if not meta then
      return
    end
    if not no_drift(meta) then
      return
    end

    local parse = require("obsidian-tasks.task.parse")
    local serialize = require("obsidian-tasks.task.serialize")
    local task = parse.parse(meta.task_text)
    if not task then
      log.warn("obsidian-tasks: could not parse task")
      return
    end

    vim.ui.input({ prompt = "Edit description: ", default = task.description or "" }, function(input)
      if input == nil then
        return
      end -- cancelled
      task.description = input
      local new_line = serialize.serialize(task)
      local src_bufnr = get_or_load_buf(meta.source_file)
      vim.api.nvim_buf_set_lines(src_bufnr, meta.source_row, meta.source_row + 1, false, { new_line })
      persist_source(meta.source_file)
      do_rerender(bufnr)
    end)
  end
end

--- <leader>tp — cycle priority.
--- @param bufnr integer
--- @return fun()
local function make_cycle_priority_handler(bufnr)
  return function()
    local meta = get_meta_at_cursor(bufnr)
    if not meta then
      return
    end
    if not no_drift(meta) then
      return
    end
    dispatch_and_refresh(bufnr, { "priority", "cycle" }, meta.source_file)
  end
end

--- <leader>td — set/edit due date.
--- @param bufnr integer
--- @return fun()
local function make_due_date_handler(bufnr)
  return function()
    local meta = get_meta_at_cursor(bufnr)
    if not meta then
      return
    end
    if not no_drift(meta) then
      return
    end

    -- Show current due date as default.
    local parse = require("obsidian-tasks.task.parse")
    local task = parse.parse(meta.task_text)
    local default_date = (task and task.fields.due) or ""

    vim.ui.input({ prompt = "Due date (YYYY-MM-DD): ", default = default_date }, function(input)
      if input == nil or input == "" then
        return
      end -- cancelled or empty
      -- Validate / parse via the date_nl parser.
      local date = require("obsidian-tasks.cmp.date_nl").parse(input)
      if not date then
        log.error("obsidian-tasks: invalid date '" .. input .. "' — use YYYY-MM-DD, 'today', or 'tomorrow'")
        return
      end
      dispatch_and_refresh(bufnr, { "due", date }, meta.source_file)
    end)
  end
end

--- <leader>tT — edit tags (comma-separated, replaces all existing tags).
--- @param bufnr integer
--- @return fun()
local function make_edit_tags_handler(bufnr)
  return function()
    local meta = get_meta_at_cursor(bufnr)
    if not meta then
      return
    end
    if not no_drift(meta) then
      return
    end

    local parse = require("obsidian-tasks.task.parse")
    local serialize = require("obsidian-tasks.task.serialize")
    local task = parse.parse(meta.task_text)
    if not task then
      log.warn("obsidian-tasks: could not parse task")
      return
    end

    -- Join existing tags for display.
    local current_tags = table.concat(task.tags or {}, ", ")

    vim.ui.input({ prompt = "Tags (comma-separated, e.g. #foo, #bar): ", default = current_tags }, function(input)
      if input == nil then
        return
      end -- cancelled
      -- Parse new tags: split on commas, trim, prefix '#' when missing.
      local new_tags = {}
      for part in (input .. ","):gmatch("([^,]+),") do
        local trimmed = vim.trim(part)
        if trimmed ~= "" then
          if not trimmed:find("^#") then
            trimmed = "#" .. trimmed
          end
          new_tags[#new_tags + 1] = trimmed
        end
      end
      task.tags = new_tags
      local new_line = serialize.serialize(task)
      local src_bufnr = get_or_load_buf(meta.source_file)
      vim.api.nvim_buf_set_lines(src_bufnr, meta.source_row, meta.source_row + 1, false, { new_line })
      persist_source(meta.source_file)
      do_rerender(bufnr)
    end)
  end
end

--- <leader>tD — delete task with confirmation.
--- @param bufnr integer
--- @return fun()
local function make_delete_handler(bufnr)
  return function()
    local meta = get_meta_at_cursor(bufnr)
    if not meta then
      return
    end
    if not no_drift(meta) then
      return
    end

    local choice = vim.fn.confirm("Delete task?\n" .. meta.task_text, "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end -- user chose No or dismissed

    local src_bufnr = get_or_load_buf(meta.source_file)
    -- Delete the source line (replace with empty list → remove the row).
    vim.api.nvim_buf_set_lines(src_bufnr, meta.source_row, meta.source_row + 1, false, {})
    persist_source(meta.source_file)
    do_rerender(bufnr)
  end
end

--- <leader>tr — force re-render all regions in the dashboard buffer.
--- @param bufnr integer
--- @return fun()
local function make_refresh_handler(bufnr)
  return function()
    do_rerender(bufnr)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Return true when leader keymaps should be installed.
--- Reads opts.setup_keymaps; defaults to true when opts are not yet available.
--- @return boolean
local function should_setup_keymaps()
  local ok, ot = pcall(require, "obsidian-tasks")
  if ok and ot.opts ~= nil then
    -- setup_keymaps defaults to true; only false explicitly disables.
    return ot.opts.setup_keymaps ~= false
  end
  return true -- default: install
end

-- All leader lhs values (for detach).
local LEADER_LHS = {
  "<leader>tt",
  "<leader>te",
  "<leader>tp",
  "<leader>td",
  "<leader>tT",
  "<leader>tg",
  "<leader>tD",
  "<leader>tr",
}

--- Attach buffer-local keymaps to *bufnr*.
--- Safe to call multiple times (idempotent: last definition wins).
--- @param bufnr integer
function M.attach(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  -- ── Leader keymaps (opt-out via setup_keymaps = false) ──────────────────────
  -- We deliberately do NOT install a buffer-local <CR> / gf override here.
  -- obsidian.nvim's ftplugin re-registers its smart_action <CR> after our
  -- render fires, racing our handler and causing intermittent checkbox toggles
  -- in place of jumps.  Use <leader>tg below for jump-from-anywhere, or place
  -- the cursor on the trailing [[wikilink]] and press <CR> — obsidian.nvim's
  -- smart_action will follow it.
  if not should_setup_keymaps() then
    return
  end

  local function kmap(lhs, handler, desc)
    vim.keymap.set("n", lhs, handler, {
      buffer = bufnr,
      noremap = true,
      silent = true,
      desc = "obsidian-tasks: " .. desc,
    })
  end

  kmap("<leader>tt", make_toggle_handler(bufnr), "toggle task done/not-done")
  kmap("<leader>te", make_edit_desc_handler(bufnr), "edit task description")
  kmap("<leader>tp", make_cycle_priority_handler(bufnr), "cycle task priority")
  kmap("<leader>td", make_due_date_handler(bufnr), "set/edit due date")
  kmap("<leader>tT", make_edit_tags_handler(bufnr), "edit task tags")
  kmap("<leader>tg", make_jump_handler(bufnr), "jump to source file at task row")
  kmap("<leader>tD", make_delete_handler(bufnr), "delete task (with confirmation)")
  kmap("<leader>tr", make_refresh_handler(bufnr), "force re-render all regions")
end

--- Detach buffer-local keymaps from *bufnr*.
--- Safe to call when no mappings exist (no-op).
--- @param bufnr integer
function M.detach(bufnr)
  -- Remove leader keymaps (all are no-ops if not installed).
  for _, lhs in ipairs(LEADER_LHS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
end

return M
