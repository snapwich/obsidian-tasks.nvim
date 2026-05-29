-- tests/unit/test_rg.lua
-- Unit tests for util/rg.lua: the pure ripgrep command-builder + NDJSON decode.
-- No process is spawned; we feed decode_line synthetic `rg --json` lines.

local T = MiniTest.new_set()

local rg = require("obsidian-tasks.util.rg")

--- Index of `needle` in list `t`, or nil.
local function index_of(t, needle)
  for i, v in ipairs(t) do
    if v == needle then
      return i
    end
  end
  return nil
end

-- ── build_command ────────────────────────────────────────────────────────────

T["build_command: starts with rg and requests json"] = function()
  local cmd = rg.build_command("/vault", "PATTERN")
  MiniTest.expect.equality(cmd[1], "rg")
  MiniTest.expect.equality(index_of(cmd, "--json") ~= nil, true)
end

T["build_command: restricts to markdown note types"] = function()
  local cmd = rg.build_command("/vault", "PATTERN")
  MiniTest.expect.equality(index_of(cmd, "--type=md") ~= nil, true)
end

T["build_command: pattern follows -e, root is last arg"] = function()
  local cmd = rg.build_command("/my/vault", "^- %[.%]")
  local e = index_of(cmd, "-e")
  MiniTest.expect.equality(e ~= nil, true)
  MiniTest.expect.equality(cmd[e + 1], "^- %[.%]")
  MiniTest.expect.equality(cmd[#cmd], "/my/vault")
end

-- ── decode_line: match events ──────────────────────────────────────────────────

--- Encode a synthetic `rg --json` match object the way ripgrep would.
local function match_line(path, text, line_number)
  return vim.json.encode({
    type = "match",
    data = {
      path = { text = path },
      lines = { text = text },
      line_number = line_number,
      absolute_offset = 0,
      submatches = {},
    },
  })
end

T["decode_line: returns MatchData shape for a match event"] = function()
  local m = rg.decode_line(match_line("/vault/note.md", "- [ ] Task #task\n", 7))
  MiniTest.expect.equality(type(m), "table")
  MiniTest.expect.equality(m.path.text, "/vault/note.md")
  MiniTest.expect.equality(m.lines.text, "- [ ] Task #task")
  MiniTest.expect.equality(m.line_number, 7)
end

T["decode_line: strips trailing CRLF as well as LF"] = function()
  local m = rg.decode_line(match_line("/vault/n.md", "- [ ] Win line\r\n", 1))
  MiniTest.expect.equality(m.lines.text, "- [ ] Win line")
end

T["decode_line: keeps internal whitespace, only trims trailing newline"] = function()
  local m = rg.decode_line(match_line("/vault/n.md", "  - [ ] Indented\n", 2))
  MiniTest.expect.equality(m.lines.text, "  - [ ] Indented")
end

-- ── decode_line: non-match / malformed ─────────────────────────────────────────

T["decode_line: nil for begin/end/summary events"] = function()
  local begin = vim.json.encode({ type = "begin", data = { path = { text = "/v/n.md" } } })
  local summary = vim.json.encode({ type = "summary", data = {} })
  MiniTest.expect.equality(rg.decode_line(begin), nil)
  MiniTest.expect.equality(rg.decode_line(summary), nil)
end

T["decode_line: nil for malformed json"] = function()
  MiniTest.expect.equality(rg.decode_line("{not json"), nil)
  MiniTest.expect.equality(rg.decode_line(""), nil)
  MiniTest.expect.equality(rg.decode_line(nil), nil)
end

T["decode_line: nil when line text is non-utf8 (bytes, no text)"] = function()
  local bytes = vim.json.encode({
    type = "match",
    data = {
      path = { text = "/v/n.md" },
      lines = { bytes = "AQID" },
      line_number = 3,
    },
  })
  MiniTest.expect.equality(rg.decode_line(bytes), nil)
end

return T
