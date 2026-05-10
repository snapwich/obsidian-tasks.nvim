-- lua/obsidian-tasks/cmd/init.lua
-- :ObsidianTask <subcmd> dispatcher with range support and tab completion.
--
-- Public surface:
--   M.setup()                  — register :ObsidianTask user command
--   M.dispatch(opts)           — dispatch an opts table (testable entry point)
--   M.resolve_task_at(bufnr, lnum) — resolve task at 0-indexed lnum
--   M.bulk_range(bufnr, range) — walk range, return list of resolved tasks

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
}

local VALID_SUBCMDS_SET = {}
for _, v in ipairs(VALID_SUBCMDS) do
  VALID_SUBCMDS_SET[v] = true
end

-- ── Resolver helpers ─────────────────────────────────────────────────────────

--- Strip the trailing ' [[basename]]' wikilink that layout.lua appends to
--- render-buffer task lines when task._src_path is set.
---
--- Only strips when the literal suffix matches; returns the original string
--- otherwise (e.g. when hide.backlinks is true and no wikilink was added).
---
--- @param line     string  raw render-buffer task line
--- @param src_path string  absolute path of the task's source file
--- @return string  line with wikilink suffix removed, or original if no match
function M._strip_render_wikilink(line, src_path)
  local basename = vim.fn.fnamemodify(src_path, ":t:r")
  local suffix = " [[" .. basename .. "]]"
  if #line >= #suffix and line:sub(-#suffix) == suffix then
    return line:sub(1, -(#suffix + 1))
  end
  return line
end

-- ── Resolver ──────────────────────────────────────────────────────────────────

--- Resolve the task at a specific buffer position.
---
--- Checks render lines first (draw.is_render_line); falls back to parsing the
--- raw buffer line as a task.
---
--- For render lines the wikilink suffix appended by layout.lua is stripped
--- before parsing.  The returned record carries src_path and src_line so that
--- subcommands can locate the source file.  The hash fields (src_hash,
--- source_text_hash) are intentionally omitted — they were consumed by the F4
--- edit-through path which has been removed.  T7 will replace this resolver
--- with a managed.task_meta_for_row-based implementation.
---
--- NOTE: cmd subcommands are currently non-functional on rendered task lines
--- (render kind='render' is returned but subcommands cannot write back without
--- T7's resolver).  They continue to work on source buffers (kind='source').
---
--- @param bufnr integer  buffer number
--- @param lnum  integer  0-indexed buffer line number
--- @return table|nil
---   Render task:  { kind='render', bufnr, lnum, task, src_path, src_line }
---   Source task:  { kind='source', bufnr, lnum, task }
function M.resolve_task_at(bufnr, lnum)
  -- Check render layer first.
  local draw = require("obsidian-tasks.render.draw")
  local info = draw.is_render_line(bufnr, lnum)
  if info then
    -- Parse the render-buffer line after stripping the wikilink suffix so the
    -- parsed task is clean.
    local render_lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
    local task = nil
    if #render_lines > 0 then
      local source_line = render_lines[1]
      if info.src_path then
        source_line = M._strip_render_wikilink(source_line, info.src_path)
      end
      task = require("obsidian-tasks.task.parse").parse(source_line)
    end
    return {
      kind = "render",
      bufnr = bufnr,
      lnum = lnum,
      task = task,
      src_path = info.src_path,
      src_line = info.src_line,
    }
  end

  -- Fall back to parsing the raw buffer line.
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
