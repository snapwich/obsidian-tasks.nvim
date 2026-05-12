-- lua/obsidian-tasks/cmd/init.lua
-- :ObsidianTask <subcmd> dispatcher with range support and tab completion.
--
-- Public surface:
--   M.setup()                  — register :ObsidianTask user command
--   M.dispatch(opts)           — dispatch an opts table (testable entry point)
--   M.resolve_task_at(bufnr, lnum) — resolve task at 0-indexed lnum
--   M.bulk_range(bufnr, range) — walk range, return list of resolved tasks
--
-- Resolver for render lines (T7):
--   Uses managed.task_meta_for_row to identify rendered task lines.
--   Performs drift detection: if the source file line no longer matches
--   meta.task_text, the operation is refused with a notification.
--   Returns source buffer bufnr/lnum so subcommands write directly to source.

local M = {}

local log = require("obsidian-tasks.log")

-- ── Valid subcommands ─────────────────────────────────────────────────────────

local VALID_SUBCMDS = {
  "toggle",
  "done",
  "cancel",
  "inProgress",
  "onHold",
  "due",
  "scheduled",
  "start",
  "priority",
  "recurrence",
  "tags",
  "edit",
  "refresh",
  "render",
  "new",
  "goto",
}

local VALID_SUBCMDS_SET = {}
for _, v in ipairs(VALID_SUBCMDS) do
  VALID_SUBCMDS_SET[v] = true
end

-- ── Resolver helpers ─────────────────────────────────────────────────────────

--- Read a single line (0-indexed row) from a source file.
--- Prefers a loaded buffer; falls back to readfile for unloaded files.
--- Returns nil if the file cannot be read or the row is out of range.
---
--- @param file_path  string
--- @param row        integer  0-indexed
--- @return string|nil
local function read_source_line(file_path, row)
  local src_bufnr = vim.fn.bufnr(file_path, false)
  if src_bufnr > -1 and vim.api.nvim_buf_is_valid(src_bufnr) then
    local lines = vim.api.nvim_buf_get_lines(src_bufnr, row, row + 1, false)
    return lines[1]
  end
  local ok, lines = pcall(vim.fn.readfile, file_path)
  if ok and type(lines) == "table" then
    return lines[row + 1] -- readfile is 1-indexed
  end
  return nil
end

--- Get or load the source buffer for *file_path*.
--- Returns an already-loaded bufnr, or bufadd+bufload a new one.
---
--- @param file_path string
--- @return integer  bufnr
local function get_or_load_buf(file_path)
  local src_bufnr = vim.fn.bufnr(file_path, false)
  if src_bufnr == -1 then
    src_bufnr = vim.fn.bufadd(file_path)
    vim.fn.bufload(src_bufnr)
  end
  return src_bufnr
end

-- Expose the internal helpers so other modules (notably render/revert.lua's
-- status-edit commit pass) can perform drift checks + source buffer loads
-- without going through resolve_task_at, which depends on live extmarks.
M._read_source_line = read_source_line
M._get_or_load_buf = get_or_load_buf

-- ── Resolver ──────────────────────────────────────────────────────────────────

--- Resolve the task at a specific buffer position.
---
--- For rendered task lines: uses managed.task_meta_for_row to look up the
--- extmark side table.  Performs drift detection — if the source file line
--- no longer matches meta.task_text (external edit), the operation is refused
--- and nil is returned with a log.warn notification so the user knows to run
--- <leader>tr.  When no drift is detected the source buffer is opened and the
--- returned record points at the SOURCE buffer (bufnr, lnum = source_row) so
--- that subcommands write directly to the source without touching the render
--- buffer.
---
--- For source-buffer lines: parses the raw buffer line as a task.
---
--- @param bufnr integer  buffer number (render or source)
--- @param lnum  integer  0-indexed buffer line number
--- @return table|nil
---   Render task:  { kind='render', bufnr=src_bufnr, lnum=src_row, task, src_path, src_line }
---   Source task:  { kind='source', bufnr, lnum, task }
function M.resolve_task_at(bufnr, lnum)
  -- Check managed task-meta first (render lines).
  local managed = require("obsidian-tasks.render.managed")
  local meta = managed.task_meta_for_row(bufnr, lnum)
  if meta then
    -- Drift check: compare current source line against the recorded task_text.
    local current_line = read_source_line(meta.source_file, meta.source_row)
    if current_line == nil then
      log.warn("obsidian-tasks: cannot read source file — run <leader>tr to refresh")
      return nil
    end
    if current_line ~= meta.task_text then
      log.warn("obsidian-tasks: source drift detected — run <leader>tr to refresh")
      return nil
    end

    -- Open (or reuse) the source buffer so subcommands can write directly.
    local src_bufnr = get_or_load_buf(meta.source_file)

    -- Parse the task from the clean source-file text (no wikilink suffix).
    local task = require("obsidian-tasks.task.parse").parse(meta.task_text)

    return {
      kind = "render",
      bufnr = src_bufnr,
      lnum = meta.source_row, -- 0-indexed source row
      task = task,
      src_path = meta.source_file,
      src_line = meta.source_row + 1, -- 1-indexed for cursor placement
    }
  end

  -- Fall back to parsing the raw buffer line (source-buffer mode).
  local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
  if #lines == 0 then
    return nil
  end
  local task = require("obsidian-tasks.task.parse").parse(lines[1])
  if not task then
    return nil
  end

  return {
    kind = "source",
    bufnr = bufnr,
    lnum = lnum,
    task = task,
  }
