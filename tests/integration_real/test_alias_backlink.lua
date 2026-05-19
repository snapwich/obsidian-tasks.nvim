-- tests/integration_real/test_alias_backlink.lua
-- Real-mode coverage for the aliased backlink suffix: rendered task lines get
-- a `[[basename|alias]]` suffix (real filename target + alias display text)
-- when the source note has a frontmatter alias, and the edit-flush round-trip
-- strips that suffix faithfully.
--
-- Uses real obsidian.nvim so the alias resolver hits the genuine
-- obsidian.frontmatter parser (the stubbed unit test in
-- tests/unit/test_alias_resolver.lua cannot catch API drift there).
--
-- The source file is a freshly written temp .md (with YAML frontmatter) so the
-- edit-flush tests can mutate it without touching checked-in fixtures.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local cwd = vim.fn.getcwd()
local deps_dir = cwd .. "/.deps"

--- Spawn a child Neovim, write *file_lines* to a temp .md, render a ```tasks
--- block with *query_lines*, and return (child, src_path).
local function spawn(file_lines, query_lines)
  local child = MiniTest.new_child_neovim()
  child.start({ "--clean", "-n", "--headless" })
  child.lua(
    [[
    local cwd, deps_dir = ...
    vim.opt.rtp:prepend(deps_dir .. "/mini.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/obsidian.nvim")
    vim.opt.rtp:prepend(deps_dir .. "/blink.cmp")
    vim.opt.rtp:prepend(cwd)
    local orig = vim.treesitter.start
    vim.treesitter.start = function(...) pcall(orig, ...) end
    require("obsidian").setup({
      workspaces = { { name = "test-vault", path = cwd .. "/tests/fixtures/vault" } },
      log_level = vim.log.levels.ERROR,
      completion = { nvim_cmp = false, blink = false },
      picker = { name = nil }, ui = { enable = false },
    })
    require("obsidian-tasks").setup({ global_filter = "#task" })
    require("blink.cmp").setup({
      fuzzy = { implementation = "lua" },
      sources = {
        default = { "obsidian-tasks" },
        providers = { ["obsidian-tasks"] = { module = "obsidian-tasks.cmp.source", name = "ObsidianTasks" } },
      },
    })
  ]],
    { cwd, deps_dir }
  )

  child.lua_get(
    [[(function(file_lines, query_lines)
    local src = vim.fn.tempname() .. ".md"
    vim.fn.writefile(file_lines, src)
    local index = require("obsidian-tasks.index")
    local task_parse = require("obsidian-tasks.task.parse")
    index.set_render_paths = function() end
    index.clear_render_paths = function() end
    index.tasks_in = function()
      local ok, lines = pcall(vim.fn.readfile, src)
      local all = {}
      if ok then
        for ln, line in ipairs(lines) do
          local t = task_parse.parse(line)
          if t then all[#all + 1] = { task = t, path = src, ln = ln } end
        end
      end
      local i = 0
      return function()
        i = i + 1
        if all[i] then return all[i].task, all[i].path, all[i].ln end
      end
    end
    local render = require("obsidian-tasks.render.init")
    render.configure({ default_folded = false })
    local bufnr = vim.api.nvim_create_buf(false, true)
    local fence_lines = { "```tasks" }
    for _, q in ipairs(query_lines) do fence_lines[#fence_lines + 1] = q end
    fence_lines[#fence_lines + 1] = "```"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, fence_lines)
    vim.b[bufnr].obsidian_tasks_dashboard = true
    render.render_buffer(bufnr, nil)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd("normal! zR")
    _G._dash_bufnr = bufnr
    _G._src = src
    return src
  end)(...)]],
    { file_lines, query_lines }
  )

  return child, child.lua_get("_G._src")
end

--- Return the 0-indexed dashboard row whose text contains *needle*, or -1.
local function find_row(child, needle)
  return child.lua_get(string.format(
    [[(function()
        for i, l in ipairs(vim.api.nvim_buf_get_lines(_G._dash_bufnr, 0, -1, false)) do
          if l and l:find(%q, 1, true) then return i - 1 end
        end
        return -1
      end)()]],
    needle
  ))
end

