-- lua/obsidian-tasks/util/rg.lua
-- Pure helpers for driving ripgrep's --json output. No process spawning here so
-- the command-builder and per-line decoder stay unit-testable without `rg`.

local M = {}

--- Build the ripgrep argv for a content search over a vault root.
---
--- Flags mirror obsidian.nvim's search invocation so behavior is unchanged when
--- migrating off it: `--type=md` (plus qmd/base type-adds) restricts to note
--- files, and rg's defaults skip hidden dirs (e.g. `.obsidian/`) and
--- gitignored files.
---
--- @param root    string  absolute vault root
--- @param pattern string  ripgrep regex
--- @return string[]
function M.build_command(root, pattern)
  return {
    "rg",
    "--no-config",
    "--type-add",
    "md:*.qmd",
    "--type-add",
    "md:*.base",
    "--type=md",
    "--json",
    "-e",
    pattern,
    root,
  }
end

--- Decode a single line of `rg --json` NDJSON into the MatchData shape that
--- index/scan.lua consumes, or nil for any non-`match` event / malformed line.
---
--- ripgrep includes the matched line's trailing newline in `data.lines.text`;
--- we strip a trailing `\r?\n` so callers see the bare line. Lines whose text
--- is not valid UTF-8 (rg emits `{ bytes = <base64> }` instead of `{ text }`)
--- are skipped.
---
--- @param line string  one NDJSON line
--- @return table|nil  { path = { text }, lines = { text }, line_number }
function M.decode_line(line)
  if type(line) ~= "string" or line == "" then
    return nil
  end
  local ok, obj = pcall(vim.json.decode, line)
  if not ok or type(obj) ~= "table" or obj.type ~= "match" then
    return nil
  end
  local data = obj.data
  if type(data) ~= "table" then
    return nil
  end
  local path_text = data.path and data.path.text
  local line_text = data.lines and data.lines.text
  if type(path_text) ~= "string" or type(line_text) ~= "string" then
    return nil
  end
  line_text = line_text:gsub("\r?\n$", "")
  return {
    path = { text = path_text },
    lines = { text = line_text },
    line_number = data.line_number,
  }
end

return M
