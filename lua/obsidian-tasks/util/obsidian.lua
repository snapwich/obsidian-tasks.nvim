-- lua/obsidian-tasks/util/obsidian.lua
-- Vault adapter. All vault access from the rest of our code goes through here.
--
-- Despite the filename, this no longer depends on obsidian.nvim: vaults are
-- detected by the standard `.obsidian/` marker directory, content is scanned
-- with ripgrep directly (util/rg.lua), and frontmatter is parsed natively
-- (util/frontmatter.lua). obsidian.nvim, if present, is an optional integration
-- handled elsewhere (task/status.lua checkbox bridge) — never required here.

local M = {}

-- ── workspace helpers ─────────────────────────────────────────────────────────

--- Find the vault that owns the given absolute path by walking ancestors for a
--- `.obsidian/` marker directory.  Returns a minimal `{ root, name }` workspace
--- (name = basename of root); every downstream consumer reads only `.root`.
---
--- @param abs_path string
--- @return table|nil  { root, name } or nil when no vault marker is found
function M.workspace_for_path(abs_path)
  if not abs_path or abs_path == "" then
    return nil
  end
  local start = vim.fs.dirname(abs_path)
  if not start or start == "" then
    return nil
  end
  local matches = vim.fs.find(".obsidian", { upward = true, type = "directory", path = start })
  local marker = matches and matches[1]
  if not marker then
    return nil
  end
  local root = vim.fs.dirname(marker)
  return { root = root, name = vim.fn.fnamemodify(root, ":t") }
end

-- ── content search ─────────────────────────────────────────────────────────────

--- Async content search across a vault's Markdown files, backed by ripgrep.
---
--- `on_match` receives MatchData: `{ path = { text }, lines = { text },
--- line_number }` — the exact shape index/scan.lua consumes. Callbacks are
--- dispatched on the main loop (schedule-wrapped) so consumers may touch
--- buffers / fs safely. `on_exit` is called once with ripgrep's exit code.
---
--- ripgrep is a hard requirement; when it is not on PATH we log an error and
--- call `on_exit(127)` rather than silently returning empty results.
---
--- @param workspace table              workspace with `.root`
--- @param pattern   string             ripgrep regex
--- @param on_match  fun(match: table)
--- @param on_exit   fun(code: integer)
function M.search_async(workspace, pattern, on_match, on_exit)
  if vim.fn.executable("rg") == 0 then
    require("obsidian-tasks.log").error(
      "ripgrep (`rg`) not found on PATH — required for vault scanning. See :checkhealth obsidian-tasks."
    )
    if on_exit then
      on_exit(127)
    end
    return
  end

  local rg = require("obsidian-tasks.util.rg")
  local cmd = rg.build_command(tostring(workspace.root), pattern)
  local emit = vim.schedule_wrap(function(match)
    on_match(match)
  end)

  -- ripgrep streams NDJSON; buffer partial lines across stdout chunks.
  local pending = ""
  local function consume(chunk)
    pending = pending .. chunk
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      local line = pending:sub(1, nl - 1)
      pending = pending:sub(nl + 1)
      local match = rg.decode_line(line)
      if match then
        emit(match)
      end
    end
  end

  vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err or not data then
        return
      end
      consume(data)
    end,
  }, function(obj)
    if pending ~= "" then
      local match = rg.decode_line(pending)
      pending = ""
      if match then
        emit(match)
      end
    end
    if on_exit then
      vim.schedule(function()
        on_exit(obj.code)
      end)
    end
  end)
end

