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
--     <leader>tg — jump to source (delegates to :ObsidianTask goto)
--     <leader>tD — delete task (vim.fn.confirm, then remove source line)
--     <leader>tr — force re-render all regions in this buffer
--
-- M.detach(bufnr): remove all buffer-local mappings above.
--
-- attach is called from render/draw.lua on first draw for a buffer.
-- detach is called from render/draw.lua clear (full-buffer clear only).
--
-- Note on jumping: we deliberately do NOT override <CR> / gf / gd.  All three
-- are owned by other ecosystems (obsidian.nvim's ftplugin re-registers <CR>
-- after our render; LazyVim/LSP installs gd on LspAttach).  `<leader>tg` is
-- the safe default for jumping; users who want gd/gD can wire it in their
-- own LspAttach with vim.schedule to win the race.

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

--- Read a single source line (0-indexed row).  Disk-only when no buffer is
--- loaded for the file, so we never trigger bufload's swap detection here.
--- @param source_file string
--- @param source_row  integer  0-indexed
--- @return string|nil
local function read_source_line(source_file, source_row)
  local src_bufnr = vim.fn.bufnr(source_file, false)
  if src_bufnr > -1 and vim.api.nvim_buf_is_loaded(src_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(src_bufnr, source_row, source_row + 1, false)
    return lines[1]
  end
  local ok, lines = pcall(vim.fn.readfile, source_file)
  if ok and type(lines) == "table" then
    return lines[source_row + 1]
  end
  return nil
end

--- Resolve the task at the cursor row of *bufnr*.  Two-mode resolution:
---  • Render mode — row carries a managed-NS task extmark.  Drift-check the
---    stored task_text against the live source line; refuse on mismatch with
---    the standard "run <leader>tr" warning.
---  • Source mode — no managed extmark.  Parse the current buffer line
---    directly as a markdown task line.
--- Returns nil → caller should no-op (not a task row, or drift detected).
--- The returned table is shape-compatible with cmd.commit_line.
--- @param bufnr integer
--- @return table|nil  { kind, bufnr, lnum, task, src_path?, src_line? }
local function resolve_at_cursor(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1
  local managed = require("obsidian-tasks.render.managed")
  local meta = managed.task_meta_for_row(bufnr, lnum)
  if meta then
    -- Render-mode: drift-check.
    local current = read_source_line(meta.source_file, meta.source_row)
    if current ~= nil and current ~= meta.task_text then
      log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
      return nil
    end
    local task = require("obsidian-tasks.task.parse").parse(meta.task_text)
    if not task then
      return nil
    end
    return {
      kind = "render",
      bufnr = nil, -- loaded source buffer lookup deferred to commit_line/apply_source_edit
      lnum = meta.source_row,
      task = task,
      src_path = meta.source_file,
      src_line = meta.source_row + 1,
    }
  end
  -- Source-mode: parse the current buffer line.
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  if #lines == 0 then
    log.info("obsidian-tasks: no task on this line")
    return nil
  end
  local task = require("obsidian-tasks.task.parse").parse(lines[1])
  if not task then
    log.info("obsidian-tasks: no task on this line")
    return nil
  end
  return {
    kind = "source",
    bufnr = bufnr,
    lnum = lnum,
    task = task,
  }
end

--- Re-render the dashboard buffer.
---
--- Refreshes the index from disk first so externally-edited source files
--- are picked up.  Without this, rerender just re-queries the stale
--- in-memory index and shows the same pre-edit state.  Wrapped in pcall
--- to be defensive against stubbed index modules in tests.
---
--- @param bufnr integer
local function do_rerender(bufnr)
  local index = require("obsidian-tasks.index")
  if type(index.refresh_all_indexed_sync) == "function" then
    pcall(index.refresh_all_indexed_sync)
  end
  local render = require("obsidian-tasks.render")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ws = safe_workspace(path)
  render.rerender_buffer(bufnr, ws)
end

--- Manual-refresh variant that clears any lingered rows before re-rendering.
--- Used by <leader>tr only; mutation handlers (toggle/edit/priority/etc.)
--- go through do_rerender so newly-completed tasks linger as intended.
--- @param bufnr integer
local function do_refresh(bufnr)
  local index = require("obsidian-tasks.index")
  if type(index.refresh_all_indexed_sync) == "function" then
    pcall(index.refresh_all_indexed_sync)
  end
  local render = require("obsidian-tasks.render")
  local path = vim.api.nvim_buf_get_name(bufnr)
  local ws = safe_workspace(path)
  if type(render.refresh_with_clear_lingers) == "function" then
    render.refresh_with_clear_lingers(bufnr, ws)
  else
    render.rerender_buffer(bufnr, ws)
  end
end

-- ── Jump handler (<leader>tg) ────────────────────────────────────────────────

--- Build the `<leader>tg` jump handler closed over *bufnr*.
--- Delegates to `:ObsidianTask goto` so the keymap and command stay in sync.
--- @param _bufnr integer
--- @return fun()
local function make_jump_handler(_bufnr)
  return function()
    local cursor = vim.api.nvim_win_get_cursor(0)
    require("obsidian-tasks.cmd").dispatch({
      fargs = { "goto" },
      line1 = cursor[1],
      line2 = cursor[1],
    })
  end
end

-- ── Mutation helpers ──────────────────────────────────────────────────────────

--- Run an :ObsidianTask subcommand via dispatch, then rerender.  Persistence
--- is handled inside the subcommand (cmd.commit_line → cmd.apply_source_edit
--- for dashboard rows, or nvim_buf_set_lines for source rows) so no extra
--- writefile is needed here.  Works on both rendered dashboard rows and raw
--- source task lines — dispatch resolves the row via cmd.resolve_task_at,
--- which handles both contexts.
--- @param bufnr integer
--- @param fargs table    e.g. {"toggle"} or {"priority", "cycle"}
local function dispatch_and_refresh(bufnr, fargs)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum = cursor[1] - 1 -- 0-indexed
  require("obsidian-tasks.cmd").dispatch({
    fargs = fargs,
    line1 = lnum + 1,
    line2 = lnum + 1,
  })
  -- do_rerender is a no-op when the buffer has no active dashboard render
  -- (i.e. source-mode invocations); we always call it so dashboard rows
  -- refresh in place.
  do_rerender(bufnr)
end

-- ── Leader keymap handlers ────────────────────────────────────────────────────

--- <leader>tt — toggle done/not-done.  Works on dashboard rows AND source
--- task lines (resolve_at_cursor handles both via cmd.resolve_task_at; the
--- subsequent dispatch re-resolves but that's cheap and keeps cmd as the
--- single mutation choke point).
--- @param bufnr integer
--- @return fun()
local function make_toggle_handler(bufnr)
  return function()
    if not resolve_at_cursor(bufnr) then
      return
    end
    dispatch_and_refresh(bufnr, { "toggle" })
  end
end

--- <leader>te — edit task description via vim.ui.input.
--- @param bufnr integer
--- @return fun()
local function make_edit_desc_handler(bufnr)
  return function()
    local resolved = resolve_at_cursor(bufnr)
    if not resolved or not resolved.task then
      return
    end
    local task = resolved.task
    vim.ui.input({ prompt = "Edit description: ", default = task.description or "" }, function(input)
      if input == nil then
        return
      end -- cancelled
      task.description = input
      local serialize = require("obsidian-tasks.task.serialize")
      local new_line = serialize.serialize(task)
      if require("obsidian-tasks.cmd").commit_line(resolved, { new_line }) then
        do_rerender(bufnr)
      end
    end)
  end
end

--- <leader>tp — cycle priority.
--- @param bufnr integer
--- @return fun()
local function make_cycle_priority_handler(bufnr)
  return function()
    if not resolve_at_cursor(bufnr) then
      return
    end
    dispatch_and_refresh(bufnr, { "priority", "cycle" })
  end
end

--- <leader>td — set/edit due date.
--- @param bufnr integer
--- @return fun()
local function make_due_date_handler(bufnr)
  return function()
    local resolved = resolve_at_cursor(bufnr)
    if not resolved or not resolved.task then
      return
    end
    local default_date = (resolved.task.fields and resolved.task.fields.due) or ""

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
      dispatch_and_refresh(bufnr, { "due", date })
    end)
  end
end

--- <leader>tT — edit tags (comma-separated, replaces all existing tags).
--- @param bufnr integer
--- @return fun()
local function make_edit_tags_handler(bufnr)
  return function()
    local resolved = resolve_at_cursor(bufnr)
    if not resolved or not resolved.task then
      return
    end
    local task = resolved.task
    local current_tags = table.concat(task.tags or {}, ", ")
    vim.ui.input({ prompt = "Tags (comma-separated, e.g. #foo, #bar): ", default = current_tags }, function(input)
      if input == nil then
        return
      end -- cancelled
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
      local serialize = require("obsidian-tasks.task.serialize")
      local new_line = serialize.serialize(task)
      if require("obsidian-tasks.cmd").commit_line(resolved, { new_line }) then
        do_rerender(bufnr)
      end
    end)
  end
end

--- <leader>tD — delete task with confirmation.
--- @param bufnr integer
--- @return fun()
local function make_delete_handler(bufnr)
  return function()
    local resolved = resolve_at_cursor(bufnr)
    if not resolved then
      return
    end
    local text = (resolved.task and resolved.task.raw_line) or "(this task)"
    local choice = vim.fn.confirm("Delete task?\n" .. text, "&Yes\n&No", 2)
    if choice ~= 1 then
      return
    end -- user chose No or dismissed
    -- commit_line({}) → 0 replacement lines = delete the row.
    if require("obsidian-tasks.cmd").commit_line(resolved, {}) then
      do_rerender(bufnr)
    end
  end
end

--- <leader>tr — force re-render all regions in the dashboard buffer AND
--- clear any lingered rows (dimmed completed tasks awaiting verification).
--- @param bufnr integer
--- @return fun()
local function make_refresh_handler(bufnr)
  return function()
    do_refresh(bufnr)
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

-- Leader keymaps that work on any markdown task line — both rendered
-- dashboard rows AND raw source task lines.  Installed on every .md buffer
-- in a workspace via the BufReadPost autocmd (see autocmds.lua), and again
-- on first dashboard draw (idempotent).
local UNIVERSAL_LHS = {
  "<leader>tt",
  "<leader>te",
  "<leader>tp",
  "<leader>td",
  "<leader>tT",
  "<leader>tg",
  "<leader>tD",
}

-- Leader keymaps that only make sense on a rendered dashboard.  Installed
-- only on first draw of a dashboard.
local DASHBOARD_LEADER_LHS = {
  "<leader>tr",
}

-- Non-leader keymaps installed alongside the dashboard leader set: u / <C-r>
-- intercept normal-mode undo/redo so the plugin's per-dashboard undo ring
-- runs before vim's native undo.  Fall back to native undo/redo when the
-- ring is empty.
local UNDO_LHS = { "u", "<C-r>" }

--- Build the u handler closed over *bufnr*.  Tries the plugin undo ring;
--- when empty, falls back to native :undo so prose-edit undo still works.
--- @param bufnr integer
--- @return fun()
local function make_undo_handler(bufnr)
  return function()
    local cmd = require("obsidian-tasks.cmd")
    if cmd.dashboard_undo(bufnr) then
      return
    end
    vim.cmd("undo")
  end
end

--- Build the <C-r> handler.  Mirrors make_undo_handler for redo.
--- @param bufnr integer
--- @return fun()
local function make_redo_handler(bufnr)
  return function()
    local cmd = require("obsidian-tasks.cmd")
    if cmd.dashboard_redo(bufnr) then
      return
    end
    vim.cmd("redo")
  end
end

--- Helper: register a buffer-local normal-mode keymap (silent + noremap).
local function kmap(bufnr, lhs, handler, desc)
  vim.keymap.set("n", lhs, handler, {
    buffer = bufnr,
    noremap = true,
    silent = true,
    desc = "obsidian-tasks: " .. desc,
  })
end

--- Install the universal task-editing keymaps on *bufnr*.  Universal = works
--- on both rendered dashboard rows AND raw source task lines (handlers
--- resolve via the inline resolve_at_cursor — managed extmark first, then
--- source-line parse).
---
--- Idempotent: re-attaching just overwrites with the same closures.
---
--- We deliberately do NOT install a buffer-local <CR> / gf override here.
--- obsidian.nvim's ftplugin re-registers its smart_action <CR> after our
--- render fires, racing our handler and causing intermittent checkbox toggles
--- in place of jumps.  Use <leader>tg for jump-from-anywhere, or place the
--- cursor on the trailing [[wikilink]] and press <CR>.
---
--- @param bufnr integer
function M.attach_universal(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not should_setup_keymaps() then
    return
  end
  kmap(bufnr, "<leader>tt", make_toggle_handler(bufnr), "toggle task done/not-done")
  kmap(bufnr, "<leader>te", make_edit_desc_handler(bufnr), "edit task description")
  kmap(bufnr, "<leader>tp", make_cycle_priority_handler(bufnr), "cycle task priority")
  kmap(bufnr, "<leader>td", make_due_date_handler(bufnr), "set/edit due date")
  kmap(bufnr, "<leader>tT", make_edit_tags_handler(bufnr), "edit task tags")
  kmap(bufnr, "<leader>tg", make_jump_handler(bufnr), "jump to source file at task row")
  kmap(bufnr, "<leader>tD", make_delete_handler(bufnr), "delete task (with confirmation)")
end

--- Install the dashboard-only keymaps on *bufnr*: refresh (<leader>tr) plus
--- the plugin undo/redo overrides (u / <C-r>).  Called from render/draw.lua
--- on first draw — these keymaps are meaningless on plain source buffers.
---
--- @param bufnr integer
function M.attach_dashboard(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not should_setup_keymaps() then
    return
  end
  kmap(bufnr, "<leader>tr", make_refresh_handler(bufnr), "force re-render all regions")
  kmap(bufnr, "u", make_undo_handler(bufnr), "undo dashboard edit (plugin ring → native)")
  kmap(bufnr, "<C-r>", make_redo_handler(bufnr), "redo dashboard edit (plugin ring → native)")
end

--- Attach buffer-local keymaps for a rendered dashboard buffer (universal +
--- dashboard-only).  Called from render/draw.lua on first draw.  Idempotent.
--- @param bufnr integer
function M.attach(bufnr)
  M.attach_universal(bufnr)
  M.attach_dashboard(bufnr)
end

--- Detach buffer-local keymaps from *bufnr*.
--- Safe to call when no mappings exist (no-op).
--- @param bufnr integer
function M.detach(bufnr)
  for _, lhs in ipairs(UNIVERSAL_LHS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  for _, lhs in ipairs(DASHBOARD_LEADER_LHS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  for _, lhs in ipairs(UNDO_LHS) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
end

return M
