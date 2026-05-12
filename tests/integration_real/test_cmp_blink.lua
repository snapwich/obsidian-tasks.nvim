-- tests/integration_real/test_cmp_blink.lua
-- Integration tests against the REAL blink.cmp plugin.
--
-- Catches API drift / contract bugs that fully-stubbed unit tests miss.
-- Concrete origin: a `Source:execute` override that returned via `callback()`
-- without calling `default_implementation` silently no-op'd accept; unit tests
-- passed because they only asserted the callback was invoked.  See the
-- structural test below for the regression.

local T = MiniTest.new_set()

local function eq(a, b)
  MiniTest.expect.equality(a, b)
end

-- ── Provider registration ────────────────────────────────────────────────────

T["blink.cmp.config.sources.providers includes 'obsidian-tasks' after setup"] = function()
  local providers = require("blink.cmp.config").sources.providers
  eq(providers["obsidian-tasks"] ~= nil, true)
  eq(providers["obsidian-tasks"].module, "obsidian-tasks.cmp.source")
end

-- ── Source contract: do NOT override Source:execute ─────────────────────────
-- Regression: blink's default execute inserts the item's insertText. An
-- override that doesn't call default_implementation silently drops the insert.

T["source module does NOT override Source:execute"] = function()
  local source_mod = require("obsidian-tasks.cmp.source")
  eq(rawget(source_mod, "execute"), nil)
end

-- ── enabled() in a real vault buffer ─────────────────────────────────────────

local function with_vault_buf(lines, cursor_col, fn)
  local fake_path = vim.fn.getcwd() .. "/tests/fixtures/vault/blink_test_scratch.md"
  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, fake_path)
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  vim.api.nvim_win_set_cursor(0, { 1, cursor_col })
  local ok, err = pcall(fn, bufnr)
  vim.api.nvim_buf_delete(bufnr, { force = true })
  if not ok then
    error(err)
  end
end

T["source:enabled() returns true on task line in vault md buffer"] = function()
  local Source = require("obsidian-tasks.cmp.source")
  local inst = Source.new({}, {})
  with_vault_buf({ "- [ ] test task" }, 14, function()
    eq(inst:enabled(), true)
  end)
end

T["source:enabled() returns false on prose line in vault md buffer"] = function()
  local Source = require("obsidian-tasks.cmp.source")
  local inst = Source.new({}, {})
  with_vault_buf({ "just prose, no task here" }, 5, function()
    eq(inst:enabled(), false)
  end)
end

-- ── get_completions() with blink's documented ctx shape ─────────────────────
-- blink ctx (per blink.cmp.Source contract): { line, cursor = {row, col} }
-- with 1-indexed row and 0-indexed byte col. source.lua adapts via cursor[2].

T["source:get_completions() returns 📅 due item on description position"] = function()
  local Source = require("obsidian-tasks.cmp.source")
  local inst = Source.new({}, {})

  with_vault_buf({ "- [ ] test task " }, 16, function()
    local ctx = { line = "- [ ] test task ", cursor = { 1, 16 } }
    local items
    inst:get_completions(ctx, function(resp)
      items = resp.items
    end)

    eq(type(items), "table")
    local found
    for _, item in ipairs(items) do
      if item.label and item.label:find("📅", 1, true) then
        found = item
        break
      end
    end
    eq(found ~= nil, true)
    eq(found.insertText, "📅 ")
  end)
end

T["source:get_completions() returns date phrases when cursor is after 📅"] = function()
  local Source = require("obsidian-tasks.cmp.source")
  local inst = Source.new({}, {})

  with_vault_buf({ "- [ ] test task 📅 " }, 22, function()
    -- Byte col 22: "- [ ] test task " is 16 bytes; "📅" is 4 bytes; trailing
    -- space is 1 byte → 16 + 4 + 1 = 21, so col 21 is right after the space.
    -- Using 21 to land just after the trailing space.
    local line = "- [ ] test task 📅 "
    local ctx = { line = line, cursor = { 1, #line } }
    local items
    inst:get_completions(ctx, function(resp)
      items = resp.items
    end)

    eq(type(items), "table")
    local labels = {}
    for _, item in ipairs(items) do
      labels[item.label] = true
    end
    eq(labels["today"], true)
    eq(labels["tomorrow"], true)
  end)
end

return T