--- Async DISCOVERY of note files containing a match for *pattern*, backed by
--- ripgrep's `--files-with-matches`.  `on_path` receives one absolute path per
--- matching file (schedule-wrapped, safe to touch buffers / fs).  `on_exit` is
--- called once with ripgrep's exit code.
---
--- Used by index/scan.lua: rg is discovery-only; the matched files are then
--- full-read by the unified node parser.  ripgrep is a hard requirement; when
--- it is not on PATH we log an error and call `on_exit(127)`.
---
--- @param workspace table              workspace with `.root`
--- @param pattern   string             ripgrep regex
--- @param on_path   fun(path: string)
--- @param on_exit   fun(code: integer)
function M.discover_files_async(workspace, pattern, on_path, on_exit)
  if vim.fn.executable("rg") == 0 then
    require("obsidian-tasks.log").error(
      "ripgrep (`rg`) not found on PATH — required for vault scanning. See :checkhealth obsidian-tasks."
    )
    if on_exit then
      on_exit(127)
    end
    return
  end

  local rg = require("obsidian-tasks.util.rg")
  local cmd = rg.build_files_command(tostring(workspace.root), pattern)
  local emit = vim.schedule_wrap(function(path)
    on_path(path)
  end)

  -- `--files-with-matches` prints one path per line (no JSON); buffer partial
  -- lines across stdout chunks exactly like the JSON streaming path.
  local pending = ""
  local function consume(chunk)
    pending = pending .. chunk
    while true do
      local nl = pending:find("\n", 1, true)
      if not nl then
        break
      end
      local path = pending:sub(1, nl - 1):gsub("\r$", "")
      pending = pending:sub(nl + 1)
      if path ~= "" then
        emit(path)
      end
    end
  end

  vim.system(cmd, {
    text = true,
    stdout = function(err, data)
      if err or not data then
        return
      end
      consume(data)
    end,
  }, function(obj)
    if pending ~= "" then
      local path = pending:gsub("\r?\n$", "")
      pending = ""
      if path ~= "" then
        emit(path)
      end
    end
    if on_exit then
      vim.schedule(function()
        on_exit(obj.code)
      end)
    end
  end)
end

-- ── frontmatter ───────────────────────────────────────────────────────────────

--- Parse the YAML frontmatter from an already-read list of file *lines*.
--- Slices the leading `---`…`---` region and hands it to the native YAML-lite
--- parser (util/frontmatter).  Pure: does no IO, so a caller that has already
--- read the file (e.g. the single-read indexer path) can derive frontmatter
--- without a second disk read.
---
--- @param lines string[]  the file's lines (line endings stripped)
--- @return table  parsed frontmatter ({} when there is none)
--- @return string[]  errors (always empty here; kept for shape parity)
function M.parse_frontmatter_lines(lines)
  if lines[1] ~= "---" then
    return {}, {}
  end
  local fm_lines = {}
  for i = 2, #lines do
    if lines[i] == "---" then
      break
    end
    fm_lines[#fm_lines + 1] = lines[i]
  end

  return require("obsidian-tasks.util.frontmatter").parse(fm_lines)
end

--- Parse the YAML frontmatter of the file at *path*.
--- Reads the file, slices the `---`…`---` region, and hands it to the native
--- YAML-lite parser (util/frontmatter).
---
--- @param path string  absolute path to the file
--- @return table|nil  parsed frontmatter, or nil on read error
--- @return string[]   errors (empty on success / no frontmatter; one entry on read error)
function M.parse_frontmatter(path)
  local lines = {}
  local ok, err_msg = pcall(function()
    local f = io.open(path, "r")
    if not f then
      error("cannot open file: " .. tostring(path))
    end
    for line in f:lines() do
      lines[#lines + 1] = line
    end
    f:close()
  end)
  if not ok then
    return nil, { err_msg }
  end

  return M.parse_frontmatter_lines(lines)
end

-- ── workspace path filter ────────────────────────────────────────────────────

--- Build a path_filter predicate scoped to a workspace root.
--- Handles Path objects (tostring) and ensures a trailing slash so
--- "/vault" does not match "/vault-other/file.md".
--- @param workspace_root string|table  workspace.root (Path object or string)
--- @return fun(abs_path: string): boolean
function M.workspace_path_filter(workspace_root)
  local root = tostring(workspace_root)
  if root:sub(-1) ~= "/" then
    root = root .. "/"
  end
  return function(abs_path)
    return abs_path:find(root, 1, true) == 1
  end
end

return M