--- A markdown file body with an `aliases:` frontmatter entry and two tasks.
local FILE = {
  "---",
  "aliases:",
  "  - Alias Note",
  "---",
  "",
  "- [ ] Aliased task one #task",
  "- [ ] Aliased task two #task",
}

-- ── render: the suffix shows [[basename|alias]] ──────────────────────────────

T["render: backlink suffix is [[basename|alias]]"] = function()
  local child, src = spawn(FILE, { "not done" })

  local row = find_row(child, "Aliased task one")
  eq(row >= 0, true, "task row must exist")

  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row .. ", " .. row + 1 .. ", false)[1]")
  -- Alias is the display text after the pipe.
  eq(line:find("|Alias Note]]", 1, true) ~= nil, true, "suffix must show the alias: [" .. line .. "]")
  -- The link target is the real filename basename, so the suffix resolves for
  -- markdown LSPs (marksman) and Obsidian alike.
  local basename = vim.fn.fnamemodify(src, ":t:r")
  eq(line:find("[[" .. basename .. "|Alias Note]]", 1, true) ~= nil, true, "suffix: [" .. line .. "]")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── edit-flush: editing an aliased row writes no stray wikilink to source ─────

T["edit-flush: alias suffix is stripped, source gains no wikilink"] = function()
  local child, src = spawn(FILE, { "not done" })

  local row = find_row(child, "Aliased task one")
  eq(row >= 0, true, "task row must exist")

  -- Change the word "Aliased" → "Renamed" inside the description.  The trailing
  -- " [[Alias Note]]" suffix stays at the line end so the flush MUTATE path
  -- must strip it before writing back to source.
  -- "Aliased" begins at byte column 6 ("- [ ] " prefix).
  child.api.nvim_win_set_cursor(0, { row + 1, 6 })
  child.type_keys("ciw", "Renamed", "<Esc>")
  vim.loop.sleep(400)

  local lines = child.lua_get("vim.fn.readfile(_G._src)")
  local task_line
  for _, l in ipairs(lines) do
    if l:find("Renamed task one") then
      task_line = l
    end
  end
  eq(task_line ~= nil, true, "edited task must reach source: " .. vim.inspect(lines))
  eq(task_line:find("[[", 1, true) == nil, true, "source line must carry no wikilink: [" .. task_line .. "]")
  eq(task_line:gsub("%s+$", ""), "- [ ] Renamed task one #task")

  child.stop()
  pcall(vim.fn.delete, src)
end

-- ── hide backlinks: no suffix rendered, edit-flush re-applies nothing ────────

T["hide backlinks: edit-flush adds no phantom suffix"] = function()
  local child, src = spawn(FILE, { "not done", "hide backlinks" })

  local row = find_row(child, "Aliased task one")
  eq(row >= 0, true, "task row must exist")

  local line = child.lua_get("vim.api.nvim_buf_get_lines(_G._dash_bufnr, " .. row .. ", " .. row + 1 .. ", false)[1]")
  eq(line:find("[[", 1, true) == nil, true, "hide backlinks → no suffix rendered: [" .. line .. "]")

  child.api.nvim_win_set_cursor(0, { row + 1, 6 })
  child.type_keys("ciw", "Renamed", "<Esc>")
  vim.loop.sleep(400)

  -- Source must not gain a wikilink token.
  local lines = child.lua_get("vim.fn.readfile(_G._src)")
  local task_line
  for _, l in ipairs(lines) do
    if l:find("Renamed task one") then
      task_line = l
    end
  end
  eq(task_line ~= nil, true, "edited task must reach source")
  eq(task_line:find("[[", 1, true) == nil, true, "source must carry no wikilink: [" .. task_line .. "]")

  -- The post-flush managed rendered_text must also be suffix-free (the quirk
  -- this feature fixed: edit-flush no longer stamps a phantom basename suffix).
  local rendered = child.lua_get(
    "(require('obsidian-tasks.render.managed').task_meta_for_row(_G._dash_bufnr, " .. row .. ") or {}).rendered_text"
  )
  eq(
    type(rendered) == "string" and rendered:find("[[", 1, true) == nil,
    true,
    "rendered_text: [" .. tostring(rendered) .. "]"
  )

  child.stop()
  pcall(vim.fn.delete, src)
end

return T