end

-- ── Bulk-range helper ─────────────────────────────────────────────────────────

--- Walk a line range and return all resolved tasks.
--- Non-task lines are silently skipped.
---
--- @param bufnr integer   buffer number
--- @param range table     { line1: integer, line2: integer }  1-indexed (from opts)
--- @return table[]        list of resolve_task_at results
function M.bulk_range(bufnr, range)
  local results = {}
  -- line1/line2 are 1-indexed; resolve_task_at expects 0-indexed.
  for lnum = range.line1 - 1, range.line2 - 1 do
    local resolved = M.resolve_task_at(bufnr, lnum)
    if resolved then
      results[#results + 1] = resolved
    end
  end
  return results
end

-- ── Dispatcher ────────────────────────────────────────────────────────────────

--- Dispatch a :ObsidianTask invocation.
---
--- `opts` matches the shape that nvim_create_user_command callbacks receive:
---   opts.fargs  — split argument list (first element is the subcmd name)
---   opts.line1  — first line of range (1-indexed)
---   opts.line2  — last line of range (1-indexed)
---
--- @param opts table
function M.dispatch(opts)
  local subcmd = opts.fargs and opts.fargs[1]
  if not subcmd or subcmd == "" then
    log.error("ObsidianTask: missing subcommand. Valid: " .. table.concat(VALID_SUBCMDS, " "))
    return
  end

  if not VALID_SUBCMDS_SET[subcmd] then
    log.error("ObsidianTask: unknown subcommand '" .. subcmd .. "'. Valid: " .. table.concat(VALID_SUBCMDS, " "))
    return
  end

  -- Lazy-load the subcommand module.
  local ok, mod = pcall(require, "obsidian-tasks.cmd." .. subcmd)
  if not ok or type(mod.run) ~= "function" then
    log.error("ObsidianTask: subcommand '" .. subcmd .. "' is not yet implemented")
    return
  end

  -- Remaining fargs (after the subcmd name) are passed as args.
  local args = {}
  for i = 2, #(opts.fargs or {}) do
    args[#args + 1] = opts.fargs[i]
  end

  local range = { line1 = opts.line1, line2 = opts.line2 }
  mod.run(args, range)
end

-- ── Completion ────────────────────────────────────────────────────────────────

--- Tab-completion for :ObsidianTask.
---
--- Top-level: completes subcmd names.
--- Second-level: delegates to subcmd module's M.complete(arg_lead, cmdline, cursorpos)
--- if defined.
---
--- @param arg_lead  string  current word being completed
--- @param cmdline   string  full command line so far
--- @param cursorpos integer cursor position in the command line
--- @return string[]
local function completion(arg_lead, cmdline, cursorpos)
  -- Extract the portion of the cmdline after the command name.
  local after_cmd = cmdline:match("^%S+%s+(.*)") or ""
  -- Count tokens that appear BEFORE the current arg_lead.
  local prefix = after_cmd:sub(1, #after_cmd - #arg_lead)
  local pre = vim.trim(prefix)

  if pre == "" then
    -- Completing the subcmd name itself.
    local matches = {}
    for _, name in ipairs(VALID_SUBCMDS) do
      if vim.startswith(name, arg_lead) then
        matches[#matches + 1] = name
      end
    end
    return matches
  end

  -- Delegate to subcmd's M.complete if available.
  local subcmd = pre:match("^%S+")
  if subcmd and VALID_SUBCMDS_SET[subcmd] then
    local ok, mod = pcall(require, "obsidian-tasks.cmd." .. subcmd)
    if ok and type(mod.complete) == "function" then
      return mod.complete(arg_lead, cmdline, cursorpos)
    end
  end
  return {}
end

-- Export for unit testing (prefixed _ to mark as internal).
M._completion = completion

-- ── Setup ─────────────────────────────────────────────────────────────────────

--- Register the :ObsidianTask user command.
--- Called from obsidian-tasks.init.setup().
--- Replaces any previously registered :ObsidianTask command (including the
--- plugin/ stub from F1).
function M.setup()
  -- Remove the stub registered by plugin/obsidian-tasks.lua, if still present.
  pcall(vim.api.nvim_del_user_command, "ObsidianTask")

  vim.api.nvim_create_user_command("ObsidianTask", M.dispatch, {
    nargs = "*",
    range = true,
    complete = completion,
    desc = "ObsidianTask: run a task subcommand (toggle, done, cancel, …)",
  })
end

return M
