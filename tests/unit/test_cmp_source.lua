-- tests/unit/test_cmp_source.lua
-- Unit tests for cmp/source.lua
--
-- Strategy:
--   • Stub obsidian-tasks.util.obsidian so vault detection is controlled.
--   • Stub obsidian-tasks.render.draw  so render-line detection is controlled.
--   • Use scratch buffers with controlled names and content.
--   • cursor position is spoofed via vim.api.nvim_win_get_cursor mock.

local T = MiniTest.new_set()

-- ── helpers ───────────────────────────────────────────────────────────────────

--- Swap package.loaded[name]; returns cleanup fn.
local function install_mock(name, mock)
  local orig = package.loaded[name]
  package.loaded[name] = mock
  return function()
    package.loaded[name] = orig
  end
end

--- Fresh require of source (clear cache so stubs take effect).
local function fresh_source()
  package.loaded["obsidian-tasks.cmp.source"] = nil
  return require("obsidian-tasks.cmp.source")
end

--- Create a scratch buffer with a given name (no actual file I/O) and lines.
--- Returns bufnr + cleanup function.
local function make_named_buf(name, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  -- Force the buffer name so is_md_buffer / vault path checks see it.
  -- Use noautocmd to suppress BufFilePre events in headless tests.
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr, function()
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

--- Override nvim_get_current_buf + nvim_win_get_cursor for the duration of fn.
--- cursor_row is 1-indexed (as returned by nvim_win_get_cursor).
local function with_cursor(bufnr, cursor_row, fn)
  local orig_buf = vim.api.nvim_get_current_buf
  local orig_cur = vim.api.nvim_win_get_cursor
  vim.api.nvim_get_current_buf = function()
    return bufnr
  end
  vim.api.nvim_win_get_cursor = function(_)
    return { cursor_row, 0 }
  end
  local ok, err = pcall(fn)
  vim.api.nvim_get_current_buf = orig_buf
  vim.api.nvim_win_get_cursor = orig_cur
  if not ok then
    error(err, 2)
  end
end

--- Standard stub for util.obsidian that marks every path as inside a vault.
local function vault_stub()
  return {
    workspace_for_path = function(_path)
      return { root = "/vault", name = "default" }
    end,
  }
end

--- Standard stub for util.obsidian that marks every path as NOT in a vault.
local function no_vault_stub()
  return {
    workspace_for_path = function(_path)
      return nil
    end,
  }
end

--- Standard stub for render.draw that says no line is a render line.
local function no_render_stub()
  return {
    is_render_line = function(_bufnr, _lnum)
      return nil
    end,
  }
end

--- Stub for render.draw that treats every line as a render task line.
local function always_render_stub()
  return {
    is_render_line = function(_bufnr, _lnum)
      return { src_path = "/vault/note.md", src_line = 1, src_hash = "abc", source_text_hash = "def" }
    end,
  }
end

-- ── module shape ──────────────────────────────────────────────────────────────

T["module shape: new() returns a table"] = function()
  local Source = fresh_source()
  local inst = Source.new({}, {})
  MiniTest.expect.equality(type(inst), "table")
end

T["module shape: instance has required methods"] = function()
  local Source = fresh_source()
  local inst = Source.new({}, {})
  MiniTest.expect.equality(type(inst.enabled), "function")
  MiniTest.expect.equality(type(inst.get_trigger_characters), "function")
  MiniTest.expect.equality(type(inst.get_completions), "function")
  MiniTest.expect.equality(type(inst.resolve), "function")
end

-- ── get_trigger_characters ────────────────────────────────────────────────────

T["get_trigger_characters: returns table with space, colon, hash"] = function()
  local Source = fresh_source()
  local inst = Source.new({}, {})
  local chars = inst:get_trigger_characters()
  MiniTest.expect.equality(type(chars), "table")
  -- Build a set for easy membership checks.
  local set = {}
  for _, c in ipairs(chars) do
    set[c] = true
  end
  MiniTest.expect.equality(set[" "], true)
  MiniTest.expect.equality(set[":"], true)
  MiniTest.expect.equality(set["#"], true)
end

-- ── get_completions ───────────────────────────────────────────────────────────

T["get_completions: calls callback with empty items"] = function()
  local Source = fresh_source()
  local inst = Source.new({}, {})
  local got = nil
  inst:get_completions({}, function(resp)
    got = resp
  end)
  MiniTest.expect.equality(got ~= nil, true)
  MiniTest.expect.equality(type(got.items), "table")
  MiniTest.expect.equality(#got.items, 0)
end

T["get_completions: response has is_incomplete_forward and is_incomplete_backward"] = function()
  local Source = fresh_source()
  local inst = Source.new({}, {})
  local got = nil
  inst:get_completions({}, function(resp)
    got = resp
  end)
  MiniTest.expect.equality(type(got.is_incomplete_forward), "boolean")
  MiniTest.expect.equality(type(got.is_incomplete_backward), "boolean")
end

-- ── resolve pass-through ─────────────────────────────────────────────────────

T["resolve: passes item through to callback"] = function()
  local Source = fresh_source()
  local inst = Source.new({}, {})
  local item = { label = "📅", kind = 1 }
  local got = nil
  inst:resolve(item, function(resolved)
    got = resolved
  end)
  MiniTest.expect.equality(got, item)
end

-- ── enabled: non-markdown buffer ──────────────────────────────────────────────

T["enabled: non-md buffer → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Buffer with a .txt name
  local bufnr, cleanup = make_named_buf("/vault/note.txt", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

T["enabled: buffer with no name → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Scratch buffer with no name (empty string)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

-- ── enabled: vault membership ─────────────────────────────────────────────────

T["enabled: md buffer outside vault → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", no_vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/not-a-vault/note.md", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

T["enabled: obsidian not ready (error) → false"] = function()
  -- workspace_for_path raises an error (obsidian not initialised).
  local c1 = install_mock("obsidian-tasks.util.obsidian", {
    workspace_for_path = function(_)
      error("obsidian-tasks: requires obsidian.nvim to be set up first")
    end,
  })
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

-- ── enabled: task-line detection ──────────────────────────────────────────────

T["enabled: vault md buffer with task line (dash) → true"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- [ ] My task 📅 2026-05-10" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, true)
end

T["enabled: task line with asterisk bullet → true"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "* [x] Done task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, true)
end

T["enabled: task line with plus bullet → true"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "+ [/] In progress" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, true)
end

T["enabled: task line with leading whitespace → true"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "  - [ ] Indented task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, true)
end

T["enabled: vault md buffer with non-task line → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "Just a plain paragraph." })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

T["enabled: plain list item (no checkbox) → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- Just a bullet without checkbox" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

T["enabled: heading line → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "# Heading" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

T["enabled: empty line → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

-- ── enabled: render-line detection ───────────────────────────────────────────

T["enabled: render task line in vault md → true"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  -- render.draw says this is a render line regardless of raw content.
  local c2 = install_mock("obsidian-tasks.render.draw", always_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  -- Raw line is NOT a task line — should still be true via render path.
  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- [ ] Render task [[note]]" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, true)
end

T["enabled: render line in non-vault md → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", no_vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", always_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/not-vault/note.md", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

-- ── enabled: correct line under cursor ───────────────────────────────────────

T["enabled: cursor on task line 2 of multi-line buffer → true"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", {
    "# Heading",
    "- [ ] Task on line 2",
    "Just prose.",
  })
  -- cursor_row = 2 → line index 1 → "- [ ] Task on line 2"
  local result
  with_cursor(bufnr, 2, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, true)
end

T["enabled: cursor on prose line in multi-line buffer → false"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", {
    "# Heading",
    "- [ ] Task on line 2",
    "Just prose on line 3.",
  })
  -- cursor_row = 3 → line index 2 → prose
  local result
  with_cursor(bufnr, 3, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()

  MiniTest.expect.equality(result, false)
end

-- ── enabled: opts.blink_cmp.enabled ──────────────────────────────────────────

T["enabled: blink_cmp.enabled=false → false even on task line"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  -- Stub the plugin module with blink_cmp.enabled = false.
  local c3 = install_mock("obsidian-tasks", {
    opts = { blink_cmp = { enabled = false } },
  })
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()
  c3()

  MiniTest.expect.equality(result, false)
end

T["enabled: blink_cmp.enabled=true → respects normal conditions"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  local c3 = install_mock("obsidian-tasks", {
    opts = { blink_cmp = { enabled = true } },
  })
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()
  c3()

  MiniTest.expect.equality(result, true)
end

T["enabled: blink_cmp opts absent → defaults to enabled"] = function()
  local c1 = install_mock("obsidian-tasks.util.obsidian", vault_stub())
  local c2 = install_mock("obsidian-tasks.render.draw", no_render_stub())
  -- Empty opts (plugin not yet fully set up).
  local c3 = install_mock("obsidian-tasks", { opts = {} })
  local Source = fresh_source()
  local inst = Source.new({}, {})

  local bufnr, cleanup = make_named_buf("/vault/note.md", { "- [ ] task" })
  local result
  with_cursor(bufnr, 1, function()
    result = inst:enabled()
  end)
  cleanup()
  c1()
  c2()
  c3()

  MiniTest.expect.equality(result, true)
end

return T
