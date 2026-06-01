-- lua/obsidian-tasks/index/scan.lua
-- Async vault walk.
--
-- ripgrep is used for DISCOVERY ONLY: `util/obsidian.discover_files_async`
-- (`rg --files-with-matches`) returns the set of note files that contain at
-- least one task/heading line.  Each discovered file is then FULL-READ by the
-- unified node parser (index/nodes.lua) — there is no longer any inline parsing
-- of rg output.  rg's default skipping of hidden dirs (`.obsidian/`) and
-- gitignored files is preserved; the file-size guard and per-file ignore check
-- run before the full read.

local M = {}

-- Discovery pattern: a file is task-bearing if it has any task line (optional
-- indent + list marker + checkbox).  Headings alone do NOT qualify a file —
-- a note with headings but no tasks contributes nothing to the index, so we
-- need not full-read it.  (The full-read parser still uses headings it finds to
-- attach `task.heading`; discovery just decides WHICH files to read.)
--
-- This MUST stay aligned with task/parse.lua's PREFIX_PAT, which makes the space
-- after the `]` OPTIONAL (`%[(.)%] ?(.*)`).  A required trailing space here would
-- silently drop a file whose only task is `- [ ]nospace` — discovered by neither
-- but parsed fine.  So discovery ends at the closing `]`, matching the parser.
-- (tests/unit/test_nodes.lua pins discovery-vs-parse prefix equivalence.)
local DISCOVERY_PATTERN = "^\\s*[-*+] \\[.\\]"

--- Walk every task-bearing file in *workspace*, full-read each, and invoke
--- *on_file(abs_path, nodes)* once per file with its complete node list.
---
--- Each discovered file is read from disk EXACTLY ONCE: the single line read
--- feeds both the frontmatter-based ignore check and the node parse (no second
--- io.open via ignore.is_ignored -> parse_frontmatter).  Skips ignored files
--- and files exceeding `opts.max_file_bytes` (the size-guarded read returns nil
--- for oversize files, which we skip).  *make_on_task* (optional) builds the
--- per-task hook (global_filter / DateFallback) for a given path; defaults to
--- nil (no hook).
---
--- @param workspace    table   workspace with `.root`
--- @param on_file      fun(abs_path: string, nodes: table[])
--- @param on_exit      fun(code: integer)?
--- @param make_on_task fun(abs_path: string): (fun(task: table): boolean|nil)?
function M.walk_files(workspace, on_file, on_exit, make_on_task)
  local obsidian = require("obsidian-tasks.util.obsidian")
  local nodes_mod = require("obsidian-tasks.index.nodes")
  local ignore = require("obsidian-tasks.index.ignore")
  local opts = require("obsidian-tasks").opts

  local max_bytes = (opts and opts.max_file_bytes) or 1048576

  obsidian.discover_files_async(workspace, DISCOVERY_PATTERN, function(abs_path)
    if type(abs_path) ~= "string" or abs_path == "" then
      return
    end

    -- ── single read ───────────────────────────────────────────────────────────
    -- Read the file once (with the size guard) and derive BOTH the ignore
    -- decision (from frontmatter) and the node list from these same lines.
    local lines = nodes_mod.read_lines(abs_path, max_bytes)
    if lines == nil then
      return -- read error / oversize: skip
    end

    local fm = obsidian.parse_frontmatter_lines(lines)
    if ignore.is_ignored_fm(fm) then
      return
    end

    local on_task = make_on_task and make_on_task(abs_path) or nil
    local nodes = nodes_mod.parse_lines(lines, { on_task = on_task })
    on_file(abs_path, nodes)
  end, function(code)
    if on_exit then
      on_exit(code)
    end
  end)
end

--- Backwards-compatible flat task walk: invoke *cb(task, abs_path, line_num)*
--- for every task node across all discovered files.  Derived from walk_files —
--- the flat task view of the node model.
---
--- @param workspace table   workspace with `.root`
--- @param cb        fun(task: table, abs_path: string, line_number: integer)
--- @param on_exit   fun(code: integer)?
--- @param make_on_task fun(abs_path: string): (fun(task: table): boolean|nil)?
function M.walk(workspace, cb, on_exit, make_on_task)
  M.walk_files(workspace, function(abs_path, nodes)
    for _, n in ipairs(nodes) do
      if n.kind == "task" then
        cb(n.task, abs_path, n.line_num)
      end
    end
  end, on_exit, make_on_task)
end

return M
