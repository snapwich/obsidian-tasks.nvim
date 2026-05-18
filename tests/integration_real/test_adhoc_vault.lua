-- tests/integration_real/test_adhoc_vault.lua
-- End-to-end: a vault (directory containing `.obsidian/`) that is NOT
-- registered in obsidian.nvim's workspaces config should still render
-- dashboards.  Exercises the `workspace_for_path` ad-hoc fallback in
-- util/obsidian.lua.

local T = MiniTest.new_set()

local eq = MiniTest.expect.equality

--- Create a fresh ad-hoc vault outside the configured fixture vault.
--- Returns root, dashboard_path, src_path.
local function make_adhoc_vault()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root .. "/.obsidian", "p")
  local src = root .. "/source.md"
  local dash = root .. "/dash.md"
  vim.fn.writefile({ "- [ ] in adhoc vault #task" }, src)
  vim.fn.writefile({ "```tasks", "not done", "```" }, dash)
  return root, dash, src
end

T["ad-hoc vault: dashboard auto-renders even though dir is not in workspaces config"] = function()
  local adapter = require("obsidian-tasks.util.obsidian")
  local render = require("obsidian-tasks.render")

  local root, dash_path, src_path = make_adhoc_vault()

  -- Sanity: obsidian.api.find_workspace would NOT find this dir (it's only
  -- registered with the fixture vault).  The adapter's ad-hoc fallback is
  -- what must surface the workspace.
  local ws = adapter.workspace_for_path(dash_path)
  eq(type(ws), "table", "ad-hoc fallback returns a workspace for the dashboard path")
  eq(tostring(ws.root), root, "workspace.root equals the ad-hoc vault dir")

  -- Open the dashboard.  BufReadPost → autocmd → render scheduled.
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(dash_path))
  local bufnr = vim.api.nvim_get_current_buf()
  vim.bo[bufnr].filetype = "markdown"

  -- Wait for the deferred render + async vault walk to populate the buffer.
  -- Success = the rendered dashboard contains the source task's description.
  local ok = vim.wait(3000, function()
    for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
      if line:find("in adhoc vault", 1, true) then
        return true
      end
    end
    return false
  end, 50)
  eq(ok, true, "dashboard must list the ad-hoc vault's task within timeout")

  vim.api.nvim_buf_delete(bufnr, { force = true })
  vim.fn.delete(root, "rf")
  pcall(vim.fn.delete, src_path)
end

return T
