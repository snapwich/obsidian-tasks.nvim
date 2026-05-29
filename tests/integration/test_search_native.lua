-- tests/integration/test_search_native.lua
-- Real-ripgrep test of util/obsidian.search_async over a temp vault.
-- Requires `rg` on PATH (a hard plugin requirement). Drives the async streaming
-- path end-to-end and asserts the MatchData shape + per-file line ordering that
-- index/scan.lua relies on.

local T = MiniTest.new_set()

-- Same pattern index/scan.lua uses: task lines (optional indent + marker +
-- checkbox) AND ATX headings.
local PATTERN = "^(\\s*[-*+] \\[.\\] |#{1,6} )"

--- Build a temp vault with a `.obsidian/` marker and the given files.
--- @param files table<string, string>  relative path → contents
--- @return string root
local function make_vault(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.obsidian", "p")
  for rel, contents in pairs(files) do
    local abs = root .. "/" .. rel
    vim.fn.mkdir(vim.fn.fnamemodify(abs, ":h"), "p")
    local f = assert(io.open(abs, "w"))
    f:write(contents)
    f:close()
  end
  return root
end

--- Run the adapter's search synchronously (via vim.wait) and return matches+code.
local function run_search(root)
  local adapter = require("obsidian-tasks.util.obsidian")
  local matches, code, done = {}, nil, false
  adapter.search_async({ root = root }, PATTERN, function(m)
    matches[#matches + 1] = m
  end, function(c)
    code = c
    done = true
  end)
  vim.wait(3000, function()
    return done
  end, 25)
  return matches, code, done
end

--- Filter matches whose path ends with `suffix`, in arrival order.
local function lines_for(matches, suffix)
  local out = {}
  for _, m in ipairs(matches) do
    if m.path.text:sub(-#suffix) == suffix then
      out[#out + 1] = m
    end
  end
  return out
end

T["search emits MatchData for task lines and headings, excludes non-md"] = function()
  local root = make_vault({
    ["a.md"] = "# Heading A\n- [ ] Task one #task\n- [x] Task two\n",
    ["b.md"] = "Some prose\n- [ ] Task three\n",
    ["c.txt"] = "- [ ] Not markdown\n",
  })

  local matches, code, done = run_search(root)
  vim.fn.delete(root, "rf")

  MiniTest.expect.equality(done, true)
  MiniTest.expect.equality(code, 0)

  -- Shape: every match has path.text, lines.text (newline stripped), line_number.
  for _, m in ipairs(matches) do
    MiniTest.expect.equality(type(m.path.text), "string")
    MiniTest.expect.equality(type(m.lines.text), "string")
    MiniTest.expect.equality(m.lines.text:find("\n"), nil)
    MiniTest.expect.equality(type(m.line_number), "number")
  end

  -- No .txt file should appear (rg --type=md).
  for _, m in ipairs(matches) do
    MiniTest.expect.equality(m.path.text:sub(-4) == ".txt", false)
  end

  -- a.md: heading + two task lines, in ascending line order.
  local a = lines_for(matches, "a.md")
  MiniTest.expect.equality(#a, 3)
  MiniTest.expect.equality(a[1].lines.text, "# Heading A")
  MiniTest.expect.equality(a[1].line_number, 1)
  MiniTest.expect.equality(a[2].lines.text, "- [ ] Task one #task")
  MiniTest.expect.equality(a[2].line_number, 2)
  MiniTest.expect.equality(a[3].lines.text, "- [x] Task two")
  MiniTest.expect.equality(a[3].line_number, 3)

  -- b.md: only the one task line (prose excluded by the pattern).
  local b = lines_for(matches, "b.md")
  MiniTest.expect.equality(#b, 1)
  MiniTest.expect.equality(b[1].lines.text, "- [ ] Task three")
  MiniTest.expect.equality(b[1].line_number, 2)
end

T["search over a vault with no matching files exits cleanly with no matches"] = function()
  local root = make_vault({ ["empty.md"] = "Just prose, no tasks.\n" })
  local matches, code, done = run_search(root)
  vim.fn.delete(root, "rf")
  MiniTest.expect.equality(done, true)
  -- rg exits 1 when there are no matches; consumers treat any code as "done".
  MiniTest.expect.equality(#matches, 0)
end

return T
