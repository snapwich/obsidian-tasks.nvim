-- lua/obsidian-tasks/index/scan.lua
-- Async vault walk: finds task lines via ripgrep-backed search and feeds
-- parsed Task objects to a callback.

local M = {}

--- Walk all task lines in *workspace* and call *cb* for each parsed Task.
---
--- Uses `util/obsidian.search_async` which wraps obsidian.search.search_async
--- (ripgrep-backed, async, non-blocking).
---
--- Match data shape from obsidian.search:
---   { path = { text = "/abs/path.md" }, lines = { text = "line content" },
---     line_number = N, submatches = {...} }
---
--- Files larger than `opts.max_file_bytes` are skipped (checked via
--- `vim.uv.fs_stat` before parsing — not before search, since we can't filter
--- at the ripgrep level easily).
---
--- `global_filter`: when `opts.global_filter` is a non-empty string, only tasks
--- whose `description` contains that string are passed to *cb*.  This check
--- happens after parsing so `task/parse.lua` stays pure.
---
--- @param workspace table   workspace object with `.root`
--- @param cb        fun(task: table, abs_path: string, line_number: integer)
--- @param on_exit   fun(code: integer)?  called when the walk finishes
function M.walk(workspace, cb, on_exit)
  local obsidian = require("obsidian-tasks.util.obsidian")
  local parse = require("obsidian-tasks.task.parse")
  local ignore = require("obsidian-tasks.index.ignore")
  local opts = require("obsidian-tasks").opts

  local max_bytes = (opts and opts.max_file_bytes) or 1048576
  local global_filter = opts and opts.global_filter

  -- Track which paths have been size-checked so we only stat once per file.
  local size_ok = {} -- abs_path → true | false (nil = not checked yet)

  -- Task-line pattern (same logic as TS plugin: optional indent + list marker + checkbox).
  local pattern = "^\\s*[-*+] \\[.\\] "

  obsidian.search_async(workspace, pattern, function(match)
    local abs_path = match.path and match.path.text
    local line_text = match.lines and match.lines.text
    local line_num = match.line_number

    if type(abs_path) ~= "string" or type(line_text) ~= "string" then
      return
    end

    -- ── ignore check ──────────────────────────────────────────────────────
    -- We check ignore lazily per path (not cached here — init.lua caches the
    -- entry entirely via mtime; ignore check is cheap for first access).
    if ignore.is_ignored(abs_path) then
      return
    end

    -- ── size guard ────────────────────────────────────────────────────────
    if size_ok[abs_path] == nil then
      local stat = vim.uv.fs_stat(abs_path)
      size_ok[abs_path] = stat ~= nil and stat.size <= max_bytes
    end
    if not size_ok[abs_path] then
      return
    end

    -- ── parse ─────────────────────────────────────────────────────────────
    local task = parse.parse(line_text)
    if task == nil then
      return
    end

    -- ── global_filter ─────────────────────────────────────────────────────
    if global_filter and global_filter ~= "" then
      if not task.description:find(global_filter, 1, true) then
        return
      end
    end

    cb(task, abs_path, line_num)
  end, function(code)
    if on_exit then
      on_exit(code)
    end
  end)
end

return M
