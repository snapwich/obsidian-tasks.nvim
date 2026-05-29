-- tests/integration_obsidian/test_checkbox_bridge.lua
-- Validates the optional obsidian.nvim checkbox-symbol bridge. obsidian.nvim is
-- loaded in this suite, so the `Obsidian` global exists. We inject a custom
-- checkbox order containing a symbol that is in neither our defaults nor
-- obsidian.nvim's default order ("@"), then assert
-- bridge_obsidian_checkbox_order() adopts it into status.by_symbol so a <CR>
-- smart_action landing on that symbol is recognised by our revert/status path.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

T["bridge adopts an obsidian-only checkbox symbol into by_symbol"] = function()
  local status = require("obsidian-tasks.task.status")

  -- "@" is in neither our default statuses (" x / - h") nor obsidian.nvim's
  -- default checkbox order, so it can only enter by_symbol via the bridge.
  eq(status.by_symbol["@"], nil)

  -- Inject a custom obsidian.nvim checkbox order containing the new symbol.
  Obsidian.opts = Obsidian.opts or {}
  Obsidian.opts.checkbox = { order = { " ", "x", "@" } }

  status.bridge_obsidian_checkbox_order()

  -- The custom symbol must now be a known status.
  eq(status.by_symbol["@"] ~= nil, true)
end

return T
