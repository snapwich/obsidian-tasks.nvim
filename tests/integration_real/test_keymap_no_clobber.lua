-- tests/integration_real/test_keymap_no_clobber.lua
-- Regression test for the obsidian.nvim <CR>/gf race fix (commit cc9cadc).
--
-- After both plugins are loaded and a markdown buffer in the test vault has
-- our render attached, we must observe:
--   • obsidian.nvim's buffer-local <CR> exists (its smart_action).
--   • NO buffer-local <CR>/gf is installed by us (desc doesn't mention us).
--   • Our `gd` IS installed (with our `obsidian-tasks:` desc prefix).
--
-- If a future change re-introduces a buffer-local <CR> in render/keymap.lua,
-- this test fails before the race bug ships.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

local fixture_vault = vim.fn.fnamemodify("tests/fixtures/vault", ":p"):gsub("/$", "")

--- Open a fixture file in a real buffer, fire FileType + BufEnter so
--- obsidian.nvim's ftplugin runs, then attach our render.
--- @param relpath string
--- @return integer bufnr
local function open_and_attach(relpath)
  local abs = fixture_vault .. "/" .. relpath
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(abs))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"
  vim.api.nvim_exec_autocmds("BufEnter", { buffer = bufnr })
  local render = require("obsidian-tasks.render")
  render.render_buffer(bufnr, Obsidian.workspace)
  return bufnr
end

--- Find first buffer-local mapping for *lhs_pattern* (matches against m.lhs
--- which is stored with `<…>` keys preserved e.g. "<CR>") or "<lt>…" forms.
--- Returns the maparg dict or nil.
--- @param lhs_pattern string  literal lhs string as stored by nvim_buf_get_keymap
--- @param bufnr integer
--- @return table|nil
local function buf_map_by_lhs(lhs_pattern, bufnr)
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if m.lhs == lhs_pattern then
      return m
    end
  end
  return nil
end

--- Return list of buffer-local n-mode mappings whose `desc` field contains
--- the substring `"obsidian-tasks:"` — our identifier prefix from
--- render/keymap.lua kmap().
--- @param bufnr integer
--- @return table[]
local function our_buf_maps(bufnr)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if (m.desc or ""):find("obsidian%-tasks:", 1, false) then
      out[#out + 1] = m
    end
  end
  return out
end

T["after both plugins load + render attaches: obsidian's <CR> wins (we install none)"] = function()
  local bufnr = open_and_attach("inbox/queries.md")
  local cr = buf_map_by_lhs("<CR>", bufnr)
  eq(type(cr), "table") -- obsidian.nvim installed it
  -- The installed <CR> must NOT be ours.
  eq((cr.desc or ""):find("obsidian%-tasks:", 1, false) == nil, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["our leader keymaps ARE installed after render attach"] = function()
  local bufnr = open_and_attach("inbox/queries.md")
  local ours = our_buf_maps(bufnr)
  -- render/keymap.lua attaches 8 leader keymaps when setup_keymaps != false.
  eq(#ours >= 1, true)
  -- Specifically the jump keymap must be present (cited in CR-race fix commit).
  local found_jump = false
  for _, m in ipairs(ours) do
    if (m.desc or ""):find("jump to source", 1, true) then
      found_jump = true
    end
  end
  eq(found_jump, true)
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

T["we install no buffer-local gf override either"] = function()
  local bufnr = open_and_attach("inbox/queries.md")
  local gf = buf_map_by_lhs("gf", bufnr)
  if gf then
    eq((gf.desc or ""):find("obsidian%-tasks:", 1, false) == nil, true)
  end
  vim.api.nvim_buf_delete(bufnr, { force = true })
end

return T
